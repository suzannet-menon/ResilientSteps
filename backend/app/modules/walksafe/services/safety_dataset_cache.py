import asyncio
import logging
import math
import numbers
import os
import time
from dataclasses import dataclass
from typing import Any, Iterable, Optional

from shapely import wkb
from shapely.geometry import LineString, Point, box, mapping
from shapely.strtree import STRtree
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

LOGGER = logging.getLogger(__name__)

EARTH_RADIUS_METERS = 6_371_008.8
DEFAULT_REFRESH_INTERVAL_SECONDS = float(
    os.environ.get("SAFETY_DATASET_REFRESH_SECONDS", "60")
)

LATEST_ROAD_VERSION_QUERY = text(
    """
    SELECT dataset_version
    FROM road_segments
    ORDER BY updated_at DESC
    LIMIT 1
    """
)

LATEST_ZONE_VERSION_QUERY = text(
    """
    SELECT dataset_version
    FROM safety_zones
    ORDER BY created_at DESC
    LIMIT 1
    """
)

ROAD_SEGMENTS_QUERY = text(
    """
    SELECT
        id,
        safety_score,
        road_type,
        lighting,
        shade_score,
        ST_AsBinary(geometry) AS geometry_wkb
    FROM road_segments
    WHERE dataset_version = :dataset_version
    ORDER BY id
    """
)

SAFETY_ZONES_QUERY = text(
    """
    SELECT
        zone_id,
        risk_level,
        risk_score,
        dataset_version,
        ST_AsBinary(geometry) AS geometry_wkb
    FROM safety_zones
    WHERE dataset_version = :dataset_version
    ORDER BY id
    """
)


@dataclass(frozen=True)
class CachedRoadSegment:
    segment_id: int
    safety_score: float
    road_type: str | None
    lighting: bool | None
    geometry: Any
    shade_score: float | None = None


@dataclass(frozen=True)
class CachedSafetyZone:
    zone_id: str
    risk_level: str
    risk_score: float
    dataset_version: str
    geometry: Any
    geojson_feature: dict[str, Any] | None = None

