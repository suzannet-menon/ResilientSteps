import logging
from typing import Any, Dict, List
from fastapi import HTTPException
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.infrastructure.schemas.reports import InfraReportCreate
from app.modules.walksafe.services.reporting_service import reporting_service

LOGGER = logging.getLogger(__name__)

DEFAULT_INFRA_CATEGORIES = [
    {"code": "pothole", "label": "Pothole", "description": None, "module": "infrastructure"},
    {"code": "streetlight", "label": "Broken Streetlight", "description": None, "module": "infrastructure"},
    {"code": "footpath", "label": "Damaged Footpath", "description": None, "module": "infrastructure"},
    {"code": "fallen_tree", "label": "Fallen Tree", "description": None, "module": "infrastructure"},
    {"code": "traffic_signal", "label": "Broken Traffic Signal", "description": None, "module": "infrastructure"},
    {"code": "water_leak", "label": "Water Leak", "description": None, "module": "infrastructure"},
    {"code": "waterlogging", "label": "Waterlogging / Flooding", "description": None, "module": "infrastructure"},
    {"code": "obstruction", "label": "Road Obstruction", "description": None, "module": "infrastructure"},
]

# Allowed codes for the optional Nugen classifier (kept in sync with the seeds).
INFRA_CATEGORY_CODES = tuple(
    category["code"] for category in DEFAULT_INFRA_CATEGORIES
)


class InfraReportingService:
    async def get_categories(self, db: AsyncSession) -> List[Dict[str, Any]]:
        try:
            result = await db.execute(
                text(
                    """
                    SELECT code, label, description, module
                    FROM report_categories
                    WHERE module = 'infrastructure'
                    ORDER BY id ASC
                    """
                )
            )
            rows = result.fetchall()
            if rows:
                return [dict(row._mapping) for row in rows]
        except Exception as exc:
            LOGGER.warning("Could not fetch categories from DB table: %s", exc)

        return DEFAULT_INFRA_CATEGORIES

    async def validate_category(self, category: str, db: AsyncSession) -> bool:
        categories = await self.get_categories(db)
        valid_codes = {c["code"].lower() for c in categories}
        valid_labels = {c["label"].lower() for c in categories}
        cat_lower = category.lower()
        return (cat_lower in valid_codes) or (cat_lower in valid_labels)

    async def create_report(
        self,
        report: InfraReportCreate,
        user_hash: str,
        db: AsyncSession,
    ) -> Dict[str, Any]:
        is_valid = await self.validate_category(report.category, db)
        if not is_valid:
            raise HTTPException(
                status_code=400,
                detail=f"Invalid infrastructure category: '{report.category}'.",
            )

        report_with_hash = type(
            "InfraReportWithHash",
            (),
            {
                "user_hash": user_hash,
                "category": report.category,
                "description": report.description,
                "lat": report.lat,
                "lon": report.lon,
                "severity": report.severity,
                "report_type": "infrastructure",
            },
        )()

        created = await reporting_service.create_report(
            report_with_hash,
            db,
            report_type="infrastructure",
            severity=report.severity,
        )
        created["report_type"] = "infrastructure"
        created["severity"] = report.severity
        return created

    async def get_recent_reports(
        self,
        limit: int,
        db: AsyncSession,
    ) -> List[Dict[str, Any]]:
        return await reporting_service.get_recent_reports(
            limit=limit,
            db=db,
            report_type="infrastructure",
        )


infra_reporting_service = InfraReportingService()
