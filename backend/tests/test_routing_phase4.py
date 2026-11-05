import json
import sys
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import AsyncMock, patch

from shapely.geometry import LineString, Polygon

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.services.reporting_service import ReportingService
from app.services.risk_engine import score_route
from app.services.safety_dataset_cache import (
    CachedRoadSegment,
    CachedSafetyZone,
    SafetyDatasetSnapshot,
)


class FakeRow:
    def __init__(self, mapping):
        self._mapping = mapping


class FakeResult:
    def __init__(self, rows):
        self._rows = rows

    def fetchall(self):
        return self._rows


class FakeAsyncSession:
    def __init__(self, rows):
        self.rows = rows
        self.calls = []

    async def execute(self, query, params):
        self.calls.append((str(query), params))
        return FakeResult(self.rows)


class RoutingPhase4Tests(unittest.IsolatedAsyncioTestCase):
    async def test_reporting_service_aggregates_incidents_per_road_segment(self):
        db = FakeAsyncSession(
            [
                FakeRow(
                    {
                        "road_segment_id": 101,
                        "incident_count": 2,
                        "incident_weight": 1.275,
                        "latest_incident_at": datetime(
                            2026,
                            4,
                            2,
                            8,
                            30,
                            tzinfo=timezone.utc,
                        ),
                        "incident_categories": ["Harassment", "Poor lighting"],
                    }
                )
            ]
        )

        aggregates = await ReportingService().get_segment_incident_aggregates(
            road_segment_ids=[101, 102],
            dataset_version="20260403-174632",
            db=db,
        )

        query, params = db.calls[0]
        self.assertIn("FROM incident_reports report", query)
        self.assertIn("FROM road_segments", query)
        self.assertIn(
            "LOWER(COALESCE(report.status, 'pending')) = 'verified'",
            query,
        )
        self.assertNotIn("WHEN 'confirmed' THEN 1.0", query)
        self.assertNotIn("WHEN 'resolved' THEN 0.4", query)
        self.assertEqual(params["dataset_version"], "20260403-174632")
        self.assertEqual(params["road_segment_ids"], [101, 102])
        self.assertEqual(aggregates[101]["incident_count"], 2)
        self.assertEqual(aggregates[101]["incident_weight"], 1.275)
        self.assertEqual(
            aggregates[101]["incident_categories"],
            ["Harassment", "Poor lighting"],
        )
        self.assertEqual(
            aggregates[101]["latest_incident_at"],
            "2026-04-02T08:30:00+00:00",
        )

    async def test_score_route_applies_incident_penalties_to_segment_scores(self):
        db = object()
        snapshot = SafetyDatasetSnapshot(
            road_dataset_version="20260403-174632",
            zone_dataset_version="20260403-174632",
            road_segments=[
                CachedRoadSegment(
                    segment_id=101,
                    safety_score=70.0,
                    road_type="residential",
                    lighting=True,
                    geometry=LineString([(73.85, 18.52), (73.855, 18.525)]),
                ),
                CachedRoadSegment(
                    segment_id=102,
                    safety_score=80.0,
                    road_type="tertiary",
                    lighting=False,
                    geometry=LineString([(73.855, 18.525), (73.86, 18.53)]),
                ),
            ],
            safety_zones=[
                CachedSafetyZone(
                    zone_id="zone-1",
                    risk_level="cautious",
                    risk_score=0.35,
                    dataset_version="20260403-174632",
                    geometry=Polygon(
                        [
                            (73.854, 18.524),
                            (73.861, 18.524),
                            (73.861, 18.531),
                            (73.854, 18.531),
                            (73.854, 18.524),
                        ]
                    ),
                )
            ],
        )

        with patch(
            "app.services.risk_engine.safety_dataset_cache.get_snapshot",
            new=AsyncMock(return_value=snapshot),
        ), patch(
            "app.services.risk_engine.reporting_service.get_segment_incident_aggregates",
            new=AsyncMock(
                return_value={
                    101: {
                        "incident_count": 2,
                        "incident_weight": 1.25,
                        "incident_categories": ["Harassment"],
                        "latest_incident_at": "2026-04-02T08:30:00+00:00",
                    }
                }
            ),
        ):
            scored = await score_route(
                [(18.52, 73.85), (18.525, 73.855), (18.53, 73.86)],
                db,
            )

        self.assertEqual(scored["dataset_version"], "20260403-174632")
        self.assertEqual(scored["applied_incident_count"], 2)
        self.assertEqual(scored["incident_affected_segment_count"], 1)
        self.assertEqual(scored["safety_score"], 67.5)
        self.assertEqual(scored["segments"][0]["base_safety_score"], 70.0)
        self.assertEqual(scored["segments"][0]["safety_score"], 55.0)
        self.assertEqual(scored["segments"][0]["incident_penalty"], 15.0)
        self.assertEqual(scored["segments"][0]["incident_count"], 2)
        self.assertEqual(
            scored["segments"][0]["latest_incident_at"],
            "2026-04-02T08:30:00+00:00",
        )
        self.assertEqual(scored["segments"][1]["safety_score"], 80.0)
        self.assertEqual(scored["segments"][1]["zone"]["zone_id"], "zone-1")


