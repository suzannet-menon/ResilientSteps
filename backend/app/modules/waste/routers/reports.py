from typing import Any, Dict, List
from fastapi import APIRouter, BackgroundTasks, Depends, Query
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.auth_middleware import require_auth
from app.core.database import get_db
from app.core.rate_limiter import report_rate_limiter
from app.modules.waste.schemas.reports import (
    WasteCategoryItem,
    WasteReportCreate,
    WasteReportResponse,
)
from app.modules.walksafe.services.reporting_service import reporting_service
from app.modules.waste.services.waste_reporting_service import (
    WASTE_CATEGORY_CODES,
    waste_reporting_service,
)

router = APIRouter(tags=["Waste Management"])


@router.post("/reports", response_model=WasteReportResponse)
async def create_waste_report(
    payload: WasteReportCreate,
    background_tasks: BackgroundTasks,
    db: AsyncSession = Depends(get_db),
    user_hash: str = Depends(require_auth),
    _: None = Depends(report_rate_limiter),
):
    """
    Submit a citizen waste/sanitation issue report.
    Requires Bearer auth token and is rate limited (5/hr).
    """
    created = await waste_reporting_service.create_report(payload, user_hash, db)

    # WP14 parity for the waste module: optional Nugen enrichment AFTER the
    # response. Degrades to the insert-time values when Nugen is unavailable.
    background_tasks.add_task(
        reporting_service.apply_ai_classification,
        report_id=str(created.get("id", "")),
        description=payload.description or "",
        provided_category=str(payload.category or ""),
        allowed_category_codes=list(WASTE_CATEGORY_CODES),
    )
    return created


@router.get("/reports/recent", response_model=List[Dict[str, Any]])
async def get_recent_waste_reports(
    limit: int = Query(20, ge=1, le=100),
    db: AsyncSession = Depends(get_db),
):
    """
    Get recent verified waste management reports.
    """
    return await waste_reporting_service.get_recent_reports(limit=limit, db=db)


@router.get("/categories", response_model=List[WasteCategoryItem])
async def get_waste_categories(
    db: AsyncSession = Depends(get_db),
):
    """
    Get available waste management report categories.
    """
    return await waste_reporting_service.get_categories(db)
