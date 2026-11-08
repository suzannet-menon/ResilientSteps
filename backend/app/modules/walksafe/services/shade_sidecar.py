"""Shade sidecar bridge (R-074 / GEE Phase 1).

The GEE satellite batch (logic/generate_shade_map_v2.py) writes satellite
NDVI-derived shade scores to a LOCAL Postgres sidecar keyed by
(road_segment_id, dataset_version) — never to the main Supabase database.
At route time this module bulk-fetches the sidecar values for the request's
matched segment ids so risk_engine can override the OSM-canopy base shade.

Degrade-safe by design (S-098):
  - SHADE_DB_URL unset   -> no-op, OSM-only shade (default deployment)
  - sidecar unreachable  -> {}, OSM-only shade (cooldown guards log spam)
  - empty for a segment  -> segment keeps its existing OSM shade
The observation-corrections layer in risk_engine always applies on top.
"""

import logging
import os
import time

import asyncpg

LOGGER = logging.getLogger(__name__)

SHADE_DB_URL_ENV = "SHADE_DB_URL"

# A single route request carries tens to a couple hundred segment ids; one
# connection is plenty and keeps sidecar pressure trivial.
_POOL_MIN_SIZE = 1
_POOL_MAX_SIZE = 1

# When the sidecar is unreachable, fail silently for a while instead of
# adding connect-timeout latency to every route request.
_UNAVAILABLE_COOLDOWN_SECONDS = 30.0

_fetch_fn = None
_pool: asyncpg.Pool | None = None
_unavailable_until: float = 0.0

FETCH_SHADE_SQL = (
    "SELECT road_segment_id, shade_score FROM segment_shade "
    "WHERE dataset_version = $1 AND road_segment_id = ANY($2)"
)


def _get_fetch_fn():
    """Return the injected fetch fn (tests) or the real one."""
    global _fetch_fn
    if _fetch_fn is None:

        async def _real_fetch(
            dsn: str, dataset_version: str, road_segment_ids: list[int]
        ) -> dict[int, float]:
            global _pool
            if _pool is None:
                _pool = await asyncpg.create_pool(
                    dsn=dsn,
                    min_size=_POOL_MIN_SIZE,
                    max_size=_POOL_MAX_SIZE,
                )
            rows = await _pool.fetch(FETCH_SHADE_SQL, dataset_version, road_segment_ids)
            return {int(row["road_segment_id"]): float(row["shade_score"]) for row in rows}

        _fetch_fn = _real_fetch
    return _fetch_fn


def set_fetch_fn(fn) -> None:
    """Test seam: inject a fake fetcher."""
    global _fetch_fn, _pool
    _fetch_fn = fn
    _pool = None


def reset() -> None:
    """Drop the injected fetcher / pooled connection (test teardown)."""
    global _fetch_fn, _pool, _unavailable_until
    _fetch_fn = None
    _pool = None
    _unavailable_until = 0.0


async def fetch_shade(
    road_segment_ids: list[int], dataset_version: str
) -> dict[int, float]:
    """
    Return {road_segment_id: satellite shade (0-100)} for the given segment
    ids. Missing ids mean "keep the existing OSM shade" at the call site.
    """
    global _unavailable_until

    dsn = os.environ.get(SHADE_DB_URL_ENV)
    if not dsn or not road_segment_ids:
        return {}

    now = time.monotonic()
    if now < _unavailable_until:
        return {}

    try:
        values = await _get_fetch_fn()(dsn, dataset_version, road_segment_ids)
    except Exception:  # noqa: BLE001 - merge is best-effort by contract
        LOGGER.warning(
            "Shade sidecar unavailable; falling back to OSM shade.",
            exc_info=True,
        )
        _unavailable_until = now + _UNAVAILABLE_COOLDOWN_SECONDS
        return {}
    return values
