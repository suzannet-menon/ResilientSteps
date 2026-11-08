from typing import Any, Dict, List, Optional
from fastapi import APIRouter, Depends, Query, Response
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_db
from app.modules.dashboard.schemas.analytics import (
    CitySummary,
    HeatmapPoint,
    TrendPoint,
    WardReportItem,
    WardSummary,
)
from app.modules.dashboard.services.analytics_service import analytics_service
from app.modules.dashboard.services.export_service import export_service
from app.modules.walksafe.routers.admin import require_admin

router = APIRouter(tags=["Dashboard"])


@router.get("/summary", response_model=CitySummary)
async def get_city_summary(
    db: AsyncSession = Depends(get_db),
    _: None = Depends(require_admin),
):
    """
    Get city-wide aggregated report summary across all report types.
    """
    return await analytics_service.get_city_summary(db)


@router.get("/wards", response_model=List[WardSummary])
async def get_ward_summaries(
    db: AsyncSession = Depends(get_db),
    _: None = Depends(require_admin),
):
    """
    Get ward-level report aggregation from materialized view / spatial join.
    """
    return await analytics_service.get_ward_summaries(db)


@router.get("/wards/{ward_id}/reports", response_model=List[WardReportItem])
async def get_ward_reports(
    ward_id: str,
    db: AsyncSession = Depends(get_db),
    _: None = Depends(require_admin),
):
    """
    Get all reports submitted within a specific municipal ward.
    """
    return await analytics_service.get_ward_reports(ward_id, db)


@router.get("/heatmap", response_model=List[HeatmapPoint])
async def get_dashboard_heatmap(
    resolution: int = Query(8, ge=5, le=10),
    db: AsyncSession = Depends(get_db),
    _: None = Depends(require_admin),
):
    """
    Get multi-module H3 heatmap aggregation of verified reports.
    """
    return await analytics_service.get_heatmap(db, resolution=resolution)


@router.get("/trends", response_model=List[TrendPoint])
async def get_dashboard_trends(
    since: Optional[str] = Query(None, description="ISO date YYYY-MM-DD"),
    db: AsyncSession = Depends(get_db),
    _: None = Depends(require_admin),
):
    """
    Get time-series report counts grouped by date and report_type.
    """
    return await analytics_service.get_trends(since, db)


@router.get("/export")
async def export_dashboard_data(
    format: str = Query("csv", pattern="^(csv|json)$"),
    db: AsyncSession = Depends(get_db),
    _: None = Depends(require_admin),
):
    """
    Export all incident reports in CSV or JSON format.
    """
    reports = await analytics_service.get_all_reports_for_export(db)
    if format == "json":
        json_data = export_service.export_json(reports)
        return Response(content=json_data, media_type="application/json")

    csv_data = export_service.export_csv(reports)
    return Response(
        content=csv_data,
        media_type="text/csv",
        headers={"Content-Disposition": "attachment; filename=resilientsteps_reports_export.csv"},
    )


@router.post("/refresh-summary")
async def refresh_ward_summary_view(
    db: AsyncSession = Depends(get_db),
    _: None = Depends(require_admin),
):
    """
    Trigger manual refresh of the ward_report_summary materialized view.
    """
    await analytics_service.refresh_summary_view(db)
    return {"message": "Ward report summary materialized view refreshed successfully"}
