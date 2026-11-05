import json
import logging
from typing import Any, Dict, List

from sqlalchemy import bindparam, text
from sqlalchemy.ext.asyncio import AsyncSession

LOGGER = logging.getLogger(__name__)

from app.modules.walksafe.schemas.reports import (
    EmergencyAlertCreate,
    ReportCreate,
    TrustedContactPayload,
)

INCIDENT_MATCH_DISTANCE_METERS = 30.0
INCIDENT_SEARCH_EXPAND_DEGREES = 0.0005

SHADE_OBSERVATION_PENALTY = 10.0
MAX_SHADE_OBSERVATION_PENALTY = 25.0
COOL_SPOT_BONUS = 5.0
MAX_COOL_SPOT_BONUS = 10.0


SEGMENT_INCIDENT_AGGREGATES_QUERY = text(
    """
    WITH route_segments AS (
        SELECT id, geometry
        FROM road_segments
        WHERE dataset_version = :dataset_version
        AND id IN :road_segment_ids
    ),
    route_bounds AS (
        SELECT ST_Envelope(ST_Collect(geometry)) AS route_bbox
        FROM route_segments
    ),
    matched_incidents AS (
        SELECT
            nearest.road_segment_id,
            report.id AS incident_id,
            report.category,
            COALESCE(report.confidence, :default_confidence) AS confidence,
            COALESCE(report.status, 'pending') AS status,
            report.submitted_at
        FROM incident_reports report
        CROSS JOIN route_bounds bounds
        JOIN LATERAL (
            SELECT
                rs.id AS road_segment_id,
                ST_Distance(rs.geometry::geography, report.location) AS distance_m
            FROM route_segments rs
            WHERE rs.geometry && ST_Expand(
                report.location::geometry,
                :incident_search_expand_degrees
            )
            ORDER BY rs.geometry <-> report.location::geometry
            LIMIT 1
        ) AS nearest ON TRUE
        WHERE bounds.route_bbox IS NOT NULL
        AND report.location::geometry && ST_Expand(
            bounds.route_bbox,
            :incident_search_expand_degrees
        )
        AND nearest.distance_m <= :incident_match_distance_m
        AND LOWER(COALESCE(report.status, 'pending')) = 'verified'
        AND COALESCE(report.report_type, 'safety') = 'safety'
    )
    SELECT
        road_segment_id,
        COUNT(*) AS incident_count,
        ROUND(
            SUM(
                confidence
                * CASE
                    WHEN submitted_at >= NOW() - INTERVAL '7 days' THEN 1.0
                    WHEN submitted_at >= NOW() - INTERVAL '30 days' THEN 0.8
                    WHEN submitted_at >= NOW() - INTERVAL '90 days' THEN 0.55
                    ELSE 0.3
                END
                * CASE category
                    WHEN 'Stalking' THEN 1.0
                    WHEN 'Harassment' THEN 0.9
                    WHEN 'Suspicious Activity' THEN 0.8
                    WHEN 'Unsafe infrastructure' THEN 0.7
                    WHEN 'Poor lighting' THEN 0.6
                    WHEN 'no_shade' THEN 0.0
                    WHEN 'No shade / heavy sun' THEN 0.0
                    WHEN 'shade_obstruction' THEN 0.0
                    WHEN 'Shade blocked (overgrown / construction)' THEN 0.0
                    WHEN 'heat_stress' THEN 0.0
                    WHEN 'Heat stress / too hot to walk' THEN 0.0
                    WHEN 'cool_spot' THEN 0.0
                    WHEN 'Cool shaded spot / water available' THEN 0.0
                    ELSE 0.65
                END
            )::numeric,
            3
        ) AS incident_weight,
        MAX(submitted_at) AS latest_incident_at,
        ARRAY_REMOVE(ARRAY_AGG(DISTINCT category), NULL) AS incident_categories
    FROM matched_incidents
    GROUP BY road_segment_id
    """
).bindparams(bindparam("road_segment_ids", expanding=True))

