"""Read-only scan to support the free-quota decision: which road_segment
classes are kill candidates and how much disk each class costs.

Prints ONLY aggregate numbers (no sizes in absolute env-sensitive form
beyond what is already public in LOCAL_SETUP_STATUS.md). No writes; no
.env values are ever shown - the backend config loader supplies credentials
in-process (user rule 2026-10-31: agent never reads backend\\.env).

Run:  cd D:\\ResilientSteps\\backend
      .\\.venv\\Scripts\\python.exe scripts\\db_trim_scan.py
"""

import asyncio
import sys
from pathlib import Path

BACKEND_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BACKEND_ROOT))

from sqlalchemy import text  # noqa: E402


async def main() -> None:
    from app.core.database import AsyncSessionLocal

    async with AsyncSessionLocal() as db:

        size = await db.execute(
            text(
                """
                SELECT
                    pg_database_size(current_database()) AS db_total,
                    pg_total_relation_size('road_segments') AS seg_total,
                    pg_relation_size('road_segments')      AS seg_table
                """
            )
        )
        s = size.one()._mapping
        db_total = int(s["db_total"])
        seg_total = int(s["seg_total"])
        seg_table = int(s["seg_table"])

        idx = await db.execute(
            text(
                """
                SELECT indexrelid::regclass::text AS idx,
                       pg_relation_size(indexrelid) AS bytes
                FROM pg_index
                WHERE indrelid = 'road_segments'::regclass
                ORDER BY bytes DESC
                """
            )
        )
        index_rows = idx.fetchall()
        idx_total = sum(int(r._mapping["bytes"]) for r in index_rows)

        count = await db.execute(text("SELECT count(*) FROM road_segments"))
        n_rows = int(count.scalar())

        # Real per-row all-in cost from live sizes, not a placeholder constant.
        per_row_all_in = (seg_total) / max(n_rows, 1)

        print("=" * 78)
        print(f"db_total          : {db_total/1048576:8.1f} MB")
        print(f"road_segments     : {seg_total/1048576:8.1f} MB "
              f"(table {seg_table/1048576:.1f} + indexes {idx_total/1048576:.1f})")
        print(f"rows              : {n_rows:,}")
        print(f"per-row all-in    : {per_row_all_in:8.0f} bytes")
        print("-" * 78)
        print("index breakdown (road_segments):")
        for r in index_rows:
            m = r._mapping
            print(f"  {m['idx']:<44} {int(m['bytes'])/1048576:7.1f} MB")
        print("=" * 78)

        rows = await db.execute(
            text(
                """
        SELECT
            COALESCE(road_type, '<null>') AS road_type,
            count(*)                      AS rows_n,
            count(*) FILTER (WHERE shade_score > 0) AS shade_kept,
            avg(ST_NPoints(geometry))     AS avg_pts
        FROM road_segments
        GROUP BY 1
        ORDER BY rows_n DESC
        """
            )
        )
        city_pts = await db.execute(
            text("SELECT avg(ST_NPoints(geometry)) FROM road_segments")
        )
        avg_pts_city = float(city_pts.scalar())
        per_row_vertex_share = max(avg_pts_city, 1.0)

        print(f"citywide avg_pts  : {avg_pts_city:8.1f}")
        print("-" * 78)
        print(f"{'road_type':<16}{'rows':>9}{'shade>0':>9}{'avg_pts':>9}{'est_mb':>10}")
        print("-" * 53)
        total_mb = 0.0
        for r in rows:
            m = r._mapping
            pts_ratio = float(m["avg_pts"]) / per_row_vertex_share
            est = int(m["rows_n"]) * per_row_all_in * min(pts_ratio, 2.0) / 1048576
            total_mb += est
            print(
                f"{str(m['road_type']):<16}"
                f"{int(m['rows_n']):>9,}"
                f"{int(m['shade_kept']):>9,}"
                f"{int(float(m['avg_pts'])):>9}"
                f"{est:>10.1f}"
            )
        print("-" * 53)
        print(f"estimate sum                 : {total_mb:8.1f} MB")
        print("est = rows x live per-row cost x vertex-share (capped 2x).")


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
