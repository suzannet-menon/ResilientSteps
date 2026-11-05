"""Evaluation: do verified reports actually move route scores?

For every verified *safety* report in the live DB, this script scores a small
route passing through the report's coordinates and prints the before/after
numbers the app receives:

    base_safety_score  = route score WITHOUT any verified-report penalties
    safety_score       = route score WITH them (what the UI shows)
    incident_score_delta = before - after

Each candidate route uses the report coordinate as its midpoint and extends
roughly 200 m along a NW-SE diagonal, so the same road segment that the
report matched (30 m tolerance in get_segment_incident_aggregates) is almost
always matched by the route itself (20 m tolerance).

Read-only: only SELECTs and in-memory score_route calls; nothing is written.

Run:  cd D:\ResilientSteps\backend
      .\.venv\Scripts\python.exe scripts\eval_verified_report_impact.py
"""

import asyncio
import sys
import textwrap
from pathlib import Path

BACKEND_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BACKEND_ROOT))

from sqlalchemy import text  # noqa: E402

from app.modules.walksafe.services.risk_engine import score_route  # noqa: E402


# Points within this many degrees (~22 m) of each other collapse into one
# evaluation coordinate, matching MATCH tolerance better than exact equality.
CLUSTER_ROUNDING_DEGREES = 0.00020
ROUTE_HALF_EXTENT_DEGREES = 0.001

SAFETY_FACTOR_SQL = text(
    """
    SELECT
        id::text AS id,
        category,
        COALESCE(severity, 3) AS severity,
        COALESCE(confidence, 0.5) AS confidence,
        ST_Y(location) AS lat,
        ST_X(location) AS lon
    FROM incident_reports
    WHERE LOWER(COALESCE(status, 'pending')) = 'verified'
      AND COALESCE(report_type, 'safety') = 'safety'
    ORDER BY submitted_at DESC
    """
)


def _summarize_report_row(row) -> dict:
    m = row._mapping
    return {
        "id": str(m["id"]),
        "category": str(m["category"]),
        "severity": int(m["severity"]),
        "confidence": float(m["confidence"]),
        "lat": float(m["lat"]),
        "lon": float(m["lon"]),
    }


def _dedupe_coordinates(reports: list[dict]) -> dict[str, list[dict]]:
    clusters: dict[str, list[dict]] = {}
    for report in reports:
        key = (
            f"{round(report['lat'] / CLUSTER_ROUNDING_DEGREES) * CLUSTER_ROUNDING_DEGREES:.5f},"
            f"{round(report['lon'] / CLUSTER_ROUNDING_DEGREES) * CLUSTER_ROUNDING_DEGREES:.5f}"
        )
        clusters.setdefault(key, []).append(report)
    return clusters


def _diagonal_through(
    lat: float,
    lon: float,
    lat_sign: float = 1.0,
    lon_sign: float = 1.0,
) -> list[tuple[float, float]]:
    """Two waypoints ~440 m apart with the report coordinate in between."""
    lat = round(lat, 6)
    lon = round(lon, 6)
    return [
        (
            lat - lat_sign * ROUTE_HALF_EXTENT_DEGREES,
            lon - lon_sign * ROUTE_HALF_EXTENT_DEGREES,
        ),
        (
            lat + lat_sign * ROUTE_HALF_EXTENT_DEGREES,
            lon + lon_sign * ROUTE_HALF_EXTENT_DEGREES,
        ),
    ]


def _points_on_route(scored: dict, lat: float, lon: float) -> list[dict]:
    points = scored.get("incident_points") or []
    tolerance = 0.0005
    matched = []
    for point in points:
        if abs(float(point["lat"]) - lat) <= tolerance and abs(
            float(point["lon"]) - lon
        ) <= tolerance:
            matched.append(point)
    return matched


def _fmt(value, suffix: str = "") -> str:
    return "-" if value is None else f"{value}{suffix}"


async def main() -> int:
    from app.core.database import AsyncSessionLocal

    async with AsyncSessionLocal() as db:
        rows = (await db.execute(SAFETY_FACTOR_SQL)).fetchall()
        reports = [_summarize_report_row(row) for row in rows]
        if not reports:
            print("No verified safety reports found - nothing to evaluate.")
            return 1

        print(f"Verified safety reports found: {len(reports)}")
        print("=" * 78)
        failures = 0
        unmatched_clusters = 0
        for cluster_key, cluster in _dedupe_coordinates(reports).items():
            repr_row = cluster[0]
            lat, lon = repr_row["lat"], repr_row["lon"]
            scored = await score_route(_diagonal_through(lat, lon), db)
            if (scored.get("matched_segment_count") or 0) == 0:
                # NE-SW attempt failed; try the three other orientations so a
                # coverage miss cannot be confused with a scoring miss.
                for lat_sign, lon_sign in (
                    (1.0, -1.0),
                    (-1.0, 1.0),
                    (-1.0, -1.0),
                ):
                    scored = await score_route(
                        _diagonal_through(lat, lon, lat_sign, lon_sign), db
                    )
                    if (scored.get("matched_segment_count") or 0) > 0:
                        break

            before = scored.get("base_safety_score")
            after = scored.get("safety_score")
            delta = scored.get("incident_score_delta")
            matched_segments = scored.get("matched_segment_count", 0)
            total_penalty = sum(
                float(seg.get("incident_penalty") or 0.0)
                for seg in scored.get("segments", [])
            )
            matched = bool(scored.get("matched_segment_count"))
            on_route = _points_on_route(scored, lat, lon)
            self_mapped = bool(on_route)
            if not matched:
                unmatched_clusters += 1
            if delta and delta < 0.5:
                failures += 1

            print(
                f"[{cluster_key}] {len(cluster)} report(s) "
                f"@( {lat:.5f}, {lon:.5f} )"
            )
            for report in cluster:
                print(
                    textwrap.indent(
                        f"- #{report['id']} {report['category']} "
                        f"severity {report['severity']} "
                        f"(confidence {report['confidence']:.2f})",
                        prefix="    ",
                    )
                )
            if delta is None:
                delta_text = "n/a"
            else:
                delta_text = f"{delta:+}"
            print(
                f"    before -> after : {before} -> {after} "
                f"(delta {delta_text} pts)"
            )
            print(
                f"    route segments  : {matched_segments}/{scored.get('segment_count', 0)} matched, "
                f"penalty sum {total_penalty:+.1f} pts"
            )
            print(
                f"    points mapped   : "
                f"{len(scored.get('incident_points') or [])} "
                f"(self mapped: {'YES' if self_mapped else 'NO'})"
            )
            if not self_mapped:
                print(
                    "    NOTE: the report's own coordinate is not among the "
                    "mapped points; the route likely matched a different "
                    "nearby segment (or none)."
                )
            print("-" * 78)

        print()
        print(
            f"Evaluation done. {failures} coordinate(s) showed a delta below "
            "0.5 pts (expected where the report pairs with no road segment); "
            f"{unmatched_clusters} cluster(s) remained unmatched after all 4 "
            "orientations - those streets have no scored road_segments row "
            "within 20 m yet."
        )
        return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