SEGMENT_SHADE_CORRECTIONS_QUERY = text(
    """
    WITH route_segments AS (
        SELECT id, geometry
        FROM road_segments
        WHERE dataset_version = :dataset_version
        AND id IN :road_segment_ids
    ),
    route_bounds AS (
        SELECT ST_Envelope(ST_Collect(geometry)) AS route_bbox
        FROM route_segments
    ),
    matched_observations AS (
        SELECT
            nearest.road_segment_id,
            report.category,
            COALESCE(report.status, 'pending') AS status
        FROM incident_reports report
        CROSS JOIN route_bounds bounds
        JOIN LATERAL (
            SELECT
                rs.id AS road_segment_id,
                ST_Distance(rs.geometry::geography, report.location) AS distance_m
            FROM route_segments rs
            WHERE rs.geometry && ST_Expand(
                report.location::geometry,
                :incident_search_expand_degrees
            )
            ORDER BY rs.geometry <-> report.location::geometry
            LIMIT 1
        ) AS nearest ON TRUE
        WHERE bounds.route_bbox IS NOT NULL
        AND report.location::geometry && ST_Expand(
            bounds.route_bbox,
            :incident_search_expand_degrees
        )
        AND nearest.distance_m <= :incident_match_distance_m
        AND LOWER(COALESCE(report.status, 'pending')) = 'verified'
        AND COALESCE(report.report_type, 'safety') = 'safety'
        AND LOWER(report.category) IN (
            'no_shade',
            'no shade / heavy sun',
            'shade_obstruction',
            'shade blocked (overgrown / construction)',
            'cool_spot',
            'cool shaded spot / water available'
        )
    )
    SELECT
        road_segment_id,
        SUM(
            CASE
                WHEN LOWER(category) IN (
                    'no_shade',
                    'no shade / heavy sun',
                    'shade_obstruction',
                    'shade blocked (overgrown / construction)'
                ) THEN :shade_observation_penalty
                WHEN LOWER(category) IN (
                    'cool_spot',
                    'cool shaded spot / water available'
                ) THEN :cool_spot_bonus
                ELSE 0.0
            END
        )::numeric AS shade_correction
    FROM matched_observations
    GROUP BY road_segment_id
    """
).bindparams(bindparam("road_segment_ids", expanding=True))

