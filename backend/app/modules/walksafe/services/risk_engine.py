"""
Risk Engine - reads route safety from cached PostGIS-backed datasets.
Never generates, randomises, or invents safety scores.
"""

import asyncio
import logging

from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import get_scoring_config
from app.modules.walksafe.services import shade_sidecar
from app.modules.walksafe.services.reporting_service import reporting_service
from app.modules.walksafe.services.safety_dataset_cache import safety_dataset_cache
from app.modules.walksafe.services.weather_service import weather_service

LOGGER = logging.getLogger(__name__)

ROAD_MATCH_DISTANCE_METERS = 20.0
MIDPOINT_SEARCH_EXPAND_DEGREES = 0.0005
INCIDENT_PENALTY_SCALE = 12.0
MAX_INCIDENT_PENALTY = 25.0

_COMFORT_CONFIG = get_scoring_config().get("comfort") or {}


def _config_float(name: str, default: float) -> float:
    try:
        return float(_COMFORT_CONFIG.get(name, default))
    except (TypeError, ValueError):
        return default


SAFETY_WEIGHT = _config_float("safety_weight", 0.70)
SHADE_WEIGHT = _config_float("shade_weight", 0.20)
HEAT_WEIGHT = _config_float("heat_weight", 0.10)
HEAT_PENALTY_ENABLED = bool(_COMFORT_CONFIG.get("heat_penalty_enabled", True))

PREFER_OPTIONS = ("balanced", "safety", "shade", "heat")
PREFER_WEIGHTS = {
    "balanced": (SAFETY_WEIGHT, SHADE_WEIGHT, HEAT_WEIGHT),
    "safety": (0.90, 0.06, 0.04),
    "shade": (0.40, 0.50, 0.10),
    "heat": (0.50, 0.15, 0.35),
}

COMFORTABLE_THRESHOLD = 70.0
MODERATE_THRESHOLD = 40.0


def _calculate_incident_penalty(incident_weight: float) -> float:
    return min(MAX_INCIDENT_PENALTY, incident_weight * INCIDENT_PENALTY_SCALE)


def _comfort_score(
    safety: float | None,
    shade: float | None,
    heat_penalty: float,
    *,
    weights: tuple[float, float, float] | None = None,
) -> float | None:
    if safety is None:
        return None
    safety_weight, shade_weight, heat_weight = weights or (
        SAFETY_WEIGHT,
        SHADE_WEIGHT,
        HEAT_WEIGHT,
    )
    shade_value = shade if shade is not None else safety
    comfort = (
        safety_weight * safety
        + shade_weight * shade_value
        - heat_weight * heat_penalty
    )
    return max(0.0, min(100.0, comfort))


def _comfort_level(comfort_score: float | None) -> str | None:
    if comfort_score is None:
        return None
    if comfort_score >= COMFORTABLE_THRESHOLD:
        return "comfortable"
    if comfort_score >= MODERATE_THRESHOLD:
        return "moderate"
    return "harsh"


def _apply_shade_correction(
    shade: float | None,
    correction: float,
) -> float | None:
    if shade is None:
        return None
    return max(0.0, min(100.0, float(shade) + float(correction)))


def _weather_sample_points(
    coordinates: list[tuple[float, float]],
) -> list[tuple[float, float]]:
    if not coordinates:
        return []

    start = coordinates[0]
    end = coordinates[-1]
    centroid = (
        sum(lat for lat, _ in coordinates) / len(coordinates),
        sum(lon for _, lon in coordinates) / len(coordinates),
    )

    sample_points: list[tuple[float, float]] = []
    seen: set[tuple[float, float]] = set()
    for lat, lon in (start, centroid, end):
        key = (round(float(lat), 4), round(float(lon), 4))
        if key in seen:
            continue
        seen.add(key)
        sample_points.append((float(lat), float(lon)))
    return sample_points[:3]


async def _fetch_route_weather(
    coordinates: list[tuple[float, float]],
) -> list[dict]:
    if not HEAT_PENALTY_ENABLED:
        return []

    sample_points = _weather_sample_points(coordinates)
    if not sample_points:
        return []

    results = await asyncio.gather(
        *(
            weather_service.get_weather(lat, lon)
            for lat, lon in sample_points
        ),
        return_exceptions=True,
    )

    weather_by_point: list[dict] = []
    for result in results:
        if isinstance(result, Exception):
            LOGGER.warning(
                "Weather sample failed; heat term will be skipped for that point.",
                exc_info=result,
            )
            continue
        if result is not None:
            weather_by_point.append(result)
    return weather_by_point