class VerifiedReportImpactTests(unittest.IsolatedAsyncioTestCase):
    """R-104: route-level before/after + mapped incident coordinates."""

    async def test_score_route_returns_before_after_delta_and_points(self):
        db = object()
        snapshot = SafetyDatasetSnapshot(
            road_dataset_version="20260403-174632",
            zone_dataset_version="20260403-174632",
            road_segments=[
                CachedRoadSegment(
                    segment_id=501,
                    safety_score=70.0,
                    road_type="residential",
                    lighting=True,
                    geometry=LineString([(73.85, 18.52), (73.855, 18.525)]),
                ),
            ],
            safety_zones=[],
        )

        with patch(
            "app.services.risk_engine.safety_dataset_cache.get_snapshot",
            new=AsyncMock(return_value=snapshot),
        ), patch(
            "app.services.risk_engine.reporting_service.get_segment_incident_aggregates",
            new=AsyncMock(
                return_value={
                    501: {
                        "incident_count": 3,
                        "incident_weight": 1.25,
                        "incident_categories": ["Harassment"],
                        "latest_incident_at": "2026-11-02T13:51:01+00:00",
                        "incident_points": [
                            {
                                "id": "23",
                                "lat": 18.52995,
                                "lon": 73.86327,
                                "category": "unsafe_infrastructure",
                                "severity": 5,
                            },
                            {
                                "id": "24",
                                "lat": 18.52995,
                                "lon": 73.86330,
                                "category": "poor_lighting",
                                "severity": 3,
                            },
                        ],
                    }
                }
            ),
        ):
            scored = await score_route([(18.52, 73.85), (18.525, 73.855)], db)

        self.assertEqual(scored["base_safety_score"], 70.0)
        self.assertEqual(scored["safety_score"], 55.0)
        self.assertEqual(scored["incident_score_delta"], 15.0)
        self.assertEqual(len(scored["incident_points"]), 2)
        self.assertEqual(scored["incident_points"][0]["id"], "23")
        self.assertEqual(scored["incident_points"][0]["lat"], 18.52995)
        self.assertEqual(scored["incident_points"][0]["severity"], 5)

    async def test_score_route_without_incidents_has_no_delta_and_no_points(
        self,
    ):
        db = object()
        snapshot = SafetyDatasetSnapshot(
            road_dataset_version="20260403-174632",
            zone_dataset_version="20260403-174632",
            road_segments=[
                CachedRoadSegment(
                    segment_id=502,
                    safety_score=88.0,
                    road_type="tertiary",
                    lighting=True,
                    geometry=LineString([(73.85, 18.52), (73.855, 18.525)]),
                ),
            ],
            safety_zones=[],
        )

        with patch(
            "app.services.risk_engine.safety_dataset_cache.get_snapshot",
            new=AsyncMock(return_value=snapshot),
        ), patch(
            "app.services.risk_engine.reporting_service.get_segment_incident_aggregates",
            new=AsyncMock(return_value={}),
        ):
            scored = await score_route([(18.52, 73.85), (18.525, 73.855)], db)

        self.assertEqual(scored["base_safety_score"], 88.0)
        self.assertEqual(scored["safety_score"], 88.0)
        self.assertEqual(scored["incident_score_delta"], 0.0)
        self.assertEqual(scored["incident_points"], [])

    async def test_parse_incident_points_degrades_safely(self):
        parse = ReportingService._parse_incident_points

        self.assertEqual(parse(None), [])
        self.assertEqual(parse(""), [])
        self.assertEqual(parse("not json"), [])

        parsed = parse(
            json.dumps(
                [
                    {
                        "id": 31,
                        "lat": 18.56161,
                        "lon": 73.80698,
                        "category": "suspicious_activity",
                        "severity": 4,
                    },
                    {"lat": 19.0, "lon": 74.0},  # missing id -> str(None)
                    {"lat": None, "lon": 73.0},  # dropped
                    "garbage",  # dropped
                ]
            )
        )
        self.assertEqual(len(parsed), 2)
        self.assertEqual(parsed[0]["id"], "31")
        self.assertEqual(parsed[0]["severity"], 4)
        self.assertEqual(parsed[1]["id"], "None")

        # asyncpg may hand back a text-decoded JSON string.
        self.assertEqual(len(parse('[{"id": 1, "lat": 18.5, "lon": 73.8}]')), 1)


