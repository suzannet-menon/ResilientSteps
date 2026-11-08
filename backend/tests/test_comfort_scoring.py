import sys
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, patch

from fastapi.testclient import TestClient

BACKEND_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BACKEND_ROOT))

from app.main import app
from app.modules.walksafe.services import risk_engine
from app.modules.walksafe.services.reporting_service import ReportingService
from app.modules.walksafe.services.risk_engine import (
    _apply_shade_correction,
    _comfort_score,
    score_route,
)


def _build_route_row(
    *,
    segment_index=0,
    start_lat=18.52,
    start_lon=73.85,
    end_lat=18.53,
    end_lon=73.86,
    route_length_m=180.0,
    road_segment_id=101,
    segment_safety_score=80.0,
    segment_shade_score=60.0,
    road_type="residential",
    lighting=True,
    match_distance_m=1.2,
    zone_id=None,
    zone_risk_level=None,
    zone_risk_score=None,
):
    return {
        "segment_index": segment_index,
        "start_lat": start_lat,
        "start_lon": start_lon,
        "end_lat": end_lat,
        "end_lon": end_lon,
        "route_length_m": route_length_m,
        "road_segment_id": road_segment_id,
        "segment_safety_score": segment_safety_score,
        "segment_shade_score": segment_shade_score,
        "road_type": road_type,
        "lighting": lighting,
        "match_distance_m": match_distance_m,
        "zone_id": zone_id,
        "zone_risk_level": zone_risk_level,
        "zone_risk_score": zone_risk_score,
    }


class _FakeSnapshot:
    def __init__(self, rows, *, road_dataset_version="roads-v1"):
        self._rows = rows
        self.road_dataset_version = road_dataset_version

    def match_route_segments(self, *_args, **_kwargs):
        return list(self._rows)


class _FakeRow:
    def __init__(self, mapping):
        self._mapping = mapping


class _FakeResult:
    def __init__(self, rows=None):
        self._rows = rows or []

    def fetchall(self):
        return self._rows


class _RecordingAsyncSession:
    def __init__(self, rows):
        self.rows = rows
        self.calls = []

    async def execute(self, query, params=None):
        self.calls.append((str(query), params or {}))
        return _FakeResult(self.rows)


def _scoring_patches(snapshot, *, shade_corrections=None, weather=None):
    return (
        patch.object(
            risk_engine.safety_dataset_cache,
            "get_snapshot",
            new=AsyncMock(return_value=snapshot),
        ),
        patch.object(
            risk_engine.reporting_service,
            "get_segment_incident_aggregates",
            new=AsyncMock(return_value={}),
        ),
        patch.object(
            risk_engine.reporting_service,
            "get_segment_shade_corrections",
            new=AsyncMock(return_value=shade_corrections or {}),
        ),
        patch.object(
            risk_engine.weather_service,
            "get_weather",
            new=AsyncMock(return_value=weather),
        ),
    )


class ComfortScoreUnitTests(unittest.TestCase):
    def test_comfort_formula_uses_safety_shade_and_heat(self):
        self.assertAlmostEqual(_comfort_score(80.0, 60.0, 0.0), 68.0, places=6)
        self.assertAlmostEqual(_comfort_score(80.0, 60.0, 20.0), 66.0, places=6)

    def test_comfort_is_none_without_safety(self):
        self.assertIsNone(_comfort_score(None, 60.0, 0.0))

    def test_unknown_shade_treats_safety_as_neutral(self):
        self.assertAlmostEqual(_comfort_score(80.0, None, 0.0), 72.0, places=6)

    def test_comfort_is_clamped_to_0_100(self):
        self.assertEqual(_comfort_score(100.0, 100.0, 0.0), 90.0)
        self.assertEqual(_comfort_score(0.0, 0.0, 40.0), 0.0)


