import logging
from typing import Any, Dict, List
from fastapi import HTTPException
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.waste.schemas.reports import WasteReportCreate
from app.modules.walksafe.services.reporting_service import reporting_service

LOGGER = logging.getLogger(__name__)

DEFAULT_WASTE_CATEGORIES = [
    {
        "code": "overflowing_bin",
        "label": "Overflowing Bin",
        "description": "Public waste bin overflowing onto street or footpath",
        "module": "waste",
    },
    {
        "code": "illegal_dumping",
        "label": "Illegal Dumping",
        "description": "Waste dumped in unauthorized location",
        "module": "waste",
    },
    {
        "code": "construction_debris",
        "label": "Construction Debris",
        "description": "Building materials or rubble left on road/footpath",
        "module": "waste",
    },
    {
        "code": "garbage_burning",
        "label": "Garbage Burning",
        "description": "Open burning of waste",
        "module": "waste",
    },
    {
        "code": "dead_animal",
        "label": "Dead Animal",
        "description": "Animal carcass on road or public area",
        "module": "waste",
    },
]

# Allowed codes for the optional Nugen classifier (kept in sync with the seeds).
WASTE_CATEGORY_CODES = tuple(
    category["code"] for category in DEFAULT_WASTE_CATEGORIES
)


class WasteReportingService:
    async def get_categories(self, db: AsyncSession) -> List[Dict[str, Any]]:
        try:
            result = await db.execute(
                text(
                    """
                    SELECT code, label, description, module
                    FROM report_categories
                    WHERE module = 'waste'
                    ORDER BY id ASC
                    """
                )
            )
            rows = result.fetchall()
            if rows:
                return [dict(row._mapping) for row in rows]
        except Exception as exc:
            LOGGER.warning("Could not fetch waste categories from DB table: %s", exc)

        return DEFAULT_WASTE_CATEGORIES

    async def validate_category(self, category: str, db: AsyncSession) -> bool:
        categories = await self.get_categories(db)
        valid_codes = {c["code"].lower() for c in categories}
        valid_labels = {c["label"].lower() for c in categories}
        cat_lower = category.lower()
        return (cat_lower in valid_codes) or (cat_lower in valid_labels)

    async def create_report(
        self,
        report: WasteReportCreate,
        user_hash: str,
        db: AsyncSession,
    ) -> Dict[str, Any]:
        is_valid = await self.validate_category(report.category, db)
        if not is_valid:
            raise HTTPException(
                status_code=400,
                detail=f"Invalid waste category: '{report.category}'.",
            )

        report_with_hash = type(
            "WasteReportWithHash",
            (),
            {
                "user_hash": user_hash,
                "category": report.category,
                "description": report.description,
                "lat": report.lat,
                "lon": report.lon,
                "severity": report.severity,
                "report_type": "waste",
            },
        )()

        created = await reporting_service.create_report(
            report_with_hash,
            db,
            report_type="waste",
            severity=report.severity,
        )
        created["report_type"] = "waste"
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
            report_type="waste",
        )


waste_reporting_service = WasteReportingService()
