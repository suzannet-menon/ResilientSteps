"""
ResilientSteps Satellite Shade Batch (v2) — Google Earth Engine
===============================================================
Batch-only pipeline (never in the request path). Reads road_segments from the
MAIN database READ-ONLY, computes per-segment NDVI from a Sentinel-2 median
composite via GEE server-side `reduceRegions`, calibrates the NDVI to the
project shade scale (0-100), and writes ONLY to the local shade SIDECAR keyed
by (road_segment_id, dataset_version).

Hard rules (S-092/S-094/S-098):
  - The main DATABASE_URL is never written to. Only SELECTs.
  - Default mode is DRY-RUN: computes everything, writes NOTHING anywhere.
    Pass --apply to enable sidecar upserts (and even then, never main-DB).
  - Segments with no valid satellite pixels (low pixel validity) are left OUT
    of the sidecar so the route-time merge keeps their existing OSM shade.

Usage (backend venv):
    python generate_shade_map_v2.py --pilot 6            # 6-segment pilot dry-run
    python generate_shade_map_v2.py --limit 2000         # 2k dry-run
    python generate_shade_map_v2.py --pilot 6 --apply    # pilot writes to sidecar
    python generate_shade_map_v2.py --apply              # supervised full batch
    python generate_shade_map_v2.py --ids 60482,60483    # explicit segments

Sidecar environ: SHADE_DB_URL (required only for --apply).
GEE environ: GEE_PROJECT_ID, GEE_KEY_PATH (same conventions as check_gee.py).
"""

import argparse
import asyncio
import json
import os
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

import asyncpg

OUT_DIR = Path(__file__).resolve().parent / "outputs"
STATE_PATH = OUT_DIR / "shade_v2_state.json"
REPORT_PATH = OUT_DIR / "shade_v2_last_run.txt"

# Couch-sized chunks keep each reduceRegions request modest and make retries
# cheap. Pune's road WKTs are vertex-dense, so the binding constraint is
# Earth Engine's 10 MB request payload, not the request count.
DEFAULT_CHUNK_SIZE = 500

# Douglas-Peucker tolerance applied before upload (meters). Well inside the
# 10 m corridor buffer, so the corridor area is visually unaffected while the
# payload shrinks several-fold.
SIMPLIFY_TOLERANCE_M = 1.5

# Pixels are 10 m; a 2x-pixel-wide corridor around the centreline catches the
# actual walking surface without bleeding into intersections.
DEFAULT_BUFFER_M = 10.0

# Pixels 10m at Pune latitudes, in degrees.
DEG_PER_M = 1.0 / 111_320.0

# Fraction of buffer pixels that must be cloud-free for a segment to get a
# GEE score. Below this the segment is NOT written to the sidecar -> route
# time keeps the existing OSM-derived shade.
DEFAULT_MIN_PIXEL_VALIDITY = 0.05

# Linear NDVI -> shade calibration (clamped). Bare earth ~0.05-0.1, grass
# ~0.25, dense canopy ~0.55+, so [0.1, 0.55] spans the walkable range.
DEFAULT_NDVI_MIN = 0.10
DEFAULT_NDVI_MAX = 0.55

RETRY_WAITS = [10, 30, 90, 240, 480]

MAIN_DB_READ = (
    "SELECT id, osm_way_id, dataset_version, ST_AsText(geometry) AS wkt "
    "FROM road_segments WHERE id > $1 ORDER BY id ASC LIMIT $2"
)

SIDECAR_ENSURE_TABLE = """
CREATE TABLE IF NOT EXISTS segment_shade (
    road_segment_id BIGINT NOT NULL,
    dataset_version TEXT NOT NULL,
    shade_score DOUBLE PRECISION NOT NULL,
    shade_source TEXT NOT NULL DEFAULT 'gee_ndvi',
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (road_segment_id, dataset_version)
)
"""

SIDECAR_UPSERT = """
INSERT INTO segment_shade
    (road_segment_id, dataset_version, shade_score, shade_source, updated_at)
VALUES ($1, $2, $3, 'gee_ndvi', NOW())
ON CONFLICT (road_segment_id, dataset_version) DO UPDATE
SET shade_score = EXCLUDED.shade_score,
    shade_source = EXCLUDED.shade_source,
    updated_at = NOW()
"""

