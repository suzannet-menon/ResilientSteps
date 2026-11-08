import unittest
from pathlib import Path
import sys
from unittest.mock import AsyncMock, patch

from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from main import app


class RoutingPhase3Tests(unittest.TestCase):
    def test_route_risk_endpoints_return_segment_safety_payload(self):
        mocked_payload = {
            "safety_score": 77.0,
            "segment_count": 1,
            "matched_segment_count": 1,
            "unmatched_segment_count": 0,
            "dataset_version": "20260403-174632",
            "segments": [
                {
                    "segment_index": 1,
                    "start": {"lat": 18.52, "lon": 73.85},
                    "end": {"lat": 18.53, "lon": 73.86},
                    "length_m": 123.4,
                    "matched": True,
                    "safety_score": 77.0,
                    "road_segment_id": 42,
                    "road_type": "residential",
                    "lighting": True,
                    "match_distance_m": 1.2,
                    "zone": {
                        "zone_id": "zone-1",
                        "risk_level": "cautious",
                        "risk_score": 0.4,
                    },
                }
            ],
            "warning": None,
        }

        with patch(
            "app.routers.routing.score_route",
            new=AsyncMock(return_value=mocked_payload),
        ):
            with TestClient(app) as client:
                for path in ("/route/risk", "/route/segments/safety"):
                    response = client.post(
                        path,
                        json={
                            "coordinates": [
                                {"lat": 18.52, "lon": 73.85},
                                {"lat": 18.53, "lon": 73.86},
                            ]
                        },
                    )

                    self.assertEqual(response.status_code, 200)
                    body = response.json()
                    self.assertEqual(body["dataset_version"], "20260403-174632")
                    self.assertEqual(body["matched_segment_count"], 1)
                    self.assertEqual(body["segments"][0]["road_segment_id"], 42)
                    self.assertEqual(body["segments"][0]["zone"]["risk_level"], "cautious")

    def test_route_safe_returns_route_metadata_with_segment_safety(self):
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
            "dataset_version": "20260403-174632",
            "segments": [
                {
                    "segment_index": 1,
                    "start": {"lat": 18.52, "lon": 73.85},
                    "end": {"lat": 18.525, "lon": 73.855},
                    "length_m": 100.0,
                    "matched": True,
                    "safety_score": 70.0,
                    "road_segment_id": 101,
                    "road_type": "residential",
                    "lighting": False,
                    "match_distance_m": 0.5,
                    "zone": None,
                },
                {
                    "segment_index": 2,
                    "start": {"lat": 18.525, "lon": 73.855},
                    "end": {"lat": 18.53, "lon": 73.86},
                    "length_m": 110.0,
                    "matched": True,
                    "safety_score": 59.0,
                    "road_segment_id": 102,
                    "road_type": "tertiary",
                    "lighting": True,
                    "match_distance_m": 0.7,
                    "zone": {
                        "zone_id": "zone-2",
                        "risk_level": "risky",
                        "risk_score": 0.7,
                    },
                },
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
        self.assertEqual(body["distance_km"], 2.5)
        self.assertEqual(body["duration_minutes"], 29.7)
        self.assertEqual(body["dataset_version"], "20260403-174632")
        self.assertEqual(body["coordinates"], [[18.52, 73.85], [18.53, 73.86]])
        self.assertEqual(body["segments"][1]["zone"]["zone_id"], "zone-2")


if __name__ == "__main__":
    unittest.main()
