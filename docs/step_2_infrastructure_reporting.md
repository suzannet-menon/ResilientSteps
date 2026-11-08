# Phase 2 — Infrastructure Reporting

## Goal

Add a new ResilientSteps module that lets citizens report infrastructure issues —
potholes, broken streetlights, damaged footpaths, fallen trees, broken traffic
signals, water leaks, and waterlogging. These reports flow through the same
moderation pipeline as ResilientSteps incident reports but are stored with structured
categories, severity levels, and (eventually) photo attachments.

## Prerequisites

- **Phase 1 complete**: The backend has `app/modules/` and `app/core/` structure.
- All existing ResilientSteps tests pass.
- The BASELINE.md document has been read.

---

## Current State (as-is)

### What exists for reporting

- `incident_reports` table: stores safety-related reports (Stalking, Harassment,
  Poor lighting, etc.). The `category` column is free-text (2–120 chars).
- `POST /reports` endpoint: accepts any category string.
- `GET /admin/reports`: lists/filters by status (pending/verified/rejected).
- Mobile `incident_modal.dart`: renders predefined safety category buttons.
- Report lifecycle: `pending → verified/rejected` via admin endpoints.

### What does NOT exist

- No separate table for infrastructure vs. safety reports.
- No `report_type` or `module` discriminator column.
- No infrastructure-specific categories in the database or API.
- No severity impact on heatmap computation.
- No photo upload support.

---

## Changes Required

### 1. Database — New Alembic Migration (`0003`)

**File**: `backend/alembic/versions/0003_infrastructure_reports.py`

Add a `report_type` column to `incident_reports` and create an infrastructure
categories reference table:

```sql
-- Add report_type discriminator to existing table
ALTER TABLE incident_reports
  ADD COLUMN IF NOT EXISTS report_type TEXT NOT NULL DEFAULT 'safety';

-- Add severity column (already in Pydantic schema but not persisted)
ALTER TABLE incident_reports
  ADD COLUMN IF NOT EXISTS severity INTEGER NOT NULL DEFAULT 3
  CHECK (severity >= 1 AND severity <= 5);

-- Create categories reference table
CREATE TABLE IF NOT EXISTS report_categories (
    id          SERIAL PRIMARY KEY,
    module      TEXT NOT NULL,            -- 'safety', 'infrastructure', 'waste'
    code        TEXT NOT NULL UNIQUE,     -- 'pothole', 'streetlight', etc.
    label       TEXT NOT NULL,            -- 'Pothole'
    description TEXT,
    created_at  TIMESTAMPTZ DEFAULT NOW()
);

-- Seed safety categories (from existing code)
INSERT INTO report_categories (module, code, label) VALUES
  ('safety', 'stalking', 'Stalking'),
  ('safety', 'harassment', 'Harassment'),
  ('safety', 'suspicious_activity', 'Suspicious Activity'),
  ('safety', 'unsafe_infrastructure', 'Unsafe infrastructure'),
  ('safety', 'poor_lighting', 'Poor lighting')
ON CONFLICT (code) DO NOTHING;

-- Seed infrastructure categories (from resilientsteps_plan.xml)
INSERT INTO report_categories (module, code, label) VALUES
  ('infrastructure', 'pothole', 'Pothole'),
  ('infrastructure', 'streetlight', 'Broken Streetlight'),
  ('infrastructure', 'footpath', 'Damaged Footpath'),
  ('infrastructure', 'fallen_tree', 'Fallen Tree'),
  ('infrastructure', 'traffic_signal', 'Broken Traffic Signal'),
  ('infrastructure', 'water_leak', 'Water Leak'),
  ('infrastructure', 'waterlogging', 'Waterlogging / Flooding'),
  ('infrastructure', 'obstruction', 'Road Obstruction')
ON CONFLICT (code) DO NOTHING;

-- Index on report_type for module-scoped queries
CREATE INDEX IF NOT EXISTS idx_incidents_report_type
  ON incident_reports (report_type);
```

**Why extend `incident_reports` rather than create a new table**: The report
lifecycle (pending → verified/rejected), admin moderation UI, and spatial
indexing are identical across modules. A single table with a `report_type`
discriminator is simpler and keeps the moderation workflow unified. Future
modules (waste, etc.) add their categories to `report_categories` and set
`report_type` accordingly.

### 2. Backend — Infrastructure Module

**New directory**: `backend/app/modules/infrastructure/`

```
backend/app/modules/infrastructure/
├── __init__.py            ← exports router
├── routers/
│   ├── __init__.py
│   └── reports.py         ← infrastructure report endpoints
├── services/
│   ├── __init__.py
│   └── infra_reporting_service.py  ← report creation with report_type='infrastructure'
└── schemas/
    ├── __init__.py
    └── reports.py         ← InfraReportCreate schema
```

#### `routers/reports.py`

```python
# Endpoints:
POST /infra/reports          # Submit infrastructure report (require_auth, 5/hr)
GET  /infra/reports/recent   # List recent verified infrastructure reports
GET  /infra/categories       # List infrastructure categories from report_categories table
```

The submit endpoint reuses the existing `create_report()` logic from
`reporting_service.py` but:
- Sets `report_type = 'infrastructure'`
- Validates `category` against `report_categories` where `module = 'infrastructure'`
- Stores the `severity` value (1–5) in the new column

#### `schemas/reports.py`