class SafetyDatasetSnapshot:
    def __init__(
        self,
        *,
        road_dataset_version: str | None,
        zone_dataset_version: str | None,
        road_segments: list[CachedRoadSegment],
        safety_zones: list[CachedSafetyZone],
    ) -> None:
        self.road_dataset_version = road_dataset_version
        self.zone_dataset_version = zone_dataset_version
        self._road_segments = road_segments
        self._safety_zones = safety_zones

        self._road_geometries = [segment.geometry for segment in road_segments]
        self._road_tree = STRtree(self._road_geometries) if self._road_geometries else None
        self._road_geometry_id_to_index = {
            id(geometry): index for index, geometry in enumerate(self._road_geometries)
        }

        self._zone_geometries = [zone.geometry for zone in safety_zones]
        self._zone_tree = STRtree(self._zone_geometries) if self._zone_geometries else None
        self._zone_geometry_id_to_index = {
            id(geometry): index for index, geometry in enumerate(self._zone_geometries)
        }

        # Precompute GeoJSON features once to avoid redundant serialization on requests
        self._all_features = [
            zone.geojson_feature if zone.geojson_feature is not None else {
                "type": "Feature",
                "geometry": mapping(zone.geometry),
                "properties": {
                    "zone_id": zone.zone_id,
                    "risk_level": zone.risk_level,
                    "risk_score": zone.risk_score,
                    "dataset_version": zone.dataset_version,
                },
            }
            for zone in safety_zones
        ]

        # Prepare zone geometries in-place to accelerate point-in-polygon checks
        for geometry in self._zone_geometries:
            try:
                import shapely
                shapely.prepare(geometry)
            except Exception:
                pass

    def match_route_segments(
        self,
        coordinates: list[tuple[float, float]],
        *,
        road_match_distance_m: float,
        midpoint_search_expand_degrees: float,
    ) -> list[dict[str, Any]]:
        matched_segments: list[dict[str, Any]] = []

        for segment_index, (start, end) in enumerate(
            zip(coordinates, coordinates[1:]),
            start=1,
        ):
            start_lat, start_lon = start
            end_lat, end_lon = end
            midpoint = Point(
                (start_lon + end_lon) / 2.0,
                (start_lat + end_lat) / 2.0,
            )
            route_length_m = _haversine_distance_m(
                start_lat,
                start_lon,
                end_lat,
                end_lon,
            )

            road_match, match_distance_m = self._match_road_segment(
                midpoint=midpoint,
                road_match_distance_m=road_match_distance_m,
                midpoint_search_expand_degrees=midpoint_search_expand_degrees,
            )
            zone_match = self._match_zone(midpoint)

            matched_segments.append(
                {
                    "segment_index": segment_index,
                    "start_lat": start_lat,
                    "start_lon": start_lon,
                    "end_lat": end_lat,
                    "end_lon": end_lon,
                    "route_length_m": route_length_m,
                    "road_segment_id": (
                        road_match.segment_id if road_match is not None else None
                    ),
                    "segment_safety_score": (
                        road_match.safety_score if road_match is not None else None
                    ),
                    "segment_shade_score": (
                        road_match.shade_score if road_match is not None else None
                    ),
                    "road_type": road_match.road_type if road_match is not None else None,
                    "lighting": road_match.lighting if road_match is not None else None,
                    "match_distance_m": match_distance_m,
                    "zone_id": zone_match.zone_id if zone_match is not None else None,
                    "zone_risk_level": (
                        zone_match.risk_level if zone_match is not None else None
                    ),
                    "zone_risk_score": (
                        zone_match.risk_score if zone_match is not None else None
                    ),
                }
            )

        return matched_segments

    def zone_feature_collection(
        self,
        *,
        min_lat: float | None = None,
        max_lat: float | None = None,
        min_lon: float | None = None,
        max_lon: float | None = None,
    ) -> dict[str, Any]:
        if not self._safety_zones:
            return {
                "type": "FeatureCollection",
                "features": [],
                "data_warning": "No zone data loaded. Run logic/generate_safety_map.py first.",
            }

        if None not in (min_lat, max_lat, min_lon, max_lon):
            query_bounds = box(min_lon, min_lat, max_lon, max_lat)
            candidate_indices = self._resolve_indices(
                self._zone_tree.query(query_bounds) if self._zone_tree else []
            )
            features = [
                self._all_features[index]
                for index in candidate_indices
                if self._safety_zones[index].geometry.intersects(query_bounds)
            ]
        else:
            features = self._all_features

        payload: dict[str, Any] = {
            "type": "FeatureCollection",
            "features": features,
        }
        if not features:
            payload["data_warning"] = (
                "No safety zones matched the requested bounds."
                if None not in (min_lat, max_lat, min_lon, max_lon)
                else "No zone data loaded. Run logic/generate_safety_map.py first."
            )
        return payload

    def _match_road_segment(
        self,
        *,
        midpoint: Point,
        road_match_distance_m: float,
        midpoint_search_expand_degrees: float,
    ) -> tuple[CachedRoadSegment | None, float | None]:
        if not self._road_tree:
            return None, None

        search_bounds = box(
            midpoint.x - midpoint_search_expand_degrees,
            midpoint.y - midpoint_search_expand_degrees,
            midpoint.x + midpoint_search_expand_degrees,
            midpoint.y + midpoint_search_expand_degrees,
        )
        candidate_indices = self._resolve_indices(self._road_tree.query(search_bounds))
        if not candidate_indices:
            return None, None

        best_match: CachedRoadSegment | None = None
        best_distance_m: float | None = None

        for index in candidate_indices:
            candidate = self._road_segments[index]
            distance_m = _point_to_linestring_distance_m(midpoint, candidate.geometry)
            if best_distance_m is None or distance_m < best_distance_m:
                best_match = candidate
                best_distance_m = distance_m

        if best_distance_m is None or best_distance_m > road_match_distance_m:
            return None, None

        return best_match, best_distance_m

    def _match_zone(self, point: Point) -> CachedSafetyZone | None:
        if not self._zone_tree:
            return None

        candidate_indices = self._resolve_indices(self._zone_tree.query(point))
        matching_zones = [
            self._safety_zones[index]
            for index in candidate_indices
            if self._safety_zones[index].geometry.covers(point)
        ]
        if not matching_zones:
            return None

        return max(
            matching_zones,
            key=lambda zone: (float(zone.risk_score), zone.zone_id),
        )

    def _resolve_indices(self, candidates: Any) -> list[int]:
        resolved_indices: list[int] = []
        seen_indices: set[int] = set()

        for candidate in _iter_candidates(candidates):
            if isinstance(candidate, numbers.Integral):
                index = int(candidate)
            else:
                index = self._resolve_geometry_index(
                    candidate,
                    self._road_geometry_id_to_index,
                    self._road_geometries,
                )
                if index is None:
                    index = self._resolve_geometry_index(
                        candidate,
                        self._zone_geometry_id_to_index,
                        self._zone_geometries,
                    )
                if index is None:
                    continue

            if index not in seen_indices:
                seen_indices.add(index)
                resolved_indices.append(index)

        return resolved_indices

    def _resolve_geometry_index(
        self,
        candidate: Any,
        geometry_id_to_index: dict[int, int],
        geometries: list[Any],
    ) -> Optional[int]:
        direct_match = geometry_id_to_index.get(id(candidate))
        if direct_match is not None:
            return direct_match

        for index, geometry in enumerate(geometries):
            if geometry.equals(candidate):
                return index
        return None