class ReportingService:
    def __init__(self) -> None:
        self.base_confidence = 0.5

    def _normalize_trusted_contacts(
        self,
        trusted_contacts: List[str | TrustedContactPayload],
    ) -> List[str | Dict[str, str]]:
        normalized_contacts: List[str | Dict[str, str]] = []
        seen_contacts: set[str] = set()
        for raw_contact in trusted_contacts:
            if isinstance(raw_contact, str):
                contact = raw_contact.strip()
                if not contact:
                    continue
                contact_key = contact.casefold()
                if contact_key in seen_contacts:
                    continue
                seen_contacts.add(contact_key)
                normalized_contacts.append(contact)
                continue

            if isinstance(raw_contact, TrustedContactPayload):
                name = raw_contact.name.strip()
                phone = raw_contact.phone.strip()
            else:
                continue

            if not name or not phone:
                continue

            contact_key = f"{name.casefold()}|{phone.casefold()}"
            if contact_key in seen_contacts:
                continue
            seen_contacts.add(contact_key)
            normalized_contacts.append({"name": name, "phone": phone})
        return normalized_contacts

    async def create_report(
        self,
        report: Any,
        db: AsyncSession,
        *,
        report_type: str = "safety",
        severity: int = 3,
    ) -> Dict[str, Any]:
        severity_val = getattr(report, "severity", severity)
        report_type_val = getattr(report, "report_type", report_type)
        result = await db.execute(
            text(
                """
                INSERT INTO incident_reports (
                    user_hash,
                    category,
                    description,
                    location,
                    status,
                    confidence,
                    report_type,
                    severity
                )
                VALUES (
                    :user_hash,
                    :category,
                    :description,
                    ST_SetSRID(ST_MakePoint(:lon, :lat), 4326),
                    'pending',
                    :confidence,
                    :report_type,
                    :severity
                )
                RETURNING id::text AS id, status, confidence, submitted_at
                """
            ),
            {
                "user_hash": report.user_hash,
                "category": report.category,
                "description": report.description,
                "lon": report.lon,
                "lat": report.lat,
                "confidence": self.base_confidence,
                "report_type": report_type_val,
                "severity": severity_val,
            },
        )
        row = result.fetchone()
        if row is None:
            raise RuntimeError("Incident report insert returned no row.")
        return dict(row._mapping)

    async def get_recent_reports(
        self,
        *,
        limit: int,
        db: AsyncSession,
        report_type: str | None = "safety",
    ) -> List[Dict[str, Any]]:
        where_clause = "WHERE status = 'verified'"
        params: Dict[str, Any] = {"limit": int(limit)}
        if report_type is not None:
            where_clause += " AND COALESCE(report_type, 'safety') = :report_type"
            params["report_type"] = report_type

        result = await db.execute(
            text(
                f"""
                SELECT
                    id::text AS id,
                    ST_Y(location) AS lat,
                    ST_X(location) AS lon,
                    category AS incident_type,
                    COALESCE(severity, 3) AS severity,
                    confidence AS confidence_score,
                    submitted_at AS created_at,
                    status
                FROM incident_reports
                {where_clause}
                ORDER BY submitted_at DESC
                LIMIT :limit
                """
            ),
            params,
        )
        rows = result.fetchall()
        return [dict(row._mapping) for row in rows]

    async def get_segment_incident_aggregates(
        self,
        *,
        road_segment_ids: List[int],
        dataset_version: str | None,
        db: AsyncSession,
    ) -> Dict[int, Dict[str, Any]]:
        if not road_segment_ids or not dataset_version:
            return {}

        query = SEGMENT_INCIDENT_AGGREGATES_QUERY

        result = await db.execute(
            query,
            {
                "dataset_version": dataset_version,
                "road_segment_ids": [int(segment_id) for segment_id in road_segment_ids],
                "default_confidence": self.base_confidence,
                "incident_match_distance_m": INCIDENT_MATCH_DISTANCE_METERS,
                "incident_search_expand_degrees": INCIDENT_SEARCH_EXPAND_DEGREES,
            },
        )

        aggregates: Dict[int, Dict[str, Any]] = {}
        for row in result.fetchall():
            mapping = row._mapping
            latest_incident_at = mapping["latest_incident_at"]
            categories = mapping["incident_categories"] or []
            aggregates[int(mapping["road_segment_id"])] = {
                "incident_count": int(mapping["incident_count"]),
                "incident_weight": float(mapping["incident_weight"] or 0.0),
                "incident_categories": [str(category) for category in categories],
                "latest_incident_at": (
                    latest_incident_at.isoformat()
                    if latest_incident_at is not None
                    else None
                ),
            }

        return aggregates

    async def get_segment_shade_corrections(
        self,
        *,
        road_segment_ids: List[int],
        dataset_version: str | None,
        db: AsyncSession,
    ) -> Dict[int, float]:
        if not road_segment_ids or not dataset_version:
            return {}

        query = SEGMENT_SHADE_CORRECTIONS_QUERY

        result = await db.execute(
            query,
            {
                "dataset_version": dataset_version,
                "road_segment_ids": [int(segment_id) for segment_id in road_segment_ids],
                "incident_match_distance_m": INCIDENT_MATCH_DISTANCE_METERS,
                "incident_search_expand_degrees": INCIDENT_SEARCH_EXPAND_DEGREES,
                "shade_observation_penalty": -SHADE_OBSERVATION_PENALTY,
                "cool_spot_bonus": COOL_SPOT_BONUS,
            },
        )

        corrections: Dict[int, float] = {}
        for row in result.fetchall():
            mapping = row._mapping
            correction = float(mapping["shade_correction"] or 0.0)
            corrections[int(mapping["road_segment_id"])] = max(
                -MAX_SHADE_OBSERVATION_PENALTY,
                min(MAX_COOL_SPOT_BONUS, correction),
            )
        return corrections

    async def create_emergency_alert(
        self,
        alert: EmergencyAlertCreate,
        db: AsyncSession,
    ) -> Dict[str, Any]:
        trusted_contacts = self._normalize_trusted_contacts(alert.trusted_contacts)
        notified_contacts = trusted_contacts[:]
        contacts_notified = len(notified_contacts)

        LOGGER.info(
            "Emergency alert created for user %s. (Note: SMS dispatch is mocked for local development; "
            "no SMS gateway integration Twilio/SNS is connected. Contacts stored: %s)",
            alert.user_hash,
            notified_contacts,
        )

        metadata = dict(alert.metadata)
        metadata["source"] = metadata.get("source", "mobile_app")
        metadata["trusted_contacts"] = trusted_contacts
        metadata["trusted_contacts_notified"] = notified_contacts

        result = await db.execute(
            text(
                """
                INSERT INTO emergency_alerts (
                    user_hash,
                    latitude,
                    longitude,
                    status,
                    message,
                    contacts_notified,
                    metadata
                )
                VALUES (
                    :user_hash,
                    :lat,
                    :lon,
                    'triggered',
                    :message,
                    :contacts_notified,
                    CAST(:metadata AS JSONB)
                )
                RETURNING id::text AS id, status, created_at, contacts_notified, metadata
                """
            ),
            {
                "user_hash": alert.user_hash,
                "lat": alert.lat,
                "lon": alert.lon,
                "message": alert.message or "Emergency alert triggered",
                "contacts_notified": contacts_notified,
                "metadata": json.dumps(metadata),
            },
        )
        row = result.fetchone()
        if row is None:
            raise RuntimeError("Emergency alert insert returned no row.")
        payload = dict(row._mapping)
        payload["message"] = alert.message or "Emergency alert triggered"
        payload["trusted_contacts"] = notified_contacts
        return payload


reporting_service = ReportingService()