_DATASET_COUNT_SQL = "SELECT COUNT(DISTINCT dataset_version) FROM road_segments"
_EXTENT_SQL = "SELECT ST_AsText(ST_Extent(geometry)) FROM road_segments"


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%H:%M:%S")


def log(msg: str) -> None:
    print(f"[{_now()}] {msg}", flush=True)


def strip_asyncpg_scheme(url: str) -> str:
    """asyncpg takes libpq DSNs; drop SQLAlchemy's `+asyncpg` token if present."""
    return url.replace("+asyncpg", "")


def find_gee_key_path(explicit: str | None) -> str | None:
    if explicit and os.path.exists(explicit):
        return explicit
    override = os.environ.get("GEE_KEY_PATH")
    if override and os.path.exists(override):
        return override
    # Same folder as check_gee.py — the keys live there by convention.
    folder = Path("C:/ResilientKeys")
    if not folder.is_dir():
        return None
    for path in sorted(folder.glob("*.json")):
        return str(path)
    return None


def calibrate_ndvi(ndvi: float, ndvi_min: float, ndvi_max: float) -> float:
    span = max(ndvi_max - ndvi_min, 1e-6)
    frac = (ndvi - ndvi_min) / span
    return max(0.0, min(100.0, frac * 100.0))


def wkt_to_ee_geometry(wkt: str, buffer_m: float):
    from shapely import wkt as shp_wkt
    from shapely.geometry import mapping as shp_mapping

    geom = shp_wkt.loads(wkt)
    simplified = geom.simplify(SIMPLIFY_TOLERANCE_M * DEG_PER_M, preserve_topology=True)
    buffer_deg = buffer_m * DEG_PER_M
    buffered = simplified.buffer(buffer_deg)
    import ee

    return ee.Geometry(shp_mapping(buffered))


def load_site_config() -> dict:
    import yaml

    config_path = Path(__file__).resolve().parent.parent / "config" / "city.yaml"
    if config_path.exists():
        with open(config_path, encoding="utf-8") as fh:
            data = yaml.safe_load(fh)
            return data.get("city", data)
    return {"city": "Pune", "osmnx_place": "Pune, Maharashtra, India"}


class GEEComposite:
    """One Sentinel-2 NDVI median composite over the dataset extent."""

    def __init__(self, extent_wkt: str, date_start: str, date_end: str, buffer_m: float):
        import ee

        self._ee = ee
        self.buffer_m = buffer_m
        self.image = self._build(extent_wkt, date_start, date_end)

    def _build(self, extent_wkt: str, date_start: str, date_end: str):
        from shapely import wkt as shp_wkt
        from shapely.geometry import mapping as shp_mapping

        ee = self._ee
        extent = shp_mapping(shp_wkt.loads(extent_wkt))
        bbox = ee.Geometry(extent).bounds(maxError=1)

        s2 = (
            ee.ImageCollection("COPERNICUS/S2_SR_HARMONIZED")
            .filterBounds(bbox)
            .filterDate(date_start, date_end)
            .filter(ee.Filter.lt("CLOUDY_PIXEL_PERCENTAGE", 60))
        )

        def cloud_mask(img):
            scl = img.select("SCL")
            clear = (
                scl.neq(0)  # no data
                .And(scl.neq(1))  # saturated
                .And(scl.neq(3))  # cloud shadow
                .And(scl.neq(8))  # cloud medium
                .And(scl.neq(9))  # cloud high
                .And(scl.neq(10))  # thin cirrus
            )
            ndvi = img.normalizedDifference(["B8", "B4"])
            return ndvi.updateMask(clear)

        ndvi_median = s2.map(cloud_mask).median().rename("ndvi")
        # Second band: fraction of cloud-free pixels per buffer, so the caller
        # can decide fallback. Mean of this band over a region = validity.
        pix_valid = ndvi_median.mask().rename("pix_valid")
        return ndvi_median.addBands(pix_valid)

    def score_chunk(self, wkt_list: list[str]) -> list[dict]:
        """Blocking: reduceRegions for one chunk. Returns list of {idx, ndvi, validity}."""
        ee = self._ee
        features = [
            ee.Feature(wkt_to_ee_geometry(wkt, self.buffer_m), {"idx": idx})
            for idx, wkt in enumerate(wkt_list)
        ]
        fc = ee.FeatureCollection(features)
        reduced = self.image.reduceRegions(
            collection=fc, reducer=ee.Reducer.mean(), scale=10
        )
        rows = reduced.getInfo()
        out = []
        debug = rows.get("features", []) if isinstance(rows, dict) else rows
        for feat in debug:
            ft = feat.get("properties", feat) if isinstance(feat, dict) else {}
            out.append(
                {
                    "idx": ft.get("idx"),
                    "ndvi": ft.get("ndvi"),
                    "validity": ft.get("pix_valid"),
                }
            )
        return out


