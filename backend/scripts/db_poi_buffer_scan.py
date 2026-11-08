"""Read-only stage-2 scan: how many trim-candidate rows sit near the
nearby-places POIs (Hospital / Police / Metro / Bus) the app routes to?

Fetches Pune transit/civic POIs from public Overpass (no keys, no secrets),
caches them locally so reruns never re-hit Overpass, loads them into
SESSION-TEMP tables (dropped at disconnect, never persisted - respects the
additive-only DB rule), and counts road_segments candidates within buffer
radii. No .env is read in-process (backend config loader supplies
credentials; user rule 2026-10-31: agent never reads backend\\.env).

Run:  cd D:\\ResilientSteps\\backend
      .\\.venv\\Scripts\\python.exe scripts\\db_poi_buffer_scan.py
"""

import asyncio
import json
import sys
import time
from pathlib import Path

import httpx

BACKEND_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BACKEND_ROOT))

from sqlalchemy import text  # noqa: E402

OVERPASS_ENDPOINTS = [
    "https://overpass-api.de/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
    "https://overpass.private.coffee/api/interpreter",
]
CACHE_PATH = BACKEND_ROOT.parent / "logic" / "outputs" / "poi_buffer_cache.json"
RADII_M = [50, 100, 150]
CANDIDATE_CLASSES = ["service", "trunk", "trunk_link", "track"]
# Set A: every stop-level POI (thousands) vs Set B: station-grade POIs only.
POI_QUERIES = {
    "A_all_pois": (
        "[out:json][timeout:120];("
        'node["amenity"~"^(bus_station|police|hospital|clinic|doctors)$"]({bbox});'
        'node["railway"~"^(station|halt)$"]({bbox});'
        'node["highway"="bus_stop"]({bbox});'
        'node["railway"="subway_entrance"]({bbox});'
        'node["public_transport"="station"]({bbox});'
        ");out center;"
    ),
    "B_terminals_only": (
        "[out:json][timeout:120];("
        'node["amenity"~"^(bus_station|police|hospital)$"]({bbox});'
        'node["railway"~"^(station|halt)$"]({bbox});'
        'node["railway"="subway_entrance"]({bbox});'
        'node["public_transport"="station"]({bbox});'
        ");out center;"
    ),
}
UA = "ResilientSteps/1.0 (local trim scan)"


def _p(msg: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def _fetch_pois(bbox: str) -> dict[str, list[tuple[float, float]]]:
    """Fetch each POI set, preferring the 24 h local cache."""
    cache: dict[str, list] = {}
    if CACHE_PATH.exists():
        age_h = (time.time() - CACHE_PATH.stat().st_mtime) / 3600
        if age_h < 24:
            cache = json.loads(CACHE_PATH.read_text())
            _p(f"cache hit ({age_h:.1f} h old): {', '.join(cache)}")

    out: dict[str, list[tuple[float, float]]] = {}
    for name, qtpl in POI_QUERIES.items():
        if name in cache:
            out[name] = [tuple(c) for c in cache[name]]
            _p(f"{name}: {len(out[name]):,} POIs from CACHE")
            continue
        query = qtpl.format(bbox=bbox)
        last_err = None
        for url in OVERPASS_ENDPOINTS:
            try:
                _p(f"{name}: querying {url.split('/')[2]} ...")
                resp = httpx.post(
                    url, data={"data": query}, timeout=120, headers={"User-Agent": UA}
                )
                resp.raise_for_status()
                elements = resp.json().get("elements", [])
                break
            except Exception as e:  # noqa: BLE001 - try next mirror
                last_err = e
                _p(f"  endpoint failed: {type(e).__name__}: {e}")
                continue
        else:
            raise RuntimeError(f"all Overpass endpoints failed; last: {last_err}")
        coords: list[tuple[float, float]] = []
        for el in elements:
            lat, lon = el.get("lat"), el.get("lon")
            if lat is None:
                cc = el.get("center") or {}
                lat, lon = cc.get("lat"), cc.get("lon")
            if lat is not None and lon is not None:
                coords.append((float(lat), float(lon)))
        out[name] = coords
        cache[name] = coords
        _p(f"{name}: {len(coords):,} POIs fetched live")

    tmp: dict[str, list] = {k: [list(c) for c in v] for k, v in out.items()}
    CACHE_PATH.write_text(json.dumps(tmp))
    _p(f"POI cache written -> {CACHE_PATH}")
    return out


async def _count_class(db, rt: str, radius: int) -> int:
    res = await db.execute(
        text(
            "SELECT count(*) FROM road_segments r "
            "WHERE r.road_type = :rt AND r.shade_score = 0 "
            "AND EXISTS (SELECT 1 FROM _circ c WHERE r.geometry && c.geom)"
        ),
        {"rt": rt},
    )
    return int(res.scalar())


async def main() -> None:
    from app.core.database import AsyncSessionLocal

    async with AsyncSessionLocal() as db:
        await db.execute(text("SET statement_timeout TO 600000"))
        _p("statement_timeout set to 10 min for this session")

        extent = await db.execute(
            text(
                "SELECT ST_XMin(e), ST_YMin(e), ST_XMax(e), ST_YMax(e) "
                "FROM (SELECT ST_Extent(geometry) AS e FROM road_segments) x"
            )
        )
        xmin, ymin, xmax, ymax = (float(v) for v in extent.one())
        bbox = f"{ymin:.6f},{xmin:.6f},{ymax:.6f},{xmax:.6f}"
        _p(f"dataset bbox: {bbox}")

        poi_sets = _fetch_pois(bbox)

        all_counts: dict = {}
        for set_name, coords in poi_sets.items():
            _p("=" * 60)
            _p(f"SET {set_name}: {len(coords):,} POIs")

            await db.execute(
                text("CREATE TEMP TABLE _poi_buf (geog geography(point, 4326))")
            )
            if coords:
                await db.execute(
                    text(
                        "INSERT INTO _poi_buf (geog) "
                        "VALUES (ST_SetSRID(ST_MakePoint(:lon, :lat), 4326)::geography)"
                    ),
                    [{"lat": la, "lon": lo} for la, lo in coords],
                )

            for radius in RADII_M:
                # Pre-buffer each POI ONCE as a lat/lon circle, then match
                # segments with r.geometry && c.geom so the planner uses
                # idx_road_segments_geom (geography-EXISTS cannot - it timed
                # out on Supabase).
                await db.execute(text("DROP TABLE IF EXISTS _circ"))
                await db.execute(
                    text("CREATE TEMP TABLE _circ (geom geometry(Polygon, 4326))")
                )
                await db.execute(
                    text(
                        "INSERT INTO _circ SELECT ST_Buffer(geog, :rad)::geometry "
                        "FROM _poi_buf"
                    ),
                    {"rad": radius},
                )
                parts = []
                total = 0
                for rt in CANDIDATE_CLASSES:
                    n = await _count_class(db, rt, radius)
                    total += n
                    parts.append(f"{rt}={n:,}")
                    key = f"{set_name}|{radius}|{rt}"
                    all_counts[key] = n
                _p(
                    f"  radius {radius:>3} m -> kept: {'  '.join(parts)}"
                    f"   | total {total:,} rows (~{total * 1270 / 1048576:.1f} MB)"
                )

            await db.execute(text("DROP TABLE _poi_buf"))

        _p("=" * 60)
        _p("FINAL counts (JSON):")
        print(json.dumps(all_counts, indent=1), flush=True)


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
