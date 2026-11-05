import logging
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Tuple
import h3
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

LOGGER = logging.getLogger(__name__)

CITY_SUMMARY_QUERY = text(
    """
    SELECT
        COALESCE(report_type, 'safety') AS report_type,
        COALESCE(status, 'pending') AS status,
        COALESCE(severity, 3) AS severity,
        COUNT(*) AS cnt
    FROM incident_reports
    GROUP BY COALESCE(report_type, 'safety'), COALESCE(status, 'pending'), COALESCE(severity, 3)
    """
)

AVG_MODERATION_HOURS_QUERY = text(
    """
    SELECT AVG(EXTRACT(EPOCH FROM (moderated_at - submitted_at)) / 3600.0) AS avg_hours
    FROM incident_reports
    WHERE moderated_at IS NOT NULL
    """
)

HEATMAP_REPORTS_QUERY = text(
    """
    SELECT
        ST_Y(location) AS lat,
        ST_X(location) AS lon,
        COALESCE(report_type, 'safety') AS report_type,
        COALESCE(severity, 3) AS severity
    FROM incident_reports
    WHERE status = 'verified'
    """
)

ALL_REPORTS_EXPORT_QUERY = text(
    """
    SELECT
        id::text AS id,
        user_hash,
        category,
        description,
        ST_Y(location) AS latitude,
        ST_X(location) AS longitude,
        status,
        confidence,
        COALESCE(severity, 3) AS severity,
        COALESCE(report_type, 'safety') AS report_type,
        submitted_at,
        moderated_at
    FROM incident_reports
    ORDER BY submitted_at DESC
    """
)

REFRESH_WARD_SUMMARY_QUERY = text("REFRESH MATERIALIZED VIEW ward_report_summary;")


