import unittest
from unittest.mock import AsyncMock, patch

from fastapi.testclient import TestClient

from app.main import app
from app.services.auth_middleware import require_auth


class ApiEndpointTests(unittest.TestCase):
    def setUp(self):
        from app.routers.routing import _zones_cache
        _zones_cache.clear()

    def test_route_risk_returns_current_response_contract(self):
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
        self.assertEqual(body["matched_segment_count"], 1)
        self.assertEqual(body["unmatched_segment_count"], 1)
        self.assertTrue(body["segments"][0]["matched"])
        self.assertIsNone(body["segments"][1]["safety_score"])

    def test_route_safe_returns_coordinates_safety_score_and_metadata(self):
        mocked_route = {
            "coordinates": [(18.52, 73.85), (18.53, 73.86)],
            "distance_km": 2.5,
            "duration_minutes": 29.7,
            "safety_score": None,
        }
        mocked_score = {
            "safety_score": 64.5,
            "segment_count": 2,
            "matched_segment_count": 2,
            "unmatched_segment_count": 0,
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

    def test_safety_zones_returns_geojson_contract(self):
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
        ):
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
        self.assertEqual(body["features"][0]["properties"]["zone_id"], "zone-1")

    def test_report_alias_returns_response_contract(self):
        app.dependency_overrides[require_auth] = lambda: "user-1"
        try:
            # TestClient executes BackgroundTasks after the response: keep the
            # Nugen classifier OFF so no live API call can happen in CI.
            with patch.dict(
                "os.environ",
                {"NUGEN_API_KEY": "", "NUGEN_MODEL": ""},
                clear=False,
            ):
                with patch(
                    "app.routers.reports.reporting_service.create_report",
                    new=AsyncMock(return_value={"id": "report-1", "status": "received"}),
                ):
                    with TestClient(app) as client:
                        response = client.post(
                            "/reports",
                            json={
                                "user_hash": "user-1",
                                "incident_type": "Poor lighting",
                                "severity": 3,
                                "lat": 18.52,
                                "lon": 73.85,
                                "description": "Dark segment",
                                "metadata": {},
                            },
                        )
        finally:
            app.dependency_overrides.pop(require_auth, None)

        self.assertEqual(response.status_code, 200)
        self.assertEqual(
            response.json(),
            {
                "id": "report-1",
                "status": "received",
                "message": "Thank you for your report. It will be verified.",
            },
        )

    def test_report_emergency_alias_returns_response_contract(self):
        app.dependency_overrides[require_auth] = lambda: "user-1"
        try:
            with patch(
                "app.routers.reports.reporting_service.create_emergency_alert",
                new=AsyncMock(
                    return_value={
                        "id": "emergency-1",
                        "status": "triggered",
                        "created_at": "2026-03-12T18:30:00Z",
                        "message": "Emergency alert has been triggered.",
                        "contacts_notified": 0,
                        "trusted_contacts": [],
                    }
                ),
            ):
                with TestClient(app) as client:
                    response = client.post(
                        "/reports/emergency",
                        json={
                            "user_hash": "user-1",
                            "lat": 18.52,
                            "lon": 73.85,
                            "message": "Help needed",
                            "contacts_notified": 0,
                            "metadata": {},
                        },
                    )
        finally:
            app.dependency_overrides.pop(require_auth, None)

        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertEqual(body["id"], "emergency-1")
        self.assertEqual(body["status"], "triggered")
        self.assertEqual(body["message"], "Emergency alert has been triggered.")


if __name__ == "__main__":
    unittest.main()