class ComfortScoringTests(unittest.IsolatedAsyncioTestCase):
    async def test_route_comfort_is_additive_and_keeps_safety_unchanged(self):
        snapshot = _FakeSnapshot([_build_route_row(segment_shade_score=60.0)])
        patches = _scoring_patches(snapshot)

        with patches[0], patches[1], patches[2], patches[3]:
            scored = await score_route([(18.52, 73.85), (18.53, 73.86)], object())

        self.assertEqual(scored["safety_score"], 80.0)
        self.assertEqual(scored["segments"][0]["safety_score"], 80.0)
        self.assertEqual(scored["segments"][0]["shade_score"], 60.0)
        self.assertEqual(scored["segments"][0]["heat_penalty"], 0.0)
        self.assertAlmostEqual(scored["comfort_score"], 68.0, places=1)
        self.assertEqual(scored["comfort_level"], "moderate")
        self.assertIsNone(scored["weather"])

    async def test_weather_failure_still_returns_the_route(self):
        snapshot = _FakeSnapshot([_build_route_row(segment_shade_score=60.0)])
        patches = _scoring_patches(snapshot, weather=None)

        with patches[0], patches[1], patches[2], patches[3]:
            scored = await score_route([(18.52, 73.85), (18.53, 73.86)], object())

        self.assertIsNotNone(scored["safety_score"])
        self.assertEqual(scored["segments"][0]["heat_penalty"], 0.0)
        self.assertIsNone(scored["weather"])

    async def test_weather_heat_penalty_is_applied_to_every_segment(self):
        snapshot = _FakeSnapshot([_build_route_row(segment_shade_score=60.0)])
        weather = {"heat_penalty": 20.0, "temperature_c": 40.0}
        patches = _scoring_patches(snapshot, weather=weather)

        with patches[0], patches[1], patches[2], patches[3]:
            scored = await score_route([(18.52, 73.85), (18.53, 73.86)], object())

        self.assertEqual(scored["segments"][0]["heat_penalty"], 20.0)
        self.assertEqual(scored["weather"], weather)
        self.assertAlmostEqual(scored["comfort_score"], 66.0, places=1)

    async def test_prefer_shade_reweights_the_reported_comfort(self):
        snapshot = _FakeSnapshot([_build_route_row(segment_shade_score=90.0)])
        patches = _scoring_patches(snapshot)

        with patches[0], patches[1], patches[2], patches[3]:
            balanced = await score_route(
                [(18.52, 73.85), (18.53, 73.86)],
                object(),
            )
            shade = await score_route(
                [(18.52, 73.85), (18.53, 73.86)],
                object(),
                prefer="shade",
            )

        self.assertEqual(balanced["safety_score"], shade["safety_score"])
        self.assertGreater(shade["comfort_score"], balanced["comfort_score"])

    async def test_verified_shade_correction_lowers_segment_shade_and_comfort(self):
        snapshot = _FakeSnapshot([_build_route_row(segment_shade_score=55.0)])
        patches = _scoring_patches(snapshot, shade_corrections={101: -20.0})

        with patches[0], patches[1], patches[2], patches[3]:
            scored = await score_route([(18.52, 73.85), (18.53, 73.86)], object())

        self.assertEqual(scored["segments"][0]["shade_score"], 35.0)
        self.assertLess(scored["comfort_score"], 68.0)


class ShadeCorrectionTests(unittest.IsolatedAsyncioTestCase):
    async def test_corrections_are_capped_per_segment(self):
        session = _RecordingAsyncSession(
            [
                _FakeRow({"road_segment_id": 101, "shade_correction": -40.0}),
                _FakeRow({"road_segment_id": 202, "shade_correction": 30.0}),
            ]
        )

        corrections = await ReportingService().get_segment_shade_corrections(
            road_segment_ids=[101, 202],
            dataset_version="roads-v1",
            db=session,
        )

        self.assertEqual(corrections[101], -25.0)
        self.assertEqual(corrections[202], 10.0)
        _, params = session.calls[0]
        self.assertEqual(params["shade_observation_penalty"], -10.0)
        self.assertEqual(params["cool_spot_bonus"], 5.0)

    async def test_empty_segment_ids_skip_the_query(self):
        session = _RecordingAsyncSession([])

        corrections = await ReportingService().get_segment_shade_corrections(
            road_segment_ids=[],
            dataset_version="roads-v1",
            db=session,
        )

        self.assertEqual(corrections, {})
        self.assertEqual(session.calls, [])

    def test_final_shade_is_clamped_to_0_100(self):
        self.assertEqual(_apply_shade_correction(5.0, -10.0), 0.0)
        self.assertEqual(_apply_shade_correction(98.0, 10.0), 100.0)
        self.assertIsNone(_apply_shade_correction(None, -10.0))


class RouteSafePreferTests(unittest.TestCase):
    def test_unknown_prefer_returns_400(self):
        with TestClient(app) as client:
            response = client.get(
                "/route-safe",
                params={
                    "start_lat": 18.52,
                    "start_lon": 73.85,
                    "end_lat": 18.53,
                    "end_lon": 73.86,
                    "prefer": "banana",
                },
            )

        self.assertEqual(response.status_code, 400)
        self.assertIn("Unsupported prefer value", response.json()["detail"])

    def test_known_prefer_is_forwarded_to_the_scorer(self):
        mocked_route = {
            "coordinates": [(18.52, 73.85), (18.53, 73.86)],
            "distance_km": 2.5,
            "duration_minutes": 29.7,
        }
        mocked_score = {
            "safety_score": 64.5,
            "comfort_score": 70.0,
            "comfort_level": "comfortable",
            "weather": None,
            "segment_count": 0,
            "matched_segment_count": 0,
            "unmatched_segment_count": 0,
            "applied_incident_count": 0,
            "incident_affected_segment_count": 0,
            "dataset_version": "roads-v1",
            "segments": [],
            "warning": None,
        }

        with patch(
            "app.routers.routing.get_route_candidates",
            new=AsyncMock(return_value=[mocked_route]),
        ), patch(
            "app.routers.routing.score_route",
            new=AsyncMock(return_value=mocked_score),
        ) as mocked_scorer:
            with TestClient(app) as client:
                response = client.get(
                    "/route-safe",
                    params={
                        "start_lat": 18.52,
                        "start_lon": 73.85,
                        "end_lat": 18.53,
                        "end_lon": 73.86,
                        "prefer": "shade",
                    },
                )

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["comfort_level"], "comfortable")
        self.assertEqual(mocked_scorer.await_args.kwargs["prefer"], "shade")


if __name__ == "__main__":
    unittest.main()