class AnalyticsService:
    async def get_city_summary(self, db: AsyncSession) -> Dict[str, Any]:
        result = await db.execute(CITY_SUMMARY_QUERY)
        rows = result.fetchall()

        total_reports = 0
        pending_count = 0
        verified_count = 0
        rejected_count = 0
        by_type: Dict[str, int] = {}
        by_severity: Dict[int, int] = {i: 0 for i in range(1, 6)}

        for row in rows:
            m = row._mapping
            rtype = str(m["report_type"])
            st = str(m["status"])
            sev = int(m["severity"])
            cnt = int(m["cnt"])

            total_reports += cnt
            if st == "pending":
                pending_count += cnt
            elif st == "verified":
                verified_count += cnt
            elif st == "rejected":
                rejected_count += cnt

            by_type[rtype] = by_type.get(rtype, 0) + cnt
            if 1 <= sev <= 5:
                by_severity[sev] += cnt

        avg_hours: Optional[float] = None
        try:
            time_res = await db.execute(AVG_MODERATION_HOURS_QUERY)
            t_row = time_res.fetchone()
            if t_row and t_row._mapping["avg_hours"] is not None:
                avg_hours = round(float(t_row._mapping["avg_hours"]), 2)
        except Exception as exc:
            LOGGER.warning("Could not calculate avg verification hours: %s", exc)

        return {
            "total_reports": total_reports,
            "pending_count": pending_count,
            "verified_count": verified_count,
            "rejected_count": rejected_count,
            "by_type": by_type,
            "by_severity": by_severity,
            "average_verification_hours": avg_hours,
        }

    async def get_ward_summaries(self, db: AsyncSession) -> List[Dict[str, Any]]:
        try:
            result = await db.execute(
                text(
                    """
                    SELECT
                        ward_id,
                        ward_name,
                        report_type,
                        status,
                        report_count,
                        avg_severity,
                        latest_report_at
                    FROM ward_report_summary
                    """
                )
            )
            rows = result.fetchall()
            if rows:
                wards: Dict[str, Dict[str, Any]] = {}
                for row in rows:
                    m = row._mapping
                    wid = str(m["ward_id"])
                    if wid not in wards:
                        wards[wid] = {
                            "ward_id": wid,
                            "ward_name": str(m["ward_name"]),
                            "report_count": 0,
                            "avg_severity": 0.0,
                            "latest_report_at": None,
                            "breakdown": {},
                            "_sev_sum": 0.0,
                        }
                    cnt = int(m["report_count"])
                    rtype = str(m["report_type"])
                    wards[wid]["report_count"] += cnt
                    wards[wid]["breakdown"][rtype] = wards[wid]["breakdown"].get(rtype, 0) + cnt
                    wards[wid]["_sev_sum"] += float(m["avg_severity"] or 3.0) * cnt
                    lat_at = m["latest_report_at"]
                    if lat_at and (wards[wid]["latest_report_at"] is None or lat_at > wards[wid]["latest_report_at"]):
                        wards[wid]["latest_report_at"] = lat_at

                res_list = []
                for wid, wdata in wards.items():
                    if wdata["report_count"] > 0:
                        wdata["avg_severity"] = round(wdata["_sev_sum"] / wdata["report_count"], 2)
                    del wdata["_sev_sum"]
                    res_list.append(wdata)
                return res_list
        except Exception as exc:
            LOGGER.warning("Materialized view query failed or empty; falling back: %s", exc)

        try:
            res = await db.execute(
                text(
                    """
                    SELECT
                        w.ward_id,
                        w.ward_name,
                        COALESCE(ir.report_type, 'safety') AS report_type,
                        COUNT(ir.id) AS report_count,
                        AVG(COALESCE(ir.severity, 3)) AS avg_severity,
                        MAX(ir.submitted_at) AS latest_report_at
                    FROM wards w
                    LEFT JOIN incident_reports ir ON ST_Contains(w.geometry, ir.location::geometry)
                    GROUP BY w.ward_id, w.ward_name, COALESCE(ir.report_type, 'safety')
                    """
                )
            )
            rows = res.fetchall()
            wards = {}
            for row in rows:
                m = row._mapping
                wid = str(m["ward_id"])
                if wid not in wards:
                    wards[wid] = {
                        "ward_id": wid,
                        "ward_name": str(m["ward_name"]),
                        "report_count": 0,
                        "avg_severity": 0.0,
                        "latest_report_at": None,
                        "breakdown": {},
                        "_sev_sum": 0.0,
                    }
                cnt = int(m["report_count"])
                rtype = str(m["report_type"])
                if cnt > 0:
                    wards[wid]["report_count"] += cnt
                    wards[wid]["breakdown"][rtype] = wards[wid]["breakdown"].get(rtype, 0) + cnt
                    wards[wid]["_sev_sum"] += float(m["avg_severity"] or 3.0) * cnt
                    lat_at = m["latest_report_at"]
                    if lat_at and (wards[wid]["latest_report_at"] is None or lat_at > wards[wid]["latest_report_at"]):
                        wards[wid]["latest_report_at"] = lat_at

            res_list = []
            for wid, wdata in wards.items():
                if wdata["report_count"] > 0:
                    wdata["avg_severity"] = round(wdata["_sev_sum"] / wdata["report_count"], 2)
                del wdata["_sev_sum"]
                res_list.append(wdata)
            return res_list
        except Exception as err:
            LOGGER.warning("Could not execute ward query: %s", err)
            return []

    async def get_ward_reports(self, ward_id: str, db: AsyncSession) -> List[Dict[str, Any]]:
        result = await db.execute(
            text(
                """
                SELECT
                    ir.id::text AS id,
                    ir.user_hash,
                    ir.category,
                    ir.description,
                    ST_Y(ir.location) AS latitude,
                    ST_X(ir.location) AS longitude,
                    ir.status,
                    COALESCE(ir.severity, 3) AS severity,
                    COALESCE(ir.report_type, 'safety') AS report_type,
                    ir.submitted_at
                FROM incident_reports ir
                JOIN wards w ON ST_Contains(w.geometry, ir.location::geometry)
                WHERE w.ward_id = :ward_id
                ORDER BY ir.submitted_at DESC
                """
            ),
            {"ward_id": ward_id},
        )
        return [dict(row._mapping) for row in result.fetchall()]

    async def get_trends(self, since: Optional[str], db: AsyncSession) -> List[Dict[str, Any]]:
        where_clause = ""
        params: Dict[str, Any] = {}
        if since:
            where_clause = "WHERE submitted_at >= :since"
            params["since"] = since

        result = await db.execute(
            text(
                f"""
                SELECT
                    TO_CHAR(submitted_at, 'YYYY-MM-DD') AS date,
                    COALESCE(report_type, 'safety') AS report_type,
                    COUNT(*) AS count
                FROM incident_reports
                {where_clause}
                GROUP BY date, report_type
                ORDER BY date ASC
                """
            ),
            params,
        )
        return [dict(row._mapping) for row in result.fetchall()]

    async def get_heatmap(self, db: AsyncSession, resolution: int = 8) -> List[Dict[str, Any]]:
        result = await db.execute(HEATMAP_REPORTS_QUERY)
        rows = result.fetchall()
        cells: Dict[Tuple[str, str], Dict[str, Any]] = {}

        for row in rows:
            m = row._mapping
            lat = float(m["lat"])
            lon = float(m["lon"])
            rtype = str(m["report_type"])
            sev = int(m["severity"])

            cell_id = h3.latlng_to_cell(lat, lon, resolution)
            key = (cell_id, rtype)
            if key not in cells:
                center_lat, center_lon = h3.cell_to_latlng(cell_id)
                cells[key] = {
                    "h3_index": cell_id,
                    "lat": center_lat,
                    "lon": center_lon,
                    "report_type": rtype,
                    "count": 0,
                    "sev_sum": 0,
                }
            cells[key]["count"] += 1
            cells[key]["sev_sum"] += sev

        res = []
        for (cell_id, rtype), data in cells.items():
            avg_sev = data["sev_sum"] / data["count"]
            weight = round(data["count"] * (avg_sev / 3.0), 2)
            res.append(
                {
                    "h3_index": cell_id,
                    "lat": data["lat"],
                    "lon": data["lon"],
                    "report_type": rtype,
                    "weight": weight,
                }
            )
        return res

    async def get_all_reports_for_export(self, db: AsyncSession) -> List[Dict[str, Any]]:
        result = await db.execute(ALL_REPORTS_EXPORT_QUERY)
        return [dict(row._mapping) for row in result.fetchall()]

    async def refresh_summary_view(self, db: AsyncSession) -> None:
        await db.execute(REFRESH_WARD_SUMMARY_QUERY)


analytics_service = AnalyticsService()