async def ensure_single_dataset_version(main_pool) -> str:
    async with main_pool.acquire() as conn:
        count = await conn.fetchval(_DATASET_COUNT_SQL)
        if count != 1:
            raise SystemExit(
                f"ABORT: expected exactly 1 dataset_version in road_segments, found {count}. "
                "The ban on multiple dataset versions (LOCAL_SETUP_STATUS D) would be violated."
            )
        return await conn.fetchval(
            "SELECT dataset_version FROM road_segments ORDER BY id LIMIT 1"
        )


async def fetch_extent(main_pool) -> str:
    async with main_pool.acquire() as conn:
        return await conn.fetchval(_EXTENT_SQL)


async def fetch_chunk(main_pool, last_id: int, chunk_size: int):
    async with main_pool.acquire() as conn:
        return await conn.fetch(MAIN_DB_READ, last_id, chunk_size)


def open_sidecar_pool(url: str):
    return asyncpg.create_pool(dsn=strip_asyncpg_scheme(url), min_size=1, max_size=2)


async def write_sidecar_rows(sidecar_pool, rows: list[dict]) -> None:
    if not rows:
        return
    payload = [
        (r["segment_id"], r["dataset_version"], r["shade_score"]) for r in rows
    ]
    async with sidecar_pool.acquire() as conn:
        await conn.executemany(SIDECAR_UPSERT, payload)


DETERMINISTIC_PAYLOAD_MARKERS = ("payload size", "10485760", "413", "too large")


def _is_payload_error(exc: Exception) -> bool:
    msg = str(exc).lower()
    return any(marker in msg for marker in DETERMINISTIC_PAYLOAD_MARKERS)


def score_chunk_with_retry(composite, wkt_list: list[str], max_retries: int):
    last_exc = None

    def attempt(wkt_sublist):
        nonlocal last_exc
        for retry_no, wait in enumerate([0] + RETRY_WAITS[:max_retries], start=1):
            if wait:
                log(f"  retry attempt {retry_no} after {wait}s backoff...")
                time.sleep(wait)
            try:
                return composite.score_chunk(wkt_sublist)
            except Exception as exc:  # noqa: BLE001 - per-chunk retry envelope
                last_exc = exc
                log(
                    f"  chunk attempt {retry_no} failed: "
                    f"{type(exc).__name__}: {str(exc)[:200]}"
                )
                if _is_payload_error(exc) and len(wkt_sublist) > 1:
                    break  # deterministic: shrinking via retry never helps
        return None

    result = attempt(wkt_list)
    if result is not None:
        return result

    if _is_payload_error(last_exc):
        # Payload cap: split deterministically and recurse so a small chunk
        # never spins through the whole backoff ladder.
        if len(wkt_list) <= 1:
            raise SystemExit(
                f"ABORT: payload too large even for a single segment: {last_exc}"
            )
        mid = len(wkt_list) // 2
        log(f"  payload limit -> splitting {len(wkt_list)} into {mid} + {len(wkt_list) - mid}")
        left = score_chunk_with_retry(composite, wkt_list[:mid], max_retries)
        right = score_chunk_with_retry(composite, wkt_list[mid:], max_retries)
        return left + right

    raise SystemExit(f"ABORT: chunk exhausted {max_retries + 1} attempts. Last: {last_exc}")


