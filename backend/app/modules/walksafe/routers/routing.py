import os
import time
from collections import OrderedDict
from typing import Any, Dict, List, Optional, Tuple

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_db
from app.core.auth_middleware import optional_auth
from app.core.rate_limiter import nearby_rate_limiter, route_rate_limiter
from app.modules.walksafe.services.risk_engine import PREFER_OPTIONS, score_route
from app.modules.walksafe.services.routing_service import (
    get_route_candidates,
    get_safe_route,
)
from app.modules.walksafe.services.safety_zone_service import (
    get_safety_zones as load_safety_zones,
)
from app.modules.walksafe.services.nearby_places_service import (
    ALL_CATEGORY,
    CATEGORY_FILTERS,
    MAX_RADIUS_METERS,
    find_nearby_places,
)

router = APIRouter()

# Silent route-selection gates (no user-facing option list; the app shows
# ONE route — either Valhalla's fastest, or the safest candidate when the
# data says it is meaningfully better within a bounded time penalty).
MIN_COMFORT_DELTA = float(os.environ.get("ROUTE_MIN_COMFORT_DELTA", "2.0"))
MAX_EXTRA_MINUTES_ABS = float(os.environ.get("ROUTE_MAX_EXTRA_MINUTES", "6.0"))
MAX_EXTRA_MINUTES_FACTOR = 0.25

# NOTE: This is an in-process cache. It does not survive server restarts
# and is not shared across multiple backend instances.
# For multi-instance deployment, replace with Redis.
# The dict is safe here because these handlers run on the app's asyncio event
# loop. If threaded workers are introduced later, guard access with a lock.
_zones_cache: OrderedDict[str, dict[str, Any]] = OrderedDict()
_ZONES_CACHE_TTL_SECONDS: float = 600.0
_ZONES_CACHE_MAX_SIZE: int = 128


def _zones_cache_key(
    min_lat: float | None,
    max_lat: float | None,
    min_lon: float | None,
    max_lon: float | None,
) -> str:
    def _format(value: float | None) -> str:
        return "none" if value is None else f"{value:.4f}"

    return ",".join(
        (
            _format(min_lat),
            _format(max_lat),
            _format(min_lon),
            _format(max_lon),
        )
    )


def _get_cached_zones(bbox_key: str) -> Optional[dict]:
    cached_entry = _zones_cache.get(bbox_key)
    if cached_entry is None:
        return None

    if (time.time() - float(cached_entry["cached_at"])) >= _ZONES_CACHE_TTL_SECONDS:
        _zones_cache.pop(bbox_key, None)
        return None

    _zones_cache.move_to_end(bbox_key)
    return cached_entry["data"]


def _set_cached_zones(bbox_key: str, data: dict) -> None:
    if bbox_key in _zones_cache:
        _zones_cache.move_to_end(bbox_key)
    _zones_cache[bbox_key] = {
        "cached_at": time.time(),
        "data": data,
    }
    while len(_zones_cache) > _ZONES_CACHE_MAX_SIZE:
        _zones_cache.popitem(last=False)


class Coordinate(BaseModel):
    lat: float
    lon: float


class RouteCoordinates(BaseModel):
    coordinates: List[Coordinate]


@router.get("/nearby-places")
async def nearby_places(
    lat: float,
    lon: float,
    category: str,
    radius_m: int = 3000,
    _user: str | None = Depends(optional_auth),
    _rate: None = Depends(nearby_rate_limiter),
):
    if not -90 <= lat <= 90 or not -180 <= lon <= 180:
        raise HTTPException(status_code=422, detail="Invalid coordinates.")
    if category != ALL_CATEGORY and category not in CATEGORY_FILTERS:
        raise HTTPException(
            status_code=400,
            detail=f"Unsupported nearby category: {category}.",
        )
    if not 100 <= radius_m <= MAX_RADIUS_METERS:
        raise HTTPException(
            status_code=422,
            detail=f"radius_m must be between 100 and {MAX_RADIUS_METERS}.",
        )
    try:
        places = await find_nearby_places(
            lat=lat,
            lon=lon,
            category=category,
            radius_m=radius_m,
        )
    except RuntimeError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    return {
        "category": category,
        "center": {"lat": lat, "lon": lon},
        "radius_m": radius_m,
        "places": places,
    }


@router.get("/route", response_model=Dict[str, List[Dict[str, float]]])
async def get_route(
    start_lat: float,
    start_lon: float,
    end_lat: float,
    end_lon: float,
    _user: str | None = Depends(optional_auth),
    _rate: None = Depends(route_rate_limiter),
):
    try:
        route = await get_safe_route(start_lat, start_lon, end_lat, end_lon)
    except RuntimeError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc

    return {
        "safest": [
            {"lat": float(lat), "lon": float(lon)}
            for lat, lon in route["coordinates"]
        ]
    }


@router.post("/route/risk")
@router.post("/route/segments/safety")
async def route_risk(
    body: RouteCoordinates,
    db: AsyncSession = Depends(get_db),
    _user: str | None = Depends(optional_auth),
    _rate: None = Depends(route_rate_limiter),
):
    coordinates = [(c.lat, c.lon) for c in body.coordinates]
    return await score_route(coordinates, db)