class SafetyDatasetCache:
    def __init__(self, *, refresh_interval_seconds: float) -> None:
        self._refresh_interval_seconds = max(0.0, float(refresh_interval_seconds))
        self._lock = asyncio.Lock()
        self._snapshot: SafetyDatasetSnapshot | None = None
        self._last_version_check_monotonic = 0.0

    async def warm_cache(self, db: AsyncSession) -> SafetyDatasetSnapshot:
        return await self.get_snapshot(db, force_refresh=True)

    async def get_snapshot(
        self,
        db: AsyncSession,
        *,
        force_refresh: bool = False,
    ) -> SafetyDatasetSnapshot:
        now = time.monotonic()
        if (
            not force_refresh
            and self._snapshot is not None
            and (now - self._last_version_check_monotonic) < self._refresh_interval_seconds
        ):
            return self._snapshot

        async with self._lock:
            now = time.monotonic()
            if (
                not force_refresh
                and self._snapshot is not None
                and (now - self._last_version_check_monotonic)
                < self._refresh_interval_seconds
            ):
                return self._snapshot

            road_dataset_version = await self._fetch_latest_version(
                db,
                LATEST_ROAD_VERSION_QUERY,
            )
            zone_dataset_version = await self._fetch_latest_version(
                db,
                LATEST_ZONE_VERSION_QUERY,
            )

            self._last_version_check_monotonic = now

            if (
                self._snapshot is not None
                and self._snapshot.road_dataset_version == road_dataset_version
                and self._snapshot.zone_dataset_version == zone_dataset_version
            ):
                return self._snapshot

            road_segments = await self._load_road_segments(db, road_dataset_version)
            safety_zones = await self._load_safety_zones(db, zone_dataset_version)
            self._snapshot = SafetyDatasetSnapshot(
                road_dataset_version=road_dataset_version,
                zone_dataset_version=zone_dataset_version,
                road_segments=road_segments,
                safety_zones=safety_zones,
            )
            return self._snapshot

    def clear(self) -> None:
        self._snapshot = None
        self._last_version_check_monotonic = 0.0

    async def _fetch_latest_version(
        self,
        db: AsyncSession,
        query: Any,
    ) -> str | None:
        try:
            result = await db.execute(query, {})
        except Exception:
            LOGGER.exception("Failed to fetch latest safety dataset version.")
            raise

        row = result.fetchone()
        if row is None:
            return None
        return row[0]

    async def _load_road_segments(
        self,
        db: AsyncSession,
        dataset_version: str | None,
    ) -> list[CachedRoadSegment]:
        if not dataset_version:
            return []

        result = await db.execute(
            ROAD_SEGMENTS_QUERY,
            {"dataset_version": dataset_version},
        )
        segments: list[CachedRoadSegment] = []
        for row in result.fetchall():
            mapping = row._mapping
            segments.append(
                CachedRoadSegment(
                    segment_id=int(mapping["id"]),
                    safety_score=float(mapping["safety_score"]),
                    road_type=(
                        str(mapping["road_type"])
                        if mapping["road_type"] is not None
                        else None
                    ),
                    lighting=(
                        bool(mapping["lighting"])
                        if mapping["lighting"] is not None
                        else None
                    ),
                    shade_score=(
                        float(mapping["shade_score"])
                        if mapping.get("shade_score") is not None
                        else None
                    ),
                    geometry=_load_geometry(mapping["geometry_wkb"]),
                )
            )
        return segments

    async def _load_safety_zones(
        self,
        db: AsyncSession,
        dataset_version: str | None,
    ) -> list[CachedSafetyZone]:
        if not dataset_version:
            return []

        result = await db.execute(
            SAFETY_ZONES_QUERY,
            {"dataset_version": dataset_version},
        )
        zones: list[CachedSafetyZone] = []
        for row in result.fetchall():
            mapping = row._mapping
            zones.append(
                CachedSafetyZone(
                    zone_id=str(mapping["zone_id"]),
                    risk_level=str(mapping["risk_level"]),
                    risk_score=float(mapping["risk_score"]),
                    dataset_version=str(mapping["dataset_version"]),
                    geometry=_load_geometry(mapping["geometry_wkb"]),
                )
            )
        return zones


def _iter_candidates(candidates: Any) -> Iterable[Any]:
    if candidates is None:
        return []
    if hasattr(candidates, "tolist"):
        converted = candidates.tolist()
        if isinstance(converted, list):
            return converted
        return [converted]
    if isinstance(candidates, (list, tuple, set)):
        return candidates
    return [candidates]


