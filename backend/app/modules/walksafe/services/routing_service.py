import os

import httpx
import polyline
from dotenv import load_dotenv

load_dotenv()

VALHALLA_BASE_URL = os.environ.get("VALHALLA_BASE_URL", "http://localhost:8002")
VALHALLA_TIMEOUT = httpx.Timeout(connect=5.0, read=25.0, write=5.0, pool=5.0)
# Valhalla supports alternates only for two-point routes (our only case).
ROUTE_ALTERNATES = max(0, int(os.environ.get("VALHALLA_ROUTE_ALTERNATES", "2")))

# Module-level client — reuses TCP connections across requests.
_http_client: httpx.AsyncClient | None = None


def _get_http_client() -> httpx.AsyncClient:
    global _http_client
    if _http_client is None or _http_client.is_closed:
        _http_client = httpx.AsyncClient(timeout=VALHALLA_TIMEOUT)
    return _http_client


def _build_route_payload(
    start_lat: float,
    start_lon: float,
    end_lat: float,
    end_lon: float,
) -> dict:
    """
    Build the Valhalla route request body.

    The costing is kept near-neutral (roads are fine, no strong lit/walkway
    preference): aggressive penalties such as use_lit=1.0 or use_roads=0.2
    made Valhalla take long walkway-heavy detours in Pune, which reported
    ~7.7 km for trips that are ~1 km as the crow flies.

    Each location carries an explicit `radius` so a pin placed inside a
    large campus (no routable edge within it) cannot snap to an edge many
    km away — Valhalla returns an error instead, and the caller surfaces
    "no route found" rather than a wildly inflated trip.

    When ROUTE_ALTERNATES > 0, up to that many extra routes are requested
    so the caller can score every candidate with the safety/shade/heat
    engine and silently pick the safest one (no user-facing option list).
    """
    payload = {
        "locations": [
            {"lat": start_lat, "lon": start_lon, "radius": 400},
            {"lat": end_lat, "lon": end_lon, "radius": 400},
        ],
        "costing": "pedestrian",
        "costing_options": {
            "pedestrian": {
                "use_lit": 0.2,
                "use_roads": 0.0,
                "walkway_factor": 1.0,
                "sidewalk_factor": 1.0,
                "walking_speed": 5.0,
            }
        },
        "directions_options": {"units": "kilometers"},
    }
    if ROUTE_ALTERNATES > 0:
        payload["alternates"] = ROUTE_ALTERNATES
    return payload


def _parse_trip(trip: dict | None) -> dict | None:
    if not trip:
        return None
    legs = trip.get("legs") or []
    if not legs:
        return None
    summary = trip.get("summary")
    if not summary:
        return None
    return {
        "coordinates": polyline.decode(legs[0]["shape"], precision=6),
        "distance_km": summary["length"],
        "duration_minutes": summary["time"] / 60,
        "safety_score": None,
    }


async def get_route_candidates(
    start_lat: float,
    start_lon: float,
    end_lat: float,
    end_lon: float,
) -> list[dict]:
    """
    Fetch one or more pedestrian route candidates from Valhalla.
    Returns a list of decoded-route dicts (same shape as get_safe_route);
    the first entry is always Valhalla's primary (fastest) route.
    """
    client = _get_http_client()
    try:
        response = await client.post(
            f"{VALHALLA_BASE_URL}/route",
            json=_build_route_payload(start_lat, start_lon, end_lat, end_lon),
        )
        response.raise_for_status()
    except httpx.ConnectError as exc:
        raise RuntimeError(
            "Cannot connect to Valhalla routing engine. "
            "Make sure Docker is running and Valhalla started with: "
            "docker compose -f backend/docker-compose.yml up valhalla"
        ) from exc
    except httpx.HTTPStatusError as exc:
        raise RuntimeError(
            f"Valhalla returned an error: {exc.response.text}"
        ) from exc

    data = response.json()
    candidates: list[dict] = [_parse_trip(data.get("trip"))]
    for alternate in data.get("alternates") or []:
        candidate = _parse_trip(alternate.get("trip") if isinstance(alternate, dict) else None)
        if candidate is not None:
            candidates.append(candidate)
    candidates = [candidate for candidate in candidates if candidate is not None]

    if not candidates:
        raise RuntimeError("Valhalla returned no usable route for this trip.")
    return candidates


async def get_safe_route(
    start_lat: float,
    start_lon: float,
    end_lat: float,
    end_lon: float,
) -> dict:
    """
    Fetch the primary pedestrian route from Valhalla (fastest candidate).
    Kept for callers that only want geometry (e.g. the plain /route path).
    """
    candidates = await get_route_candidates(start_lat, start_lon, end_lat, end_lon)
    return candidates[0]
