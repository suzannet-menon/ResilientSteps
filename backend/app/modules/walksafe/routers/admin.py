"""
WalkSafe Admin Moderation Endpoints
=====================================
Used by the operator to verify or reject pending incident reports.
All endpoints require the X-Admin-Key header.

Usage with curl:
  List pending reports:
    curl http://localhost:8000/admin/reports?status=pending \
         -H "X-Admin-Key: YOUR_ADMIN_KEY"

  Verify a report (id = 5):
    curl -X POST http://localhost:8000/admin/reports/5/verify \
         -H "X-Admin-Key: YOUR_ADMIN_KEY"

  Reject a report (id = 5):
    curl -X POST http://localhost:8000/admin/reports/5/reject \
         -H "X-Admin-Key: YOUR_ADMIN_KEY"
"""
import hmac
import os
from datetime import datetime, timezone

from dotenv import load_dotenv
from fastapi import APIRouter, Depends, Header, HTTPException
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_db

load_dotenv()

router = APIRouter(prefix="/admin", tags=["Admin Moderation"])

ADMIN_API_KEY = os.environ.get("ADMIN_API_KEY")
if not ADMIN_API_KEY:
    raise RuntimeError(
        "ADMIN_API_KEY is not set in backend/.env. "
        "Add a line like: ADMIN_API_KEY=choose-any-long-random-string"
    )


async def require_admin(x_admin_key: str = Header(...)):
    """Dependency that blocks all admin routes unless the correct key is supplied."""
    if not hmac.compare_digest(x_admin_key.encode(), ADMIN_API_KEY.encode()):
        raise HTTPException(
            status_code=403,
            detail="Invalid admin key. Supply the correct key in the X-Admin-Key header.",
        )


@router.get("/reports")
async def list_reports(
    status: str = "pending",
    report_type: str | None = None,
    db: AsyncSession = Depends(get_db),
    _: None = Depends(require_admin),
):
    """
    List incident reports by status and optional report_type.
    status can be: pending, verified, rejected
    report_type can be: safety, infrastructure, waste, etc.
    """
    if status not in ("pending", "verified", "rejected"):
        raise HTTPException(
            status_code=400,
            detail="status must be one of: pending, verified, rejected",
        )

    params: dict = {"status": status, "report_type": report_type}
    result = await db.execute(
        text(
            """
            SELECT
                id,
                user_hash,
                category,
                description,
                ST_Y(location) AS latitude,
                ST_X(location) AS longitude,
                status,
                confidence,
                submitted_at,
                moderated_at,
                COALESCE(report_type, 'safety') AS report_type,
                COALESCE(severity, 3) AS severity,
                COALESCE(model_name, '') AS model_name,
                COALESCE(model_confidence, 0.0) AS model_confidence,
                auto_moderated,
                COALESCE(metadata->'ai', '{}'::jsonb) AS ai
            FROM incident_reports
            WHERE status = :status
            AND (CAST(:report_type AS text) IS NULL
                 OR report_type = CAST(:report_type AS text))
            ORDER BY submitted_at DESC
            LIMIT 100
            """
        ),
        params,
    )

    rows = result.fetchall()
    return {
        "status_filter": status,
        "report_type_filter": report_type,
        "count": len(rows),
        "reports": [dict(row._mapping) for row in rows],
    }


@router.post("/reports/{report_id}/verify")
async def verify_report(
    report_id: int,
    db: AsyncSession = Depends(get_db),
    _: None = Depends(require_admin),
):
    """
    Mark a report as verified. This allows it to affect route safety scores
    through dynamic incident scoring only.
    """
    result = await db.execute(
        text(
            """
            SELECT id, status
            FROM incident_reports
            WHERE id = :id
            """
        ),
        {"id": report_id},
    )
    row = result.fetchone()

    if row is None:
        raise HTTPException(status_code=404, detail=f"Report {report_id} not found")

    if row.status == "verified":
        return {"message": f"Report {report_id} is already verified"}

    if row.status == "rejected":
        raise HTTPException(
            status_code=409,
            detail=(
                f"Report {report_id} has been rejected and cannot be verified. "
                "Rejected reports cannot change status."
            ),
        )

    await db.execute(
        text(
            """
            UPDATE incident_reports
            SET
                status = 'verified',
                moderated_at = :now
            WHERE id = :id
            """
        ),
        {"id": report_id, "now": datetime.now(timezone.utc)},
    )
    await db.commit()

    return {
        "message": f"Report {report_id} verified",
        "penalty_applied": 0.0,
        "road_segments_updated": 0,
    }


@router.post("/reports/{report_id}/reject")
async def reject_report(
    report_id: int,
    db: AsyncSession = Depends(get_db),
    _: None = Depends(require_admin),
):
    """
    Mark a report as rejected. Rejected reports never affect route safety scores.
    """
    result = await db.execute(
        text(
            """
            SELECT id, status
            FROM incident_reports
            WHERE id = :id
            """
        ),
        {"id": report_id},
    )
    row = result.fetchone()

    if row is None:
        raise HTTPException(status_code=404, detail=f"Report {report_id} not found")

    if row.status == "rejected":
        return {"message": f"Report {report_id} is already rejected"}

    await db.execute(
        text(
            """
            UPDATE incident_reports
            SET
                status = 'rejected',
                moderated_at = :now
            WHERE id = :id
            """
        ),
        {"id": report_id, "now": datetime.now(timezone.utc)},
    )
    await db.commit()

    return {"message": f"Report {report_id} rejected"}