async def run(args) -> int:
    database_url = os.environ.get("DATABASE_URL")
    if not database_url:
        print("ERROR: DATABASE_URL not found (backend/.env). Read-only main DB access required.")
        return 1

    project_id = args.project or os.environ.get("GEE_PROJECT_ID", "")
    if not project_id:
        print("ERROR: GEE project id missing. Pass --project <id> or set GEE_PROJECT_ID.")
        return 1

    key_path = find_gee_key_path(args.key_path)
    if not key_path:
        print("ERROR: no service-account JSON discovered (GEE_KEY_PATH unset, none in C:/ResilientKeys).")
        return 1

    sha_de_db_url = os.environ.get("SHADE_DB_URL")
    if args.apply and not sha_de_db_url:
        print("ERROR: --apply needs SHADE_DB_URL (sidecar). Dry-run mode needs nothing.")
        return 1

    import ee
    from google.oauth2 import service_account

    creds = service_account.Credentials.from_service_account_file(
        key_path, scopes=["https://www.googleapis.com/auth/cloud-platform"]
    )
    ee.Initialize(credentials=creds, project=project_id)
    log(f"GEE initialized: project {project_id}")

    main_pool = await asyncpg.create_pool(
        dsn=strip_asyncpg_scheme(database_url), min_size=1, max_size=2
    )
    dataset_version = await ensure_single_dataset_version(main_pool)
    extent_wkt = await fetch_extent(main_pool)
    log(f"dataset_version locked: {dataset_version}")

    ndvi_min = args.ndvi_min
    ndvi_max = args.ndvi_max
    log(
        f"mode={'APPLY' if args.apply else 'DRY-RUN (no writes)'} "
        f"chunk={args.chunk_size} buffer={args.buffer_m:.0f}m "
        f"NDVI maps [{ndvi_min}, {ndvi_max}] -> [0, 100]"
    )

    sidecar_pool = None
    if args.apply:
        sidecar_pool = await open_sidecar_pool(sha_de_db_url)
        async with sidecar_pool.acquire() as conn:
            await conn.execute(SIDECAR_ENSURE_TABLE)
        log("Sidecar connected: table segment_shade verified.")

    if args.ids:
        base = ",".join(str(i) for i in sorted(set(args.ids)))
        id_filter_sql = f"WHERE id IN ({base}) ORDER BY id ASC"
        fetch_sql = (
            f"SELECT id, osm_way_id, dataset_version, ST_AsText(geometry) AS wkt "
            f"FROM road_segments {id_filter_sql}"
        )
    else:
        fetch_sql = None

    date_end = args.end or datetime.now(timezone.utc).strftime("%Y-%m-%d")
    date_start = args.start or (
        (datetime.now(timezone.utc) - timedelta(days=args.days)).strftime("%Y-%m-%d")
    )
    log(f"Sentinel-2 composite window: {date_start} .. {date_end}")

    composite = await asyncio.to_thread(
        GEEComposite, extent_wkt, date_start, date_end, args.buffer_m
    )

    last_id = 0
    if args.resume and STATE_PATH.exists():
        try:
            state = json.loads(STATE_PATH.read_text())
            last_id = int(state.get("last_id", 0))
            log(f"--resume: continuing after segment id {last_id}")
        except (ValueError, json.JSONDecodeError):
            log("--resume: unreadable state file, starting from 0")
    processed = 0
    gee_scored = 0
    fallback_osm = 0
    total_shade = 0.0
    upserts_proposed = 0
    pending_upserts: list[dict] = []
    start_time = time.time()

    state = {"mode": "apply" if args.apply else "dry-run", "last_id": 0}
    if args.apply:
        OUT_DIR.mkdir(exist_ok=True)

    while True:
        if fetch_sql:
            rows = await fetch_payload(main_pool, fetch_sql)
            exhausted = True
        else:
            rows = await fetch_chunk(main_pool, last_id, args.chunk_size)
            exhausted = len(rows) < args.chunk_size
            if args.limit and processed + len(rows) >= args.limit:
                rows = rows[: args.limit - processed]
                exhausted = True

        if not rows:
            break

        wkt_list = [r["wkt"] for r in rows]
        raw = await asyncio.to_thread(
            score_chunk_with_retry, composite, wkt_list, args.max_retries
        )

        for db_row, result in zip(rows, raw):
            ndvi = result.get("ndvi")
            validity = result.get("validity") or 0.0
            processed += 1
            if ndvi is None or validity < args.min_validity:
                fallback_osm += 1
                continue
            shade = calibrate_ndvi(float(ndvi), ndvi_min, ndvi_max)
            gee_scored += 1
            total_shade += shade
            upserts_proposed += 1
            pending_upserts.append(
                {
                    "segment_id": int(db_row["id"]),
                    "dataset_version": dataset_version,
                    "shade_score": round(shade, 1),
                }
            )

        if args.apply:
            await write_sidecar_rows(sidecar_pool, pending_upserts)
            pending_upserts = []
            last_id = int(rows[-1]["id"])
            state["last_id"] = last_id
            STATE_PATH.write_text(json.dumps(state))
        else:
            pending_upserts = []  # dry-run: never stage writes across chunks

        log(
            f"  chunk done: processed {processed:,} | gee {gee_scored:,} | "
            f"fallback(OSM) {fallback_osm:,} | {time.time() - start_time:.0f}s elapsed"
        )

        if exhausted:
            break

    mean_shade = (total_shade / gee_scored) if gee_scored else 0.0
    summary = (
        "\n" + "=" * 60 + "\n"
        f"Satellite shade run ({'APPLY' if args.apply else 'DRY-RUN — NO WRITES'})\n"
        f"dataset_version        : {dataset_version}\n"
        f"segments processed     : {processed:,}\n"
        f"GEE-scored             : {gee_scored:,} (mean shade {mean_shade:.1f})\n"
        f"fallback kept OSM      : {fallback_osm:,}\n"
        f"proposed sidecar upsert: {upserts_proposed:,}\n"
        f"sidecar writes done    : {upserts_proposed if args.apply else 0:,}\n"
        + "=" * 60 + "\n"
    )
    print(summary)
    OUT_DIR.mkdir(exist_ok=True)
    REPORT_PATH.write_text(summary, encoding="utf-8")

    await main_pool.close()
    if sidecar_pool:
        await sidecar_pool.close()
    return 0


