import unittest
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

from fastapi.testclient import TestClient

from app.main import app
from app.routers.admin import verify_report
from app.services.risk_engine import score_route


def _build_route_row(
    *,
    segment_index,
    start_lat,
    start_lon,
    end_lat,
    end_lon,
    route_length_m,
    road_segment_id,
    segment_safety_score,
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


class _FakeFetchOneResult:
    def __init__(self, row):
        self._row = row

    def fetchone(self):
        return self._row


class _TrackingModerationSession:
    def __init__(self, *, report_status="pending"):
        self.calls = []
        self.commit_count = 0
        self._report_row = SimpleNamespace(id=5, status=report_status)

    async def execute(self, query, params=None):
        sql = str(query)
        self.calls.append((sql, params or {}))
        if "SELECT id, status" in sql and "FROM incident_reports" in sql:
            return _FakeFetchOneResult(self._report_row)
        return _FakeFetchOneResult(None)

    async def commit(self):
        self.commit_count += 1


class RoutingIntegrityEndpointTests(unittest.TestCase):
    def setUp(self):
        from app.routers.routing import _zones_cache
        _zones_cache.clear()

    def test_route_risk_returns_expected_structure_with_matched_and_unmatched_segments(self):
        mocked_payload = {
            "safety_score": 74.2,
            "segment_count": 2,
            "matched_segment_count": 1,
            "unmatched_segment_count": 1,
            "applied_incident_count": 1,
            "incident_affected_segment_count": 1,
            "dataset_version": "roads-v1",
            "segments": [
                {
                    "segment_index": 0,
                    "start": {"lat": 18.52, "lon": 73.85},
                    "end": {"lat": 18.525, "lon": 73.855},
                    "length_m": 100.0,
                    "matched": True,
                    "base_safety_score": 82.0,
                    "safety_score": 74.2,
                    "road_segment_id": 101,
                    "road_type": "residential",
                    "lighting": True,
                    "match_distance_m": 1.4,
                    "incident_count": 1,
                    "incident_weight": 0.65,
                    "incident_penalty": 7.8,
                    "incident_categories": ["Poor lighting"],
                    "latest_incident_at": "2026-04-05T18:30:00+00:00",
                    "zone": None,
                },
                {
                    "segment_index": 1,
                    "start": {"lat": 18.525, "lon": 73.855},
                    "end": {"lat": 18.53, "lon": 73.86},
                    "length_m": 95.0,
                    "matched": False,
                    "base_safety_score": None,
                    "safety_score": None,
                    "road_segment_id": None,
                    "road_type": None,
                    "lighting": None,
                    "match_distance_m": None,
                    "incident_count": 0,
                    "incident_weight": 0.0,
                    "incident_penalty": 0.0,
                    "incident_categories": [],
                    "latest_incident_at": None,
                    "zone": None,
                },
            ],
            "warning": (
                "Safety data was matched for only part of this route. "
                "Unmatched route segments are returned with null safety scores."
            ),
        }

        with patch(
            "app.routers.routing.score_route",
            new=AsyncMock(return_value=mocked_payload),
        ):
            with TestClient(app) as client:
                response = client.post(
                    "/route/risk",
                    json={
                        "coordinates": [
                            {"lat": 18.52, "lon": 73.85},
                            {"lat": 18.53, "lon": 73.86},
                        ]
                    },
                )

        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertEqual(body["segment_count"], 2)
        self.assertEqual(body["matched_segment_count"], 1)
        self.assertEqual(body["unmatched_segment_count"], 1)
        self.assertTrue(body["segments"][0]["matched"])
        self.assertFalse(body["segments"][1]["matched"])

    def test_route_safe_returns_coordinates_safety_score_and_metadata(self):
        mocked_route = {
            "coordinates": [(18.52, 73.85), (18.53, 73.86)],
            "distance_km": 2.5,
            "duration_minutes": 29.7,
            "safety_score": None,
        }
        mocked_score = {
            "safety_score": 64.5,
            "segment_count": 1,
            "matched_segment_count": 1,
            "unmatched_segment_count": 0,
            "applied_incident_count": 1,
            "incident_affected_segment_count": 1,
            "dataset_version": "roads-v1",
            "segments": [
                {
                    "segment_index": 0,
                    "start": {"lat": 18.52, "lon": 73.85},
                    "end": {"lat": 18.53, "lon": 73.86},
                    "length_m": 195.0,
                    "matched": True,
                    "base_safety_score": 72.0,
                    "safety_score": 64.5,
                    "road_segment_id": 101,
                    "road_type": "residential",
                    "lighting": True,
                    "match_distance_m": 0.8,
                    "incident_count": 1,
                    "incident_weight": 0.625,
                    "incident_penalty": 7.5,
                    "incident_categories": ["Harassment"],
                    "latest_incident_at": "2026-04-05T18:30:00+00:00",
                    "zone": {
                        "zone_id": "zone-2",
                        "risk_level": "risky",
                        "risk_score": 0.7,
                    },
                }
            ],
            "warning": None,
        }

        with patch(
            "app.routers.routing.get_route_candidates",
            new=AsyncMock(return_value=[mocked_route]),
        ), patch(
            "app.routers.routing.score_route",
            new=AsyncMock(return_value=mocked_score),
        ):
            with TestClient(app) as client:
                response = client.get(
                    "/route-safe",
                    params={
                        "start_lat": 18.52,
                        "start_lon": 73.85,
                        "end_lat": 18.53,
                        "end_lon": 73.86,
                    },
                )

        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertEqual(body["coordinates"], [[18.52, 73.85], [18.53, 73.86]])
        self.assertEqual(body["safety_score"], 64.5)
        self.assertEqual(body["distance_km"], 2.5)
        self.assertEqual(body["duration_minutes"], 29.7)
        self.assertEqual(body["dataset_version"], "roads-v1")

    def test_safety_zones_returns_bounded_geojson(self):
        mocked_payload = {
            "type": "FeatureCollection",
            "features": [
                {
                    "type": "Feature",
                    "properties": {
                        "zone_id": "zone-1",
                        "risk_level": "cautious",
                        "risk_score": 0.35,
                    },
                    "geometry": {
                        "type": "Polygon",
                        "coordinates": [
                            [
                                [73.8500, 18.5200],
                                [73.8550, 18.5200],
                                [73.8550, 18.5250],
                                [73.8500, 18.5250],
                                [73.8500, 18.5200],
                            ]
                        ],
                    },
                }
            ],
            "dataset_version": "zones-v1",
        }

        with patch(
            "app.routers.routing.load_safety_zones",
            new=AsyncMock(return_value=mocked_payload),
        ) as mocked_loader:
            with TestClient(app) as client:
                response = client.get(
                    "/safety-zones",
                    params={
                        "min_lat": 18.51,
                        "max_lat": 18.53,
                        "min_lon": 73.84,
                        "max_lon": 73.86,
                    },
                )

        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertEqual(body["type"], "FeatureCollection")
        feature = body["features"][0]
        for lon, lat in feature["geometry"]["coordinates"][0]:
            self.assertGreaterEqual(lat, 18.51)
            self.assertLessEqual(lat, 18.53)
            self.assertGreaterEqual(lon, 73.84)
            self.assertLessEqual(lon, 73.86)

        self.assertEqual(mocked_loader.await_count, 1)
        self.assertEqual(mocked_loader.await_args.kwargs["min_lat"], 18.51)
        self.assertEqual(mocked_loader.await_args.kwargs["max_lat"], 18.53)
        self.assertEqual(mocked_loader.await_args.kwargs["min_lon"], 73.84)
        self.assertEqual(mocked_loader.await_args.kwargs["max_lon"], 73.86)


class RoutingIntegrityScoringTests(unittest.IsolatedAsyncioTestCase):
    async def test_verified_incident_decreases_score_and_rejected_incident_has_no_effect(self):
        snapshot = _FakeSnapshot(
            [
                _build_route_row(
                    segment_index=0,
                    start_lat=18.52,
                    start_lon=73.85,
                    end_lat=18.53,
                    end_lon=73.86,
                    route_length_m=180.0,
                    road_segment_id=101,
                    segment_safety_score=80.0,
                )
            ]
        )

        with patch(
            "app.services.risk_engine.safety_dataset_cache.get_snapshot",
            new=AsyncMock(return_value=snapshot),
        ), patch(
            "app.services.risk_engine.reporting_service.get_segment_incident_aggregates",
            new=AsyncMock(
                side_effect=[
                    {
                        101: {
                            "incident_count": 1,
                            "incident_weight": 0.75,
                            "incident_categories": ["Harassment"],
                            "latest_incident_at": "2026-04-05T18:30:00+00:00",
                        }
                    },
                    {},
                ]
            ),
        ):
            verified_score = await score_route(
                [(18.52, 73.85), (18.53, 73.86)],
                object(),
            )
            rejected_score = await score_route(
                [(18.52, 73.85), (18.53, 73.86)],
                object(),
            )

        self.assertLess(verified_score["safety_score"], rejected_score["safety_score"])
        self.assertEqual(verified_score["segments"][0]["base_safety_score"], 80.0)
        self.assertEqual(rejected_score["segments"][0]["safety_score"], 80.0)
        self.assertEqual(verified_score["segments"][0]["incident_count"], 1)
        self.assertEqual(rejected_score["segments"][0]["incident_count"], 0)

    async def test_multiple_scoring_calls_do_not_stack_penalties(self):
        snapshot = _FakeSnapshot(
            [
                _build_route_row(
                    segment_index=0,
                    start_lat=18.52,
                    start_lon=73.85,
                    end_lat=18.53,
                    end_lon=73.86,
                    route_length_m=180.0,
                    road_segment_id=101,
                    segment_safety_score=80.0,
                )
            ]
        )
        incident_aggregates = {
            101: {
                "incident_count": 1,
                "incident_weight": 0.75,
                "incident_categories": ["Harassment"],
                "latest_incident_at": "2026-04-05T18:30:00+00:00",
            }
        }

        with patch(
            "app.services.risk_engine.safety_dataset_cache.get_snapshot",
            new=AsyncMock(return_value=snapshot),
        ), patch(
            "app.services.risk_engine.reporting_service.get_segment_incident_aggregates",
            new=AsyncMock(return_value=incident_aggregates),
        ):
            first_score = await score_route(
                [(18.52, 73.85), (18.53, 73.86)],
                object(),
            )
            second_score = await score_route(
                [(18.52, 73.85), (18.53, 73.86)],
                object(),
            )

        self.assertEqual(first_score["safety_score"], second_score["safety_score"])
        self.assertEqual(
            first_score["segments"][0]["base_safety_score"],
            second_score["segments"][0]["base_safety_score"],
        )
        self.assertEqual(first_score["segments"][0]["base_safety_score"], 80.0)

    async def test_score_route_is_safe_when_matching_rows_are_missing(self):
        snapshot = _FakeSnapshot([])

        with patch(
            "app.services.risk_engine.safety_dataset_cache.get_snapshot",
            new=AsyncMock(return_value=snapshot),
        ), patch(
            "app.services.risk_engine.reporting_service.get_segment_incident_aggregates",
            new=AsyncMock(return_value={}),
        ):
            scored = await score_route(
                [(18.52, 73.85), (18.53, 73.86)],
                object(),
            )

        self.assertIsNone(scored["safety_score"])
        self.assertEqual(scored["segment_count"], 0)
        self.assertEqual(scored["matched_segment_count"], 0)
        self.assertEqual(scored["unmatched_segment_count"], 0)
        self.assertIn("No safety data found", scored["warning"])

    async def test_admin_verification_does_not_mutate_road_segment_scores(self):
        session = _TrackingModerationSession()

        response = await verify_report(report_id=5, db=session, _=None)

        executed_sql = [sql for sql, _ in session.calls]
        self.assertTrue(any("UPDATE incident_reports" in sql for sql in executed_sql))
        self.assertFalse(any("UPDATE road_segments" in sql for sql in executed_sql))
        self.assertEqual(session.commit_count, 1)
        self.assertEqual(response["message"], "Report 5 verified")
        self.assertEqual(response["penalty_applied"], 0.0)
        self.assertEqual(response["road_segments_updated"], 0)


if __name__ == "__main__":
    unittest.main()