def _load_geometry(raw_geometry: Any) -> Any:
    if isinstance(raw_geometry, memoryview):
        return wkb.loads(raw_geometry.tobytes())
    if isinstance(raw_geometry, bytearray):
        return wkb.loads(bytes(raw_geometry))
    return wkb.loads(raw_geometry)


def _haversine_distance_m(
    start_lat: float,
    start_lon: float,
    end_lat: float,
    end_lon: float,
) -> float:
    start_lat_rad = math.radians(start_lat)
    end_lat_rad = math.radians(end_lat)
    delta_lat = math.radians(end_lat - start_lat)
    delta_lon = math.radians(end_lon - start_lon)

    haversine = (
        math.sin(delta_lat / 2.0) ** 2
        + math.cos(start_lat_rad)
        * math.cos(end_lat_rad)
        * math.sin(delta_lon / 2.0) ** 2
    )
    arc = 2.0 * math.atan2(math.sqrt(haversine), math.sqrt(1.0 - haversine))
    return EARTH_RADIUS_METERS * arc


def _point_to_linestring_distance_m(point: Point, line: LineString) -> float:
    coordinates = list(line.coords)
    if not coordinates:
        return math.inf
    if len(coordinates) == 1:
        lon, lat = coordinates[0]
        return _haversine_distance_m(point.y, point.x, lat, lon)

    point_lat = point.y
    point_lon = point.x
    best_distance_m = math.inf
    deg_to_rad = math.pi / 180.0
    meters_per_lat = deg_to_rad * EARTH_RADIUS_METERS
    meters_per_lon = meters_per_lat * math.cos(point_lat * deg_to_rad)

    for start, end in zip(coordinates, coordinates[1:]):
        start_lon, start_lat = start
        end_lon, end_lat = end
        distance_m = _fast_point_to_segment_distance_m(
            point_lat,
            point_lon,
            start_lat,
            start_lon,
            end_lat,
            end_lon,
            meters_per_lat,
            meters_per_lon,
        )
        if distance_m < best_distance_m:
            best_distance_m = distance_m

    return best_distance_m


def _point_to_segment_distance_m(
    point_lat: float,
    point_lon: float,
    start_lat: float,
    start_lon: float,
    end_lat: float,
    end_lon: float,
) -> float:
    start_x, start_y = _to_local_xy(
        lat=start_lat,
        lon=start_lon,
        origin_lat=point_lat,
        origin_lon=point_lon,
    )
    end_x, end_y = _to_local_xy(
        lat=end_lat,
        lon=end_lon,
        origin_lat=point_lat,
        origin_lon=point_lon,
    )

    delta_x = end_x - start_x
    delta_y = end_y - start_y
    segment_length_sq = (delta_x * delta_x) + (delta_y * delta_y)
    if segment_length_sq == 0.0:
        return math.hypot(start_x, start_y)

    projection = -((start_x * delta_x) + (start_y * delta_y)) / segment_length_sq
    projection = max(0.0, min(1.0, projection))
    closest_x = start_x + (projection * delta_x)
    closest_y = start_y + (projection * delta_y)
    return math.hypot(closest_x, closest_y)


def _fast_point_to_segment_distance_m(
    point_lat: float,
    point_lon: float,
    start_lat: float,
    start_lon: float,
    end_lat: float,
    end_lon: float,
    meters_per_lat: float,
    meters_per_lon: float,
) -> float:
    start_x = (start_lon - point_lon) * meters_per_lon
    start_y = (start_lat - point_lat) * meters_per_lat
    end_x = (end_lon - point_lon) * meters_per_lon
    end_y = (end_lat - point_lat) * meters_per_lat

    delta_x = end_x - start_x
    delta_y = end_y - start_y
    segment_length_sq = (delta_x * delta_x) + (delta_y * delta_y)
    if segment_length_sq == 0.0:
        return math.hypot(start_x, start_y)

    projection = -((start_x * delta_x) + (start_y * delta_y)) / segment_length_sq
    projection = max(0.0, min(1.0, projection))
    closest_x = start_x + (projection * delta_x)
    closest_y = start_y + (projection * delta_y)
    return math.hypot(closest_x, closest_y)

def _to_local_xy(
    *,
    lat: float,
    lon: float,
    origin_lat: float,
    origin_lon: float,
) -> tuple[float, float]:
    mean_lat_rad = math.radians((lat + origin_lat) / 2.0)
    x = (
        math.radians(lon - origin_lon)
        * EARTH_RADIUS_METERS
        * math.cos(mean_lat_rad)
    )
    y = math.radians(lat - origin_lat) * EARTH_RADIUS_METERS
    return x, y


safety_dataset_cache = SafetyDatasetCache(
    refresh_interval_seconds=DEFAULT_REFRESH_INTERVAL_SECONDS
)
