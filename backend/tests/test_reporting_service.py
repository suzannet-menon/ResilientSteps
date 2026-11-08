import json
import unittest
from datetime import datetime, timezone

from app.schemas.reports import EmergencyAlertCreate, ReportCreate, TrustedContactPayload
from app.services.reporting_service import ReportingService


class _FakeRow:
    def __init__(self, mapping):
        self._mapping = mapping


class _FakeResult:
    def __init__(self, *, row=None, rows=None):
        self._row = _FakeRow(row) if row is not None else None
        self._rows = [_FakeRow(mapping) for mapping in (rows or [])]

    def fetchone(self):
        return self._row

    def fetchall(self):
        return self._rows


class _RecordingAsyncSession:
    def __init__(self, handler):
        self._handler = handler
        self.calls = []
        self.commits = 0

    async def execute(self, query, params=None):
        sql = str(query)
        normalized_params = params or {}
        self.calls.append((sql, normalized_params))
        return self._handler(sql, normalized_params)

    async def commit(self):
        self.commits += 1


class ReportingServiceContractTests(unittest.IsolatedAsyncioTestCase):
    async def test_create_report_persists_pending_incident_and_returns_created_row(self):
        submitted_at = datetime(2026, 4, 6, 10, 30, tzinfo=timezone.utc)

        def handler(sql, _params):
            if "INSERT INTO incident_reports" in sql:
                return _FakeResult(
                    row={
                        "id": "report-1",
                        "status": "pending",
                        "confidence": 0.5,
                        "submitted_at": submitted_at,
                    }
                )
            raise AssertionError(f"Unexpected query: {sql}")

        session = _RecordingAsyncSession(handler)
        created = await ReportingService().create_report(
            ReportCreate(
                user_hash="user-123",
                incident_type="Poor lighting",
                severity=3,
                lat=18.52,
                lon=73.85,
                description="Dark stretch",
                metadata={"source": "test"},
            ),
            session,
        )

        insert_sql, insert_params = session.calls[0]
        self.assertIn("INSERT INTO incident_reports", insert_sql)
        self.assertIn("'pending'", insert_sql)
        self.assertEqual(insert_params["user_hash"], "user-123")
        self.assertEqual(insert_params["category"], "poor_lighting")
        self.assertEqual(insert_params["confidence"], 0.5)
        self.assertEqual(
            json.loads(insert_params["metadata"]), {"source": "test"}
        )
        self.assertEqual(created["id"], "report-1")
        self.assertEqual(created["status"], "pending")
        self.assertEqual(created["submitted_at"], submitted_at)
        # Create must commit immediately: the Nugen background task needs the
        # row visible before the dependency teardown would run.
        self.assertEqual(session.commits, 1)

    async def test_apply_ai_classification_persists_payload_and_fields(self):
        from types import SimpleNamespace
        from unittest import mock

        from app.core.nugen_service import NugenClassification

        recorded = {}

        class _FakeSession:
            async def __aenter__(self):
                return self

            async def __aexit__(self, *args):
                return False

            async def execute(self, query, params=None):
                recorded["sql"] = str(query)
                recorded["params"] = params

            async def commit(self):
                recorded["committed"] = True

        classification = NugenClassification(
            category="poor_lighting",
            severity=4,
            confidence=0.85,
            reason="very dark street",
            model_name="test-model",
            severity_label="High",
        )

        def fake_factory():
            return _FakeSession()

        with mock.patch(
            "app.core.database.AsyncSessionLocal", new=fake_factory
        ), mock.patch(
            "app.core.nugen_service.nugen_service.classify_report",
            new=mock.AsyncMock(return_value=classification),
        ):
            outcome = await ReportingService().apply_ai_classification(
                report_id="12",
                description="dark stretch",
                provided_category="poor_lighting",
                allowed_category_codes=["poor_lighting"],
            )

        self.assertTrue(outcome["classified"])
        self.assertTrue(recorded["committed"])
        self.assertIn("UPDATE incident_reports", recorded["sql"])
        self.assertIn("model_confidence", recorded["sql"])
        self.assertIn("metadata", recorded["sql"])
        # R-079 merge: AI severity may raise but never lower the
        # operator-provided severity already on the row.
        self.assertIn("GREATEST(COALESCE(severity, 3), :severity)", recorded["sql"])
        params = recorded["params"]
        self.assertEqual(params["category"], "poor_lighting")
        self.assertEqual(params["severity"], 4)
        self.assertEqual(params["confidence"], 0.85)
        ai_payload = json.loads(params["ai_payload"])
        self.assertEqual(ai_payload["source"], "nugen")
        self.assertEqual(ai_payload["model"], "test-model")
        self.assertEqual(ai_payload["severity"], 4)
        self.assertEqual(ai_payload["severity_label"], "High")

    async def test_apply_ai_classification_degrades_when_nugen_unavailable(self):
        from unittest import mock

        with mock.patch(
            "app.core.nugen_service.nugen_service.classify_report",
            new=mock.AsyncMock(return_value=None),
        ):
            outcome = await ReportingService().apply_ai_classification(
                report_id="12",
                description="dark stretch",
                provided_category="poor_lighting",
                allowed_category_codes=["poor_lighting"],
            )

        self.assertFalse(outcome["classified"])

    async def test_apply_ai_classification_skips_network_for_empty_description(self):
        # Empty description -> the model has nothing to verify (report id 20:
        # it hallucinated a reason AND self-reported 0.8). No Nugen call at
        # all; the row keeps its insert-time confidence (0.5).
        from unittest import mock

        classify_mock = mock.AsyncMock(side_effect=AssertionError("must not be called"))

        with mock.patch(
            "app.core.nugen_service.nugen_service.classify_report", new=classify_mock
        ):
            outcome = await ReportingService().apply_ai_classification(
                report_id="12",
                description="   ",
                provided_category="unsafe_infrastructure",
                allowed_category_codes=["unsafe_infrastructure"],
            )

        self.assertFalse(outcome["classified"])
        self.assertEqual(outcome.get("skipped"), "empty_description")
        classify_mock.assert_not_called()

    async def test_get_recent_reports_shapes_rows_for_api_response(self):
        created_at = datetime(2026, 4, 6, 11, 0, tzinfo=timezone.utc)

        def handler(sql, params):
            if "FROM incident_reports" in sql:
                self.assertEqual(params["limit"], 5)
                return _FakeResult(
                    rows=[
                        {
                            "id": "report-2",
                            "lat": 18.52,
                            "lon": 73.85,
                            "incident_type": "Harassment",
                            "severity": 3,
                            "confidence_score": 0.9,
                            "created_at": created_at,
                            "status": "verified",
                        }
                    ]
                )
            raise AssertionError(f"Unexpected query: {sql}")

        session = _RecordingAsyncSession(handler)
        reports = await ReportingService().get_recent_reports(limit=5, db=session)

        self.assertEqual(len(reports), 1)
        self.assertEqual(reports[0]["id"], "report-2")
        self.assertEqual(reports[0]["incident_type"], "Harassment")
        self.assertEqual(reports[0]["confidence_score"], 0.9)
        self.assertEqual(reports[0]["status"], "verified")
        self.assertEqual(reports[0]["created_at"], created_at)

    async def test_create_emergency_alert_serializes_named_and_plain_contacts(self):
        created_at = datetime(2026, 4, 6, 12, 0, tzinfo=timezone.utc)

        def handler(sql, _params):
            if "INSERT INTO emergency_alerts" in sql:
                return _FakeResult(
                    row={
                        "id": "emergency-2",
                        "status": "triggered",
                        "created_at": created_at,
                        "contacts_notified": 2,
                        "metadata": {},
                    }
                )
            return _FakeResult()

        session = _RecordingAsyncSession(handler)
        created = await ReportingService().create_emergency_alert(
            EmergencyAlertCreate(
                user_hash="user-999",
                lat=18.52,
                lon=73.85,
                message="Need help",
                trusted_contacts=[
                    " sister@walksafe.local ",
                    TrustedContactPayload(name="Alice", phone="+911234567890"),
                    TrustedContactPayload(name="alice", phone="+911234567890"),
                    "",
                ],
                metadata={"source": "test"},
            ),
            session,
        )

        insert_sql, insert_params = next(
            (sql, params)
            for sql, params in session.calls
            if "INSERT INTO emergency_alerts" in sql
        )
        self.assertIn("INSERT INTO emergency_alerts", insert_sql)
        self.assertEqual(insert_params["contacts_notified"], 2)

        metadata = json.loads(insert_params["metadata"])
        self.assertEqual(metadata["source"], "test")
        self.assertEqual(
            metadata["trusted_contacts"],
            [
                "sister@walksafe.local",
                {"name": "Alice", "phone": "+911234567890"},
            ],
        )
        self.assertEqual(
            metadata["trusted_contacts_notified"],
            [
                "sister@walksafe.local",
                {"name": "Alice", "phone": "+911234567890"},
            ],
        )
        self.assertEqual(created["id"], "emergency-2")
        self.assertEqual(created["contacts_notified"], 2)
        self.assertEqual(
            created["trusted_contacts"],
            [
                "sister@walksafe.local",
                {"name": "Alice", "phone": "+911234567890"},
            ],
        )


if __name__ == "__main__":
    unittest.main()
