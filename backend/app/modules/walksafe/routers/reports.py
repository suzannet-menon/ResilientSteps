import logging
from typing import List

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.auth_middleware import require_auth
from app.core.rate_limiter import emergency_rate_limiter, report_rate_limiter
from app.core.database import get_db
from app.modules.walksafe.schemas.reports import (
    EmergencyAlertCreate,
    EmergencyAlertResponse,
    RecentReport,
    ReportCreate,
    ReportResponse,
)
from app.modules.walksafe.services.reporting_service import (
    SAFETY_CATEGORY_CODES,
    reporting_service,
)

LOGGER = logging.getLogger(__name__)

router = APIRouter()


def _serialize_trusted_contact(contact: object) -> object:
    if isinstance(contact, dict):
        name = str(contact.get("name", "")).strip()
        phone = str(contact.get("phone", "")).strip()
        if not name or not phone:
            return None
        return {"name": name, "phone": phone}

    return str(contact).strip() if contact is not None else None


def _serialize_trusted_contacts(contacts: object) -> list[object]:
    serialized_contacts: list[object] = []
    for contact in contacts if isinstance(contacts, list) else []:
        serialized = _serialize_trusted_contact(contact)
        if serialized is not None:
            serialized_contacts.append(serialized)
    return serialized_contacts


@router.post("/reports", response_model=ReportResponse)
async def submit_report(
    report: ReportCreate,
    background_tasks: BackgroundTasks,
    db: AsyncSession = Depends(get_db),
    user_id: str = Depends(require_auth),
    _rate: None = Depends(report_rate_limiter),
):
    # Override client-supplied user_hash with the authenticated user ID.
    report.user_hash = user_id
    try:
        created = await reporting_service.create_report(report, db)
    except Exception as exc:
        LOGGER.error("Failed to persist report: %s", exc, exc_info=True)
        raise HTTPException(
            status_code=503,
            detail="Failed to persist report",
        ) from exc

    report_id = str(created.get("id", ""))
    status = str(created.get("status", "pending"))

    # WP14: optional Nugen enrichment AFTER the response is sent. Degrades to
    # the insert-time values if Nugen is unavailable (S-103 offline rule).
    background_tasks.add_task(
        reporting_service.apply_ai_classification,
        report_id=report_id,
        description=report.description or "",
        provided_category=str(report.category or ""),
        allowed_category_codes=list(SAFETY_CATEGORY_CODES),
    )

    return ReportResponse(
        id=report_id,
        status=status,
        message="Thank you for your report. It will be verified.",
    )


@router.get("/reports/recent", response_model=List[RecentReport])
async def get_recent_reports(
    limit: int = 50,
    db: AsyncSession = Depends(get_db),
):
    bounded_limit = max(1, min(limit, 200))
    return await reporting_service.get_recent_reports(limit=bounded_limit, db=db)


@router.post("/reports/emergency", response_model=EmergencyAlertResponse)
async def create_emergency_alert(
    alert: EmergencyAlertCreate,
    db: AsyncSession = Depends(get_db),
    user_id: str = Depends(require_auth),
    _rate: None = Depends(emergency_rate_limiter),
):
    # Override client-supplied user_hash with the authenticated user ID.
    alert.user_hash = user_id
    try:
        created = await reporting_service.create_emergency_alert(alert, db)
    except Exception as exc:
        LOGGER.error("Failed to persist emergency alert: %s", exc, exc_info=True)
        raise HTTPException(
            status_code=503,
            detail="Failed to persist emergency alert",
        ) from exc

    return EmergencyAlertResponse(
        id=str(created.get("id", "")),
        status=str(created.get("status", "pending")),
        created_at=created.get("created_at"),
        message=str(created.get("message", "Emergency alert has been recorded.")),
        contacts_notified=int(created.get("contacts_notified", 0)),
        trusted_contacts=_serialize_trusted_contacts(
            created.get("trusted_contacts") or [],
        ),
    )