async def fetch_payload(main_pool, sql: str):
    async with main_pool.acquire() as conn:
        return await conn.fetch(sql)


def parse_args(argv):
    parser = argparse.ArgumentParser(description="GEE satellite shade batch (sidecar-only writes)")
    parser.add_argument("--apply", action="store_true",
                        help="enable sidecar writes (default: dry-run)")
    parser.add_argument("--ids", type=lambda s: [int(x) for x in s.split(",")],
                        help="explicit road_segment ids, comma separated (pilot)")
    parser.add_argument("--pilot", type=int, metavar="N",
                        help="first N segments by id — low-risk visible-route validation")
    parser.add_argument("--limit", type=int, metavar="N",
                        help="cap the number of segments processed")
    parser.add_argument("--chunk-size", type=int, default=DEFAULT_CHUNK_SIZE)
    parser.add_argument("--buffer-m", type=float, default=DEFAULT_BUFFER_M)
    parser.add_argument("--ndvi-min", type=float, default=DEFAULT_NDVI_MIN)
    parser.add_argument("--ndvi-max", type=float, default=DEFAULT_NDVI_MAX)
    parser.add_argument("--min-validity", type=float, default=DEFAULT_MIN_PIXEL_VALIDITY)
    parser.add_argument("--days", type=int, default=365,
                        help="composite window length in days (default 365)")
    parser.add_argument("--start", type=str, default=None)
    parser.add_argument("--end", type=str, default=None)
    parser.add_argument("--max-retries", type=int, default=5)
    parser.add_argument("--resume", action="store_true",
                        help="continue an interrupted --apply run from the state file")
    parser.add_argument("--project", type=str, default=None)
    parser.add_argument("--key-path", type=str, default=None)
    args = parser.parse_args(argv)
    if args.pilot:
        args.limit = min(args.limit or args.pilot, args.pilot)
        args.chunk_size = min(args.chunk_size, args.pilot)
    return args


def main() -> None:
    from dotenv import load_dotenv

    load_dotenv(dotenv_path=Path(__file__).resolve().parent.parent / "backend" / ".env")
    asyncio.run(run(parse_args(sys.argv[1:])))


if __name__ == "__main__":
    main()
