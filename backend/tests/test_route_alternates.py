import unittest
from unittest.mock import AsyncMock, patch

from fastapi.testclient import TestClient

from app.main import app


def _route(coordinates, duration_minutes, distance_km=2.0):
    return {
        "coordinates": coordinates,
        "distance_km": distance_km,
        "duration_minutes": duration_minutes,
        "safety_score": None,
    }


def _score(comfort_score, safety_score=70.0):
    return {
        "safety_score": safety_score,
        "comfort_score": comfort_score,
        "comfort_level": "moderate",
        "segment_count": 1,
        "matched_segment_count": 1,
        "unmatched_segment_count": 0,
        "applied_incident_count": 0,
        "incident_affected_segment_count": 0,
        "dataset_version": "roads-v1",
        "segments": [],
        "warning": None,
    }


class RouteAlternatesSelectionTests(unittest.TestCase):
    """S-070 Option A: /route-safe silently picks the safest candidate
    among Valhalla alternates within a bounded time penalty — no
    user-facing option list."""

    def _call(self, candidates, scores):
        with patch(
            "app.routers.routing.get_route_candidates",
            new=AsyncMock(return_value=candidates),
        ), patch(
            "app.routers.routing.score_route",
            new=AsyncMock(side_effect=list(scores)),
        ):
            with TestClient(app) as client:
                return client.get(
                    "/route-safe",
                    params={
                        "start_lat": 18.52,
                        "start_lon": 73.85,
                        "end_lat": 18.53,
                        "end_lon": 73.86,
                    },
                )

    def test_safest_candidate_wins_when_meaningfully_better_within_time_cap(
        self,
    ):
        fast = _route([[18.52, 73.85]], 25.0)
        safer = _route([[18.52, 73.84]], 29.0)  # +4 min, within cap (12.25)
        response = self._call(
            candidates=[fast, safer],
            scores=[_score(comfort_score=60.0), _score(comfort_score=75.0)],
        )

        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertEqual(body["route_selection"]["chosen"], "safest")
        self.assertEqual(body["route_selection"]["candidates"], 2)
        self.assertEqual(body["route_selection"]["comfort_gain"], 15.0)
        self.assertEqual(body["coordinates"], [[18.52, 73.84]])
        self.assertEqual(body["duration_minutes"], 29.0)

    def test_time_cap_keeps_fastest_when_safest_is_much_slower(self):
        fast = _route([[18.52, 73.85]], 25.0)
        safer = _route([[18.52, 73.84]], 40.0)  # +15 min > cap (12.25)
        response = self._call(
            candidates=[fast, safer],
            scores=[_score(comfort_score=60.0), _score(comfort_score=75.0)],
        )

        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertEqual(body["route_selection"]["chosen"], "fastest")
        self.assertIsNone(body["route_selection"]["comfort_gain"])
        self.assertEqual(body["coordinates"], [[18.52, 73.85]])
        self.assertEqual(body["duration_minutes"], 25.0)

    def test_marginal_gain_beyond_a_minute_keeps_the_fastest_route(self):
        fast = _route([[18.52, 73.85]], 25.0)
        slightly_safer = _route([[18.52, 73.84]], 30.0)  # +5 min, gain 1.0
        response = self._call(
            candidates=[fast, slightly_safer],
            scores=[_score(comfort_score=60.0), _score(comfort_score=61.0)],
        )

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["route_selection"]["chosen"], "fastest")

    def test_small_gain_is_accepted_when_essentially_as_fast(self):
        fast = _route([[18.52, 73.85]], 25.0)
        slightly_safer = _route([[18.52, 73.84]], 25.5)  # +0.5 min, gain 1.0
        response = self._call(
            candidates=[fast, slightly_safer],
            scores=[_score(comfort_score=60.0), _score(comfort_score=61.0)],
        )

        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertEqual(body["route_selection"]["chosen"], "safest")
        self.assertEqual(body["coordinates"], [[18.52, 73.84]])

    def test_candidates_without_comfort_data_fall_back_to_fastest(self):
        fast = _route([[18.52, 73.85]], 25.0)
        other = _route([[18.52, 73.84]], 26.0)
        response = self._call(
            candidates=[fast, other],
            scores=[_score(comfort_score=None), _score(comfort_score=None)],
        )

        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertEqual(body["route_selection"]["chosen"], "fastest")
        self.assertEqual(body["coordinates"], [[18.52, 73.85]])

    def test_single_candidate_reports_only_strategy(self):
        only = _route([[18.52, 73.85]], 25.0)
        response = self._call(
            candidates=[only],
            scores=[_score(comfort_score=64.5)],
        )

        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertEqual(body["route_selection"]["chosen"], "only")
        self.assertEqual(body["route_selection"]["candidates"], 1)
        self.assertEqual(body["coordinates"], [[18.52, 73.85]])


if __name__ == "__main__":
    unittest.main()