def _select_route(
    scored_candidates: list[Tuple[Dict[str, Any], Dict[str, Any]]],
) -> Tuple[Dict[str, Any], Dict[str, Any], Dict[str, Any]]:
    """
    Silently rank the scored candidates and pick one.

    Rules (documented stability) :
    - candidates without matched comfort data never win on merit;
    - a candidate may only beat the fastest one if it is richer in comfort
      data (fastest has none), OR beats it by MIN_COMFORT_DELTA comfort
      points OR beats it by more comfort while staying essentially as fast
      (within ~1 minute);
    - in every case the winner must cost at most
      fastest + max(MAX_EXTRA_MINUTES_ABS, 0.25 x fastest) minutes;
    - otherwise the fastest route is returned unchanged.
    """
    if len(scored_candidates) == 1:
        route, score = scored_candidates[0]
        return route, score, {"candidates": 1, "chosen": "only", "comfort_gain": None}

    def _duration_minutes(entry: Tuple[Dict[str, Any], Dict[str, Any]]) -> float:
        value = entry[0].get("duration_minutes")
        return float(value) if value is not None else 0.0

    fastest_index = min(
        range(len(scored_candidates)),
        key=lambda index: _duration_minutes(scored_candidates[index]),
    )
    base_route, base_score = scored_candidates[fastest_index]
    base_duration = _duration_minutes((base_route, base_score))
    allowed_extra = max(MAX_EXTRA_MINUTES_ABS, MAX_EXTRA_MINUTES_FACTOR * base_duration)

    eligible: list[Tuple[Dict[str, Any], float, Dict[str, Any]]] = []
    for route, score in scored_candidates:
        if route is base_route:
            continue
        comfort = score.get("comfort_score")
        if comfort is None:
            continue
        extra_minutes = _duration_minutes((route, score)) - base_duration
        if extra_minutes > allowed_extra:
            continue
        eligible.append((route, float(comfort), score))

    if not eligible:
        return base_route, base_score, {
            "candidates": len(scored_candidates),
            "chosen": "fastest",
            "comfort_gain": None,
        }

    best_route, best_comfort, best_score = max(
        eligible,
        key=lambda item: (
            item[1],
            float(item[2].get("safety_score") or 0.0),
        ),
    )

    base_comfort = base_score.get("comfort_score")
    if base_comfort is not None:
        comfort_gain = best_comfort - float(base_comfort)
        base_duration_value = _duration_minutes((base_route, base_score))
        best_duration_value = _duration_minutes((best_route, best_score))
        essentially_as_fast = best_duration_value - base_duration_value <= 1.0
        if comfort_gain < MIN_COMFORT_DELTA and not essentially_as_fast:
            return base_route, base_score, {
                "candidates": len(scored_candidates),
                "chosen": "fastest",
                "comfort_gain": round(comfort_gain, 2),
            }
    else:
        comfort_gain = None

    return best_route, best_score, {
        "candidates": len(scored_candidates),
        "chosen": "safest",
        "comfort_gain": (
            round(comfort_gain, 2) if base_comfort is not None else None
        ),
    }


@router.get("/route-safe")
async def route_safe(
    start_lat: float,
    start_lon: float,
    end_lat: float,
    end_lon: float,
    prefer: str = "balanced",
    db: AsyncSession = Depends(get_db),
    _user: str | None = Depends(optional_auth),
    _rate: None = Depends(route_rate_limiter),
):
    if prefer not in PREFER_OPTIONS:
        raise HTTPException(
            status_code=400,
            detail=(
                f"Unsupported prefer value '{prefer}'. "
                f"Expected one of: {', '.join(PREFER_OPTIONS)}."
            ),
        )

    try:
        candidates = await get_route_candidates(
            start_lat, start_lon, end_lat, end_lon
        )
    except RuntimeError as exc:
        message = str(exc)
        if "Cannot connect to Valhalla routing engine" in message:
            raise HTTPException(status_code=503, detail=message) from exc
        raise HTTPException(
            status_code=502,
            detail="No route or safety data found for this route area.",
        ) from exc

    scored_candidates: list[Tuple[Dict[str, Any], Dict[str, Any]]] = [
        (route, await score_route(route["coordinates"], db, prefer=prefer))
        for route in candidates
    ]
    chosen_route, score, selection = _select_route(scored_candidates)

    score["coordinates"] = chosen_route["coordinates"]
    score["distance_km"] = chosen_route["distance_km"]
    score["duration_minutes"] = chosen_route["duration_minutes"]
    score["route_selection"] = selection
    return score


@router.get("/safety-zones")
async def safety_zones(
    min_lat: float | None = None,
    max_lat: float | None = None,
    min_lon: float | None = None,
    max_lon: float | None = None,
    db: AsyncSession = Depends(get_db),
):
    bbox_key = _zones_cache_key(min_lat, max_lat, min_lon, max_lon)
    cached = _get_cached_zones(bbox_key)
    if cached is not None:
        return cached

    result = await load_safety_zones(
        db,
        min_lat=min_lat,
        max_lat=max_lat,
        min_lon=min_lon,
        max_lon=max_lon,
    )
    _set_cached_zones(bbox_key, result)
    return result