```python
class InfraReportCreate(BaseModel):
    lat: float = Field(ge=-90, le=90)
    lon: float = Field(ge=-180, le=180)
    category: str = Field(min_length=2, max_length=120)  # validated against DB
    description: str | None = Field(default=None, max_length=2000)
    severity: int = Field(default=3, ge=1, le=5)
    metadata: dict = Field(default_factory=dict)
```

### 3. Backend — Modify Admin Module

Update `app/modules/walksafe/routers/admin.py` (or `app/routers/admin.py` if
Phase 1 used re-export stubs) to:

- Add optional `report_type` query parameter to `GET /admin/reports`:
  ```
  GET /admin/reports?status=pending&report_type=infrastructure
  ```
- Default: returns all report types (backward compatible).
- The verify/reject endpoints need no changes — they work on `incident_reports.id`
  regardless of `report_type`.

**Exact SQL change** in `admin.py` `list_reports()`:

```sql
-- Current (line 83):
WHERE status = :status

-- New:
WHERE status = :status
AND (:report_type IS NULL OR report_type = :report_type)
```

### 4. Backend — Register Module in `main.py`

```python
from app.modules.infrastructure import router as infra_router
app.include_router(infra_router, prefix="/infra", tags=["Infrastructure"])
```

### 5. Backend — Shared Reporting Service Extraction

The `create_report()` method in `reporting_service.py` currently hardcodes no
`report_type`. Modify it to accept an optional `report_type` parameter:

```python
# Current (reporting_service.py line 67):
INSERT INTO incident_reports (user_hash, category, description, location, status, confidence)

# New:
INSERT INTO incident_reports (user_hash, category, description, location, status, confidence, report_type, severity)
VALUES (:user_hash, :category, :description, ST_SetSRID(ST_MakePoint(:lon, :lat), 4326),
        'pending', :confidence, :report_type, :severity)
```

Default `report_type='safety'` preserves backward compatibility for
existing ResilientSteps report submissions.

### 6. Logic Pipeline — Infrastructure Heatmap (Optional in Phase 2)

If infrastructure heatmaps are desired in Phase 2, modify
`logic/generate_safety_map.py` to:

1. Query `incident_reports WHERE report_type = 'infrastructure' AND status = 'verified'`
2. Group by H3 cell (resolution 8 for infrastructure — ~460m, coarser than safety)
3. Write to a new `infrastructure_zones` table (or reuse `safety_zones` with a
   `module` column)

**Recommendation**: Defer infrastructure heatmaps to Phase 4 (dashboard) and
focus Phase 2 on the report submission + moderation flow only.

### 7. Mobile — Infrastructure Reporting Screen

**New files**:

```
mobile/lib/modules/infrastructure/                    ← or keep flat if Phase 1 deferred
├── screens/
│   └── infra_report_screen.dart
├── services/
│   └── infra_reporting_api_service.dart
└── widgets/
    └── infra_category_picker.dart
```

The `infra_report_screen.dart` should:
- Show a grid of infrastructure category buttons (Pothole, Streetlight, etc.)
- Allow severity selection (1–5 scale with icons)
- Capture GPS location
- Submit to `POST /infra/reports`
- Show confirmation

**Navigation**: Add an "Infrastructure" tab or button to `home_screen.dart`
alongside the existing safety report button.

---

## Verification

### Automated Tests

```bash
# New test file:
cd backend
python -m pytest tests/test_infrastructure_reports.py -v

# All existing tests must still pass:
python -m pytest tests/ -v
```

**New test cases** (`tests/test_infrastructure_reports.py`):
- Submit infrastructure report → verify `report_type='infrastructure'` in DB
- Submit with invalid category → 400 or validation error
- List infrastructure reports via admin with `report_type=infrastructure`
- Verify infrastructure report via admin → status changes
- Existing safety reports are unaffected by new column defaults

### Manual Verification

1. `POST /infra/reports` with `category=pothole` → success response
2. `GET /infra/categories` → returns 8 infrastructure categories
3. `GET /admin/reports?status=pending&report_type=infrastructure` → shows only infra reports
4. `GET /admin/reports?status=pending` (no filter) → shows both safety + infra reports
5. `POST /admin/reports/{id}/verify` → works for infra reports
6. Existing `POST /reports` (ResilientSteps) still works with `report_type='safety'` default

### Migration Verification

```bash
cd backend
alembic upgrade head   # applies 0003
alembic downgrade -1   # reverts cleanly
alembic upgrade head   # re-applies cleanly
```

---

## Done Criteria

- [ ] Alembic migration `0003` adds `report_type`, `severity` to `incident_reports` + `report_categories` table
- [ ] `backend/app/modules/infrastructure/` exists with routers, services, schemas
- [ ] `POST /infra/reports` accepts infrastructure reports
- [ ] `GET /infra/categories` returns categories from database
- [ ] `GET /admin/reports` supports optional `report_type` filter
- [ ] All 8 existing test files pass without modification
- [ ] New `test_infrastructure_reports.py` passes
- [ ] Mobile infrastructure screen exists (or is deferred to Phase 4 with dashboard)

---

## Risks and Mitigations

| Risk | Mitigation |
|------|-----------|
| Adding columns to `incident_reports` breaks existing queries | `report_type DEFAULT 'safety'` and `severity DEFAULT 3` ensure backward compat |
| Category validation against DB adds a query to every report submission | Cache categories in memory (they rarely change) |
| Mobile navigation becomes cluttered with new module entries | Use a module switcher or tabbed interface, not individual buttons |
| Infrastructure reports pollute ResilientSteps safety scoring | `risk_engine.py` and `reporting_service.py` already filter by `status='verified'`; add `AND report_type='safety'` to incident penalty queries |