class SeverityFactorTests(unittest.IsolatedAsyncioTestCase):
    """R-075 option A: verified-report severity is a weight factor, sev-3 neutral."""

    async def test_aggregate_query_carries_severity_factor_and_neutrality(self):
        db = FakeAsyncSession(
            [
                FakeRow(
                    {
                        "road_segment_id": 201,
                        "incident_count": 1,
                        "incident_weight": 1.35,
                        "max_incident_severity": 5,
                        "latest_incident_at": None,
                        "incident_categories": ["Harassment"],
                    }
                )
            ]
        )

        aggregates = await ReportingService().get_segment_incident_aggregates(
            road_segment_ids=[201],
            dataset_version="20260403-174632",
            db=db,
        )

        query, _params = db.calls[0]
        self.assertIn("report.severity,", query)
        self.assertIn("MAX(severity) AS max_incident_severity", query)
        self.assertIn("WHEN severity IS NULL THEN 1.0", query)
        self.assertIn("WHEN severity <= 1 THEN 0.5", query)
        self.assertIn("WHEN severity = 2 THEN 0.75", query)
        self.assertIn("WHEN severity = 3 THEN 1.0", query)
        self.assertIn("WHEN severity = 4 THEN 1.25", query)
        self.assertIn("ELSE 1.5", query)

        self.assertEqual(aggregates[201]["max_incident_severity"], 5)

        db_no_severity = FakeAsyncSession(
            [
                FakeRow(
                    {
                        "road_segment_id": 202,
                        "incident_count": 1,
                        "incident_weight": 0.9,
                        "max_incident_severity": None,
                        "latest_incident_at": None,
                        "incident_categories": [],
                    }
                )
            ]
        )
        aggregates = await ReportingService().get_segment_incident_aggregates(
            road_segment_ids=[202],
            dataset_version="20260403-174632",
            db=db_no_severity,
        )
        self.assertIsNone(aggregates[202]["max_incident_severity"])

    async def test_score_route_surfaces_max_incident_severity(self):
        db = object()
        snapshot = SafetyDatasetSnapshot(
            road_dataset_version="20260403-174632",
            zone_dataset_version="20260403-174632",
            road_segments=[
                CachedRoadSegment(
                    segment_id=301,
                    safety_score=70.0,
                    road_type="residential",
                    lighting=True,
                    geometry=LineString([(73.85, 18.52), (73.855, 18.525)]),
                ),
            ],
            safety_zones=[],
        )

        with patch(
            "app.services.risk_engine.safety_dataset_cache.get_snapshot",
            new=AsyncMock(return_value=snapshot),
        ), patch(
            "app.services.risk_engine.reporting_service.get_segment_incident_aggregates",
            new=AsyncMock(
                return_value={
                    301: {
                        "incident_count": 1,
                        "incident_weight": 1.35,
                        "incident_categories": ["Harassment"],
                        "max_incident_severity": 5,
                        "latest_incident_at": None,
                    }
                }
            ),
        ):
            scored = await score_route([(18.52, 73.85), (18.525, 73.855)], db)

        self.assertEqual(scored["segments"][0]["max_incident_severity"], 5)
        # Penalty math itself is unchanged: min(25, 1.35 * 12) = 16.2.
        self.assertEqual(scored["segments"][0]["incident_penalty"], 16.2)
        self.assertEqual(scored["segments"][0]["incident_weight"], 1.35)

    async def test_score_route_defaults_max_incident_severity_to_none(self):
        db = object()
        snapshot = SafetyDatasetSnapshot(
            road_dataset_version="20260403-174632",
            zone_dataset_version="20260403-174632",
            road_segments=[
                CachedRoadSegment(
                    segment_id=302,
                    safety_score=70.0,
                    road_type="residential",
                    lighting=True,
                    geometry=LineString([(73.85, 18.52), (73.855, 18.525)]),
                ),
            ],
            safety_zones=[],
        )

        with patch(
            "app.services.risk_engine.safety_dataset_cache.get_snapshot",
            new=AsyncMock(return_value=snapshot),
        ), patch(
            "app.services.risk_engine.reporting_service.get_segment_incident_aggregates",
            new=AsyncMock(
                return_value={
                    302: {
                        "incident_count": 1,
                        "incident_weight": 0.9,
                        "incident_categories": [],
                        "latest_incident_at": None,
                    }
                }
            ),
        ):
            scored = await score_route([(18.52, 73.85), (18.525, 73.855)], db)

        self.assertIsNone(scored["segments"][0]["max_incident_severity"])


if __name__ == "__main__":
    unittest.main()