async def score_route(
    coordinates: list[tuple[float, float]],
    db: AsyncSession,
    *,
    prefer: str = "balanced",
) -> dict:
    """
    Given a list of (lat, lon) waypoints, return the route's safety score.
    Score is derived from road_segments matched to the route geometry and
    adjusted by nearby incident reports.
    Returns None score (not zero) if no matching route safety data exists.
    """
    if prefer not in PREFER_OPTIONS:
        raise ValueError(
            f"Unsupported prefer value '{prefer}'. "
            f"Expected one of: {', '.join(PREFER_OPTIONS)}."
        )

    if not coordinates or len(coordinates) < 2:
        return {
            "safety_score": None,
            "comfort_score": None,
            "comfort_level": None,
            "weather": None,
            "segment_count": 0,
            "matched_segment_count": 0,
            "unmatched_segment_count": 0,
            "applied_incident_count": 0,
            "incident_affected_segment_count": 0,
            "base_safety_score": None,
            "incident_score_delta": None,
            "incident_points": [],
            "dataset_version": None,
            "segments": [],
            "warning": "Route has no coordinates",
        }

    comfort_weights = PREFER_WEIGHTS[prefer]
    weather_by_point = await _fetch_route_weather(coordinates)
    route_heat_penalty = max(
        (float(weather["heat_penalty"]) for weather in weather_by_point),
        default=0.0,
    )

    snapshot = await safety_dataset_cache.get_snapshot(db)
    rows = snapshot.match_route_segments(
        coordinates,
        road_match_distance_m=ROAD_MATCH_DISTANCE_METERS,
        midpoint_search_expand_degrees=MIDPOINT_SEARCH_EXPAND_DEGREES,
    )

    total_route_length = sum(float(row["route_length_m"]) for row in rows)
    road_segment_ids = sorted(
        {
            int(row["road_segment_id"])
            for row in rows
            if row["road_segment_id"] is not None
        }
    )
    incident_aggregates = await reporting_service.get_segment_incident_aggregates(
        road_segment_ids=road_segment_ids,
        dataset_version=snapshot.road_dataset_version,
        db=db,
    )
    try:
        sidecar_shade = await shade_sidecar.fetch_shade(
            road_segment_ids=road_segment_ids,
            dataset_version=snapshot.road_dataset_version,
        )
    except Exception:
        LOGGER.warning(
            "Failed to load sidecar shade; using OSM shade values.",
            exc_info=True,
        )
        sidecar_shade = {}
    try:
        shade_corrections = await reporting_service.get_segment_shade_corrections(
            road_segment_ids=road_segment_ids,
            dataset_version=snapshot.road_dataset_version,
            db=db,
        )
    except Exception:
        LOGGER.warning(
            "Failed to load shade corrections; using cached shade values.",
            exc_info=True,
        )
        shade_corrections = {}

    segments = []
    matched_length = 0.0
    weighted_score_total = 0.0
    weighted_base_score_total = 0.0
    comfort_length = 0.0
    weighted_comfort_total = 0.0

    # R-104 before/after evidence: dedupe the verified report coordinates that
    # matched the route's segments, so the app can show which points moved the
    # score and drop them on the map.
    incident_points_by_id: Dict[str, Dict[str, Any]] = {}
    for incident_info in incident_aggregates.values():
        for point in incident_info.get("incident_points") or []:
            if not isinstance(point, dict):
                continue
            try:
                lat = float(point["lat"])
                lon = float(point["lon"])
            except (KeyError, TypeError, ValueError):
                continue
            normalized = {
                "id": (
                    str(point["id"]) if point.get("id") is not None else None
                ),
                "lat": lat,
                "lon": lon,
                "category": (
                    str(point["category"])
                    if point.get("category") is not None
                    else None
                ),
                "severity": (
                    int(point["severity"])
                    if point.get("severity") is not None
                    else None
                ),
            }
            key = normalized["id"] or f"{lat:.6f},{lon:.6f}"
            incident_points_by_id[key] = normalized
    incident_points = list(incident_points_by_id.values())

    for row in rows:
        segment = row
        segment_length = float(segment["route_length_m"])
        base_safety_score = segment["segment_safety_score"]
        matched = base_safety_score is not None
        road_segment_id = (
            int(segment["road_segment_id"])
            if segment["road_segment_id"] is not None
            else None
        )
        incident_info = (
            incident_aggregates.get(road_segment_id, {})
            if road_segment_id is not None
            else {}
        )
        incident_weight = float(incident_info.get("incident_weight", 0.0))
        incident_penalty = (
            _calculate_incident_penalty(incident_weight) if matched else 0.0
        )
        adjusted_safety_score = (
            max(0.0, float(base_safety_score) - incident_penalty)
            if matched
            else None
        )

        base_shade_score = segment.get("segment_shade_score")
        if road_segment_id is not None and road_segment_id in sidecar_shade:
            base_shade_score = sidecar_shade[road_segment_id]
        shade_correction = (
            float(shade_corrections.get(road_segment_id, 0.0))
            if road_segment_id is not None
            else 0.0
        )
        adjusted_shade_score = _apply_shade_correction(
            base_shade_score,
            shade_correction,
        )
        heat_penalty = route_heat_penalty
        comfort = _comfort_score(
            adjusted_safety_score,
            adjusted_shade_score,
            heat_penalty,
            weights=comfort_weights,
        )

        if matched:
            matched_length += segment_length
            weighted_score_total += adjusted_safety_score * segment_length
            weighted_base_score_total += float(base_safety_score) * segment_length
        if comfort is not None:
            comfort_length += segment_length
            weighted_comfort_total += comfort * segment_length

        zone = None
        if segment["zone_id"] is not None:
            zone = {
                "zone_id": segment["zone_id"],
                "risk_level": segment["zone_risk_level"],
                "risk_score": (
                    round(float(segment["zone_risk_score"]), 3)
                    if segment["zone_risk_score"] is not None
                    else None
                ),
            }

        segments.append(
            {
                "segment_index": int(segment["segment_index"]),
                "start": {
                    "lat": float(segment["start_lat"]),
                    "lon": float(segment["start_lon"]),
                },
                "end": {
                    "lat": float(segment["end_lat"]),
                    "lon": float(segment["end_lon"]),
                },
                "length_m": round(segment_length, 2),
                "matched": matched,
                "base_safety_score": (
                    round(float(base_safety_score), 1) if matched else None
                ),
                "safety_score": (
                    round(adjusted_safety_score, 1) if matched else None
                ),
                "shade_score": (
                    round(float(adjusted_shade_score), 1)
                    if adjusted_shade_score is not None
                    else None
                ),
                "heat_penalty": round(heat_penalty, 1),
                "comfort_score": (
                    round(comfort, 1) if comfort is not None else None
                ),
                "road_segment_id": road_segment_id,
                "road_type": segment["road_type"],
                "lighting": segment["lighting"],
                "match_distance_m": (
                    round(float(segment["match_distance_m"]), 3)
                    if segment["match_distance_m"] is not None
                    else None
                ),
                "incident_count": int(incident_info.get("incident_count", 0)),
                "incident_weight": round(incident_weight, 3),
                "incident_penalty": round(incident_penalty, 1),
                "incident_categories": incident_info.get("incident_categories", []),
                "max_incident_severity": incident_info.get("max_incident_severity"),
                "latest_incident_at": incident_info.get("latest_incident_at"),
                "zone": zone,
            }
        )

    if matched_length == 0:
        warning = (
            "No safety data found for this route. "
            "The ingest job may not have been run yet."
        )
        safety_score = None
    elif matched_length < total_route_length:
        warning = (
            "Safety data was matched for only part of this route. "
            "Unmatched route segments are returned with null safety scores."
        )
        safety_score = round(weighted_score_total / matched_length, 1)
    else:
        warning = None
        safety_score = round(weighted_score_total / matched_length, 1)

    comfort_score = (
        round(weighted_comfort_total / comfort_length, 1)
        if comfort_length > 0
        else None
    )
    matched_segment_count = sum(1 for segment in segments if segment["matched"])
    applied_incident_count = sum(
        int(incident.get("incident_count", 0))
        for incident in incident_aggregates.values()
    )

    base_safety_score: float | None
    incident_score_delta: float | None
    if matched_length > 0:
        base_safety_score = round(
            weighted_base_score_total / matched_length, 1
        )
        raw_base = weighted_base_score_total / matched_length
        raw_adjusted = weighted_score_total / matched_length
        incident_score_delta = round(raw_base - raw_adjusted, 1)
    else:
        base_safety_score = None
        incident_score_delta = None

    return {
        "safety_score": safety_score,
        "comfort_score": comfort_score,
        "comfort_level": _comfort_level(comfort_score),
        "weather": weather_by_point[0] if weather_by_point else None,
        "segment_count": len(segments),
        "matched_segment_count": matched_segment_count,
        "unmatched_segment_count": len(segments) - matched_segment_count,
        "applied_incident_count": applied_incident_count,
        "incident_affected_segment_count": sum(
            1
            for incident in incident_aggregates.values()
            if int(incident.get("incident_count", 0)) > 0
        ),
        # R-104: route score before verified-report penalties, the delta from
        # those reports, and the mapped report coordinates behind both.
        "base_safety_score": base_safety_score,
        "incident_score_delta": incident_score_delta,
        "incident_points": incident_points,
        "dataset_version": snapshot.road_dataset_version,
        "segments": segments,
        "warning": warning,
    }
