# ResilientSteps — Documentation Index

## Product scope

ResilientSteps is a pedestrian navigation system that routes citizens through
streets scored for **safety** and **thermal comfort**. Comfort is derived from
two independent signals:

- **Shade** — tree-canopy coverage, precomputed per road segment from
  OpenStreetMap and stored in PostGIS.
- **Heat** — current temperature, heat index, relative humidity, and UV index,
  retrieved from Open-Meteo at request time.

The active implementation scope is:

1. **Phase 7 — Heat & Shade Data Layer**
2. **Phase 8 — Comfort-Aware Route Finalisation & Live Observations**

Phases 1–6 are already present in the codebase. Phase 1 (module structure) and
Phase 2 (reporting) are reference material that Phase 8 builds on. Phases 3–6
are outside the current scope.

## Document index

| Document | Status | Contents |
|----------|--------|----------|
| `step_7_heat_and_shade_data.md` | Current | Open-Meteo heat service, OSM shade seed, migration `0006`, cache wiring |
| `step_8_comfort_route_and_observations.md` | Current | Comfort composition, `prefer` parameter, observation corrections, mobile fields |
| `BASELINE.md` | Current reference | Verified tables, endpoints, cache behaviour, and test inventory |
| `step_1` … `step_6` | Historical | Origin of the module, reporting, config, and deployment structure |
| `ResilientSteps_Engineering_Handbook_Volume_I.md` | Legacy | Original platform vision |
| `ResilientSteps_ADR_System_Spec.md` | Legacy | Original architecture decisions |
| `resilientsteps_plan.xml` | Legacy | Original module plan |

Legacy documents carry a superseded banner. Where a legacy document conflicts
with the current code or with Phases 7–8, the code and Phases 7–8 take
precedence.

## Phase status

| Phase | Title | Status | Relevance |
|-------|-------|--------|-----------|
| 1 | Walking-module structure | Implemented | Structure reference |
| 2 | Reporting (`report_type`, categories) | Implemented | Reused by Phase 8 observations |
| 3 | Waste reporting | Implemented | Out of scope |
| 4 | Authority dashboard | Implemented | Out of scope |
| 5 | Deployment and configuration | Implemented | `config/` layout used by Phase 7 |
| 6 | Multi-city support | Implemented | Out of scope |
| 7 | Heat & Shade Data Layer | Implemented (2026-10-18 dataset `20261018-064339`) | `step_7_heat_and_shade_data.md` |
| 8 | Comfort Route & Live Observations | Implemented | `step_8_comfort_route_and_observations.md`, `/route-safe` |
| 9 | Score-preferring route alternatives | Implemented (2026-11-01) | Safest-alternate selection: candidates fetched + scored + silent pick, `routing.py` `_select_route` |

Indicative schedule for a 15-day window: Phase 7 in 5–6 days, Phase 8 in 5–6
days, with a 3-day buffer. The data layer (Phase 7) has priority; the
alternative-route work (Phase 9) is the first item to defer. (Historical
planning note — Phases 7–9 shipped as logged above.)

## Scope boundary

The observation interface required for reporting conditions while walking is
delivered by **Phase 8**, using the Phase 2 reporting machinery
(`incident_reports`, `report_type`, `report_categories`). No separate
infrastructure or waste reporting UI is required.

Phase 8 reports a comfort score for the single route returned by Valhalla.
Presenting two distinct route candidates (safety-first versus shade-first) is
Phase 9 and is out of scope for the initial delivery.

## Engineering conventions

1. **Additive changes only.** New signals are added as new response keys. The
   existing `safety_score` value and all existing keys must remain unchanged.
2. **I/O isolation.** Database access, Valhalla, and Open-Meteo are injected into
   services, not called from pure logic. Unit tests run without a database or
   network.
3. **Characterisation before modification.** Freeze the current `/route-safe`
   response in a test before refactoring the scorer.
4. **Layer ownership.** Data flows through a fixed path:
   `logic/` ingest → PostGIS → `SafetyDatasetCache` → service → router →
   Flutter model → controller → screen. Changes belong in the layer that owns
   the data.
5. **Versioned schema.** Every database change is an Alembic migration with a
   working `downgrade()`.

## External services

| Service | Purpose | Credentials |
|---------|---------|-------------|
| Valhalla | Pedestrian routing | Self-hosted; `VALHALLA_BASE_URL` |
| Open-Meteo | Heat and UV data | None — keyless |
| Supabase / PostGIS | Road, zone, and report storage | `DATABASE_URL`, Supabase keys |
| Maptiler | Map tiles (mobile) | `MAPTILER_API_KEY` via `--dart-define` |

OpenWeather is not used. Open-Meteo provides `apparent_temperature` (heat
index), `relative_humidity_2m`, and `uv_index` without an API key.

## Commands

```bash
# Backend tests (no database or network required)
cd backend && python -m pytest tests/ -v

# Mobile analysis and tests
cd mobile && flutter analyze lib/ && flutter test

# Backend development server
cd backend && python -m uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload
```

See the repository `README.md` for local setup, Valhalla, and APK packaging.
