"""Shade sidecar merge (R-074 / GEE Phase 1) tests.

Contract under test (S-155/S-098):
  - SHADE_DB_URL unset -> no sidecar calls, OSM shade untouched.
  - Sidecar values override the OSM base shade for matched ids and FILL
    unknown (None) shade for segments the satellite batch scored.
  - Sidecar failure degrades to {} (OSM shade retained) and the sidecar is
    marked unavailable for a cooldown window (no per-request log spam).
"""

import os
import sys
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, patch

from shapely.geometry import LineString

BACKEND_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BACKEND_ROOT))

from app.services.risk_engine import score_route
from app.services.safety_dataset_cache import (
    CachedRoadSegment,
    SafetyDatasetSnapshot,
)


class FakeRow:
    def __init__(self, mapping):
        self._mapping = mapping


class FakeRow:
    def __init__(self, mapping):
        self._mapping = mapping


class _SidecarTestBase(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self._saved_env = os.environ.pop("SHADE_DB_URL", None)

    def tearDown(self):
        from app.modules.walksafe.services import shade_sidecar

        shade_sidecar.reset()
        if self._saved_env is not None:
            os.environ["SHADE_DB_URL"] = self._saved_env
        else:
            os.environ.pop("SHADE_DB_URL", None)


class ShadeSidecarServiceTests(_SidecarTestBase):
    async def test_no_env_returns_empty_without_calling_fetcher(self):
        from app.modules.walksafe.services import shade_sidecar

        def _fail_factory(*args, **kwargs):
            raise AssertionError("fetcher must not be created without SHADE_DB_URL")

        with patch.object(shade_sidecar, "_get_fetch_fn", _fail_factory):
            values = await shade_sidecar.fetch_shade([1, 2, 3], "v-1")
        self.assertEqual(values, {})

    async def test_set_env_fetches_values_through_fetcher(self):
        from app.modules.walksafe.services import shade_sidecar
        from unittest.mock import AsyncMock

        os.environ["SHADE_DB_URL"] = "postgresql://fake:fake@localhost:5433/fake"
        remote = {101: 12.3, 102: 88.8}
        fake_fetcher = AsyncMock(return_value=remote)
        fake_fetcher.return_value = remote
        shade_sidecar.set_fetch_fn(fake_fetcher)

        values = await shade_sidecar.fetch_shade([101, 102, 103], "v-1")
        self.assertEqual(values, {101: 12.3, 102: 88.8})
        fake_fetcher.assert_called_once_with(
            "postgresql://fake:fake@localhost:5433/fake", "v-1", [101, 102, 103]
        )

    async def test_fetcher_failure_degrades_and_cooldowns(self):
        from app.modules.walksafe.services import shade_sidecar

        os.environ["SHADE_DB_URL"] = "postgresql://fake:fake@localhost:5433/fake"
        calls = {"count": 0}

        async def failing_fetcher(dsn, dataset_version, ids):
            calls["count"] += 1
            raise ConnectionError("sidecar down")

        shade_sidecar.set_fetch_fn(failing_fetcher)

        first = await shade_sidecar.fetch_shade([1], "v-1")
        self.assertEqual(first, {})

        second = await shade_sidecar.fetch_shade([1], "v-1")
        self.assertEqual(second, {})
        self.assertEqual(calls["count"], 1)

    async def test_empty_ids_short_circuits(self):
        from app.modules.walksafe.services import shade_sidecar

        os.environ["SHADE_DB_URL"] = "postgresql://fake:fake@localhost:5433/fake"

        async def failing_fetcher(dsn, dataset_version, ids):
            raise ConnectionError("sidecar down")

        shade_sidecar.set_fetch_fn(failing_fetcher)
        values = await shade_sidecar.fetch_shade([], "v-1")
        self.assertEqual(values, {})


class SafeShadeDatasetSnapshot(SafetyDatasetSnapshot):
    """Incident/zone query paths off; only the road geometry matching matters here."""

    def __init__(self, segments):
        super().__init__(
            road_dataset_version="20260403-174632",
            zone_dataset_version="20260403-174632",
            road_segments=segments,
            safety_zones=[],
        )


class ShadeSidecarMergeTests(_SidecarTestBase):
    def _snapshot(self):
        return SafeShadeDatasetSnapshot(
            segments=[
                CachedRoadSegment(
                    segment_id=101,
                    safety_score=70.0,
                    road_type="residential",
                    lighting=True,
                    shade_score=55.0,
                    geometry=LineString([(73.85, 18.52), (73.855, 18.525)]),
                ),
                CachedRoadSegment(
                    segment_id=102,
                    safety_score=80.0,
                    road_type="tertiary",
                    lighting=False,
                    shade_score=None,
                    geometry=LineString([(73.855, 18.525), (73.86, 18.53)]),
                ),
            ]
        )

    async def _score(self):
        with patch(
            "app.services.risk_engine.safety_dataset_cache.get_snapshot",
            new=AsyncMock(return_value=self._snapshot()),
        ), patch(
            "app.services.risk_engine.reporting_service.get_segment_incident_aggregates",
            new=AsyncMock(return_value={}),
        ):
            return await score_route(
                [(18.52, 73.85), (18.525, 73.855), (18.53, 73.86)], object()
            )

    async def test_sidecar_values_override_osm_and_fill_unknown(self):
        from unittest.mock import AsyncMock

        from app.modules.walksafe.services import shade_sidecar

        os.environ["SHADE_DB_URL"] = "postgresql://fake:fake@localhost:5433/fake"

        async def fake_fetcher(dsn, dataset_version, ids):
            self.assertEqual(dsn, "postgresql://fake:fake@localhost:5433/fake")
            self.assertEqual(dataset_version, "20260403-174632")
            return {101: 12.0, 102: 90.0}

        shade_sidecar.set_fetch_fn(fake_fetcher)
        scored = await self._score()

        by_id = {seg["road_segment_id"]: seg for seg in scored["segments"]}
        self.assertEqual(by_id[101]["shade_score"], 12.0)
        self.assertEqual(by_id[102]["shade_score"], 90.0)

    async def test_sidecar_gap_keeps_osm_and_unknown_stays_none(self):
        from unittest.mock import AsyncMock

        from app.modules.walksafe.services import shade_sidecar

        os.environ["SHADE_DB_URL"] = "postgresql://fake:fake@localhost:5433/fake"

        async def partial_fetcher(dsn, dataset_version, ids):
            return {101: 77.0}

        shade_sidecar.set_fetch_fn(partial_fetcher)
        scored = await self._score()

        by_id = {seg["road_segment_id"]: seg for seg in scored["segments"]}
        self.assertEqual(by_id[101]["shade_score"], 77.0)
        self.assertIsNone(by_id[102]["shade_score"])

    async def test_no_env_route_uses_osm_shade(self):
        from unittest.mock import AsyncMock

        scored = await self._score()

        by_id = {seg["road_segment_id"]: seg for seg in scored["segments"]}
        self.assertEqual(by_id[101]["shade_score"], 55.0)
        self.assertIsNone(by_id[102]["shade_score"])


class SidecarSQLContractTests(unittest.IsolatedAsyncioTestCase):
    async def test_fetch_sql_filters_by_version_and_id_list(self):
        from app.modules.walksafe.services.shade_sidecar import FETCH_SHADE_SQL

        self.assertIn("FROM segment_shade", FETCH_SHADE_SQL)
        self.assertIn("dataset_version = $1", FETCH_SHADE_SQL)
        self.assertIn("road_segment_id = ANY($2)", FETCH_SHADE_SQL)


class SidecarTimestampTests(unittest.IsolatedAsyncioTestCase):
    async def test_utc_timestamp_shape_in_upsert_docs(self):
        from pathlib import Path as _Path

        generator = (
            _Path(BACKEND_ROOT).parent / "logic" / "generate_shade_map_v2.py"
        )
        text = generator.read_text(encoding="utf-8")
        self.assertIn("ON CONFLICT (road_segment_id, dataset_version) DO UPDATE", text)
        self.assertIn("MAIN database READ-ONLY", text)


if __name__ == "__main__":
    unittest.main()
