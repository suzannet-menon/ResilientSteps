# ResilientSteps — Current-State Baseline

> **Purpose**: This document records the exact state of the ResilientSteps repository as it exists
> today. Every file path, table name, column, endpoint, and env var listed here has been
> verified against the source code. Any agent or developer working on the ResilientSteps
> codebase **must read this document first** to avoid inventing phantom entities or contradicting
> existing systems.
>
> Last verified: 2026-08-07

---

## 1. Repository Structure

```
ResilientSteps/
├── ARCHITECTURE.md                    High-level system description
├── README.md                          Full project documentation (578 lines)
├── RULES.md                           Agent constraint rules
├── LICENSE                            MIT license
├── deploymentsteps.txt                Windows deployment guide
├── instruc.txt                        Short instruction note
├── linuxinstructions.md               Linux setup guide
│
├── backend/                           FastAPI server (Python 3.11)
│   ├── app/
│   │   ├── main.py                    FastAPI entrypoint + lifespan + middleware
│   │   ├── routers/
│   │   │   ├── routing.py             Route + safety-zone endpoints (4 routes)
│   │   │   ├── reports.py             Incident + emergency alert endpoints (3 routes)
│   │   │   └── admin.py               Operator moderation endpoints (3 routes)
│   │   ├── services/
│   │   │   ├── routing_service.py     Valhalla HTTP client
│   │   │   ├── risk_engine.py         Route safety scoring against cached data
│   │   │   ├── safety_dataset_cache.py STRtree in-memory spatial cache (595 lines)
│   │   │   ├── safety_zone_service.py  GeoJSON zone serving via cache
│   │   │   ├── reporting_service.py    Report + emergency alert persistence (306 lines)
│   │   │   ├── auth_middleware.py      Supabase JWT verification (ES256/HS256)
│   │   │   └── rate_limiter.py         In-process token-bucket rate limiter
│   │   ├── schemas/
│   │   │   └── reports.py             Pydantic models for reports + alerts
│   │   └── db/
│   │       ├── __init__.py
│   │       ├── session.py             SQLAlchemy async engine + session factory
│   │       └── supabase_client.py     Supabase client init
│   ├── alembic/
│   │   ├── env.py                     Async Alembic environment
│   │   ├── script.py.mako             Migration template
│   │   └── versions/
│   │       ├── 0001_initial_schema.py  road_segments, safety_zones, incident_reports
│   │       └── 0002_emergency_alerts_table.py  emergency_alerts
│   ├── tests/
│   │   ├── test_api_endpoints.py
│   │   ├── test_auth_middleware.py
│   │   ├── test_emergency_phase7.py
│   │   ├── test_reporting_service.py
│   │   ├── test_routing_integrity.py
│   │   ├── test_routing_phase3.py
│   │   ├── test_routing_phase4.py
│   │   └── test_routing_phase8.py
│   ├── alembic.ini
│   ├── docker-compose.yml             Valhalla container only
│   ├── requirements.txt               19 pinned dependencies
│   ├── main.py                        One-liner: imports app
│   ├── .env.example                   Environment template (41 lines)
│   └── .env                           Real credentials (gitignored)
│
├── logic/                             Spatial data pipeline (standalone Python)
│   ├── generate_safety_map.py         OSMnx ingest + H3 zone generation (311 lines)
│   ├── safety_feature_engine.py       Segment-level scoring engine (786 lines)
│   ├── generate_street_graph.py       Street graph utilities
│   ├── generate_incidents.py          Incident generation utilities
│   ├── datagen.py                     Data generation utilities
│   ├── punegraph.py                   Pune graph loader
│   ├── api.py                         Logic API wrapper
│   ├── requirements.txt               Logic-specific dependencies
│   └── outputs/                       Cached OSMnx graph (pune_walk.graphml)
│
├── mobile/                            Flutter 3.x app
│   ├── lib/
│   │   ├── main.dart                  App entrypoint + Supabase init
│   │   ├── config/
│   │   │   └── app_config.dart        Compile-time --dart-define constants
│   │   ├── screens/
│   │   │   ├── home_screen.dart       Main map screen (17,363 bytes)
│   │   │   ├── destination_search_screen.dart
│   │   │   ├── emergency_sos_screen.dart
│   │   │   ├── login_screen.dart
│   │   │   ├── signup_screen.dart
│   │   │   ├── forgot_password_screen.dart
│   │   │   ├── splash_screen.dart
│   │   │   ├── report_incident_screen.dart
│   │   │   ├── saved_places_screen.dart
│   │   │   ├── settings_profile_screen.dart
│   │   │   └── trusted_contacts_screen.dart
│   │   ├── controllers/
│   │   │   └── navigation_controller.dart  Navigation state machine (22,730 bytes)
│   │   ├── widgets/
│   │   │   ├── walksafe_map_view.dart
│   │   │   ├── navigation_card.dart    Bottom nav card (37,372 bytes)
│   │   │   ├── map_layers_builder.dart  Route + marker rendering
│   │   │   ├── safety_zone_overlay.dart Zone polygon overlay
│   │   │   ├── incident_modal.dart     Report incident UI (21,711 bytes)
│   │   │   ├── route_info_card.dart
│   │   │   ├── route_summary_panel.dart
│   │   │   ├── safety_legend_card.dart
│   │   │   ├── saved_place_chips.dart
│   │   │   ├── auth_gate.dart
│   │   │   └── gradient_button.dart
│   │   ├── services/
│   │   │   ├── routing_service.dart
│   │   │   ├── navigation_math.dart
│   │   │   ├── safety_heatmap_service.dart
│   │   │   ├── reporting_api_service.dart
│   │   │   ├── sos_service.dart        (17,428 bytes)
│   │   │   ├── trusted_contacts_service.dart
│   │   │   ├── auth_service.dart
│   │   │   ├── location_service.dart
│   │   │   ├── place_search_service.dart
│   │   │   ├── saved_places_service.dart
│   │   │   ├── logic_safety_api_service.dart
│   │   │   ├── incident_storage_service.dart
│   │   │   ├── device_sms_service.dart
│   │   │   └── api_utils.dart
│   │   ├── models/
│   │   │   ├── incident_report.dart
│   │   │   ├── logic_safety_score.dart
│   │   │   ├── place_suggestion.dart
│   │   │   ├── route_segment_safety.dart
│   │   │   ├── safety_zone.dart
│   │   │   └── scored_route.dart
│   │   ├── domain/
│   │   │   ├── entities/               (empty)
│   │   │   └── repositories/           (empty)
│   │   ├── data/
│   │   │   ├── datasources/            (empty)
│   │   │   └── repositories/           (empty)
│   │   └── core/                       (empty)
│   ├── pubspec.yaml                   Flutter dependencies
│   ├── .env.example
│   ├── .env.local                     Local env overrides
│   ├── build_apk.ps1                  PowerShell build script
│   ├── run_mobile.ps1                 PowerShell run script
│   └── android/, ios/, web/, ...      Platform directories (DO NOT MODIFY)
│
├── commandsteps/                      Windows batch deployment scripts
│   ├── step_1_check_flutter_and_adb.bat
│   ├── step_2_get_flutter_dependencies.bat
│   ├── step_3_verify_android_device_over_usb.bat
│   ├── step_4_analyze_and_test_flutter_app.bat
│   ├── step_5_build_android_release_apk.bat
│   ├── step_6_install_release_apk_on_connected_android.bat
│   ├── step_7_launch_walksafe_on_android.bat
│   ├── step_8_run_flutter_app_in_chrome_release.bat
│   └── step_9_build_web_release_bundle.bat
│
├── cache/                             Local cache directory
│
└── docs/                              Migration planning documents
    ├── resilientsteps_plan.xml             ResilientSteps vision + modules (XML)
    ├── ResilientSteps_ADR_System_Spec.md   Architecture decisions
    └── ResilientSteps_Engineering_Handbook_Volume_I.md  Product specification
```

---

## 2. Database Schema (Supabase PostgreSQL + PostGIS)

### Migration Chain

| Revision | File | Description |
|----------|------|-------------|
| `0001` | `0001_initial_schema.py` | Creates `road_segments`, `safety_zones`, `incident_reports` + PostGIS extension + GIST indexes + legacy data migration |
| `0002` | `0002_emergency_alerts_table.py` | Creates `emergency_alerts` with generated GEOGRAPHY column |

Run with: `cd backend && alembic upgrade head`

### Table: `road_segments`

| Column | Type | Constraints |
|--------|------|-------------|
| `id` | `BIGSERIAL` | PRIMARY KEY |
| `osm_way_id` | `BIGINT` | NOT NULL |
| `geometry` | `GEOMETRY(LINESTRING, 4326)` | NOT NULL |
| `safety_score` | `FLOAT` | NOT NULL, CHECK 0–100 |
| `road_type` | `TEXT` | nullable |
| `lighting` | `BOOLEAN` | DEFAULT FALSE |
| `dataset_version` | `TEXT` | NOT NULL |
| `updated_at` | `TIMESTAMPTZ` | DEFAULT NOW() |

**Indexes**: `idx_road_segments_geom` (GIST on geometry)

### Table: `safety_zones`

| Column | Type | Constraints |
|--------|------|-------------|
| `id` | `BIGSERIAL` | PRIMARY KEY |
| `zone_id` | `TEXT` | NOT NULL, UNIQUE |
| `geometry` | `GEOMETRY(POLYGON, 4326)` | NOT NULL |
| `risk_level` | `TEXT` | NOT NULL, CHECK IN ('safe', 'cautious', 'risky') |
| `risk_score` | `FLOAT` | NOT NULL |
| `dataset_version` | `TEXT` | NOT NULL |
| `created_at` | `TIMESTAMPTZ` | DEFAULT NOW() |

**Indexes**: `idx_safety_zones_geom` (GIST on geometry)

### Table: `incident_reports`

| Column | Type | Constraints |
|--------|------|-------------|
| `id` | `BIGSERIAL` | PRIMARY KEY |
| `user_hash` | `TEXT` | NOT NULL |
| `category` | `TEXT` | NOT NULL |
| `description` | `TEXT` | nullable |
| `location` | `GEOMETRY(POINT, 4326)` | NOT NULL |
| `status` | `TEXT` | NOT NULL, DEFAULT 'pending', CHECK IN ('pending', 'verified', 'rejected') |
| `confidence` | `FLOAT` | DEFAULT 0.5 |
| `submitted_at` | `TIMESTAMPTZ` | DEFAULT NOW() |
| `moderated_at` | `TIMESTAMPTZ` | nullable |
| `moderated_by` | `TEXT` | nullable |

**Indexes**: `idx_incidents_geom` (GIST on location), `idx_incidents_status` (B-tree on status)

### Table: `emergency_alerts`

| Column | Type | Constraints |
|--------|------|-------------|
| `id` | `UUID` | PRIMARY KEY, DEFAULT gen_random_uuid() |
| `user_hash` | `TEXT` | NOT NULL |
| `latitude` | `DOUBLE PRECISION` | NOT NULL |
| `longitude` | `DOUBLE PRECISION` | NOT NULL |
| `location` | `GEOGRAPHY(POINT, 4326)` | GENERATED ALWAYS AS (ST_SetSRID(ST_MakePoint(longitude, latitude), 4326)) STORED |
| `status` | `TEXT` | NOT NULL, DEFAULT 'triggered' |
| `message` | `TEXT` | nullable |
| `contacts_notified` | `INTEGER` | NOT NULL, DEFAULT 0 |
| `created_at` | `TIMESTAMPTZ` | NOT NULL, DEFAULT NOW() |
| `resolved_at` | `TIMESTAMPTZ` | nullable |
| `metadata` | `JSONB` | NOT NULL, DEFAULT '{}' |

**Indexes**: `idx_emergency_alerts_location` (GIST), `idx_emergency_alerts_created_at` (DESC)

### Tables That Do NOT Exist (mentioned in docs but not in code)

- `User` — auth is handled entirely by Supabase; user identity is a JWT `sub` claim
- `Municipality` — no table, no model, no reference in code
- `Moderator` — admin auth is a static `ADMIN_API_KEY` env var, not a table
- `HeatmapSnapshot` — zones are stored in `safety_zones` with `dataset_version` for snapshotting
- `Image` — media upload is listed as "planned" in README; no table or storage integration exists

---

## 3. API Surface

### FastAPI Application

- **Title**: "ResilientSteps API"
- **Entrypoint**: `backend/app/main.py` → `app = FastAPI(...)`
- **Run**: `python -m uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload`
- **Lifespan**: On startup, warms the safety dataset cache (loads all `road_segments` + `safety_zones` into an in-memory STRtree)
- **Middleware stack** (order matters):
  1. `NgrokHeaderMiddleware` — adds `ngrok-skip-browser-warning: true` to all responses
  2. `GZipMiddleware` — compresses responses ≥1000 bytes
  3. `CORSMiddleware` — allows `localhost:3000`, `localhost:8080`, `127.0.0.1:3000/8080`, and one hardcoded ngrok domain

### Endpoints

#### Health

| Method | Path | Auth | Rate Limit | Description |
|--------|------|------|------------|-------------|
| `GET` | `/` | None | None | Returns `{"message": "ResilientSteps API is running", "status": "online"}` |
| `GET` | `/ready` | None | None | Readiness probe — 200 when cache warm, 503 during startup |

#### Routing (`app/routers/routing.py`)

| Method | Path | Auth | Rate Limit | Description |
|--------|------|------|------------|-------------|
| `GET` | `/route` | `optional_auth` | 60/min | Fetch pedestrian route from Valhalla |
| `POST` | `/route/risk` | `optional_auth` | 60/min | Score a route's safety from coordinates |
| `POST` | `/route/segments/safety` | `optional_auth` | 60/min | Alias for `/route/risk` |
| `GET` | `/route-safe` | `optional_auth` | 60/min | Combined route + safety score in one call |
| `GET` | `/safety-zones` | None | None | GeoJSON FeatureCollection of H3 zones (10-min in-process cache) |

#### Reports (`app/routers/reports.py`)

| Method | Path | Auth | Rate Limit | Description |
|--------|------|------|------------|-------------|
| `POST` | `/reports` | `require_auth` | 5/hr | Submit incident report |
| `GET` | `/reports/recent` | None | None | List recent verified reports (max 200) |
| `POST` | `/reports/emergency` | `require_auth` | 3/10min | Record SOS alert with trusted contacts |

#### Admin Moderation (`app/routers/admin.py`, prefix `/admin`)

| Method | Path | Auth | Rate Limit | Description |
|--------|------|------|------------|-------------|
| `GET` | `/admin/reports` | `X-Admin-Key` header | None | List reports by status (pending/verified/rejected) |
| `POST` | `/admin/reports/{id}/verify` | `X-Admin-Key` header | None | Verify a report (state: pending → verified) |
| `POST` | `/admin/reports/{id}/reject` | `X-Admin-Key` header | None | Reject a report (any → rejected; rejected is terminal) |

### Pydantic Schemas (`app/schemas/reports.py`)

```
ReportCreate:
  user_hash: str (2–128 chars, default "anonymous", overridden by auth)
  lat: float (-90 to 90)
  lon: float (-180 to 180)
  category: str (2–120 chars, alias "incident_type")
  description: str? (max 2000)
  severity: int (1–5, default 3)
  metadata: dict (default {})

ReportResponse:
  id: str
  status: str
  message: str

RecentReport:
  id, lat, lon, incident_type, severity, confidence_score, created_at, status

EmergencyAlertCreate:
  user_hash: str (2–128 chars)
  lat, lon: float
  message: str?
  trusted_contacts: list[str | TrustedContactPayload] (max 10)
  contacts_notified: int (default 0)
  metadata: dict

TrustedContactPayload:
  name: str (1–120 chars)
  phone: str (1–32 chars)

EmergencyAlertResponse:
  id, status, created_at?, message, contacts_notified, trusted_contacts
```

---

## 4. Authentication System

### Backend (`app/services/auth_middleware.py`)

Two FastAPI dependencies:
- **`require_auth(request)`** — extracts Bearer JWT from `Authorization` header, decodes it, returns `sub` claim as `user_id`. Raises 401 if missing/invalid/expired.
- **`optional_auth(request)`** — same extraction, but returns `None` instead of raising 401.

JWT verification supports two algorithms:
- **ES256** — uses JWKS from `SUPABASE_JWKS` env var (static JSON) or fetched dynamically from `{SUPABASE_URL}/auth/v1/.well-known/jwks.json` (cached 1 hour).
- **HS256** — uses `SUPABASE_JWT_SECRET` env var for symmetric verification.

Admin endpoints use a separate mechanism: constant-time comparison of `X-Admin-Key` header against `ADMIN_API_KEY` env var (via `hmac.compare_digest`).

### Mobile (`mobile/lib/services/auth_service.dart`)

Uses `supabase_flutter` package. Supabase URL and anon key are injected via `--dart-define` at compile time.

---

## 5. Safety Scoring — Two Systems

### System A: Offline Ingest (`logic/generate_safety_map.py`)

Runs standalone. Downloads Pune's walkable street graph from OSM via OSMnx, scores every edge, and writes results to `road_segments` + `safety_zones` tables.

**Scoring formula** (per street segment):

```
base  = ROAD_TYPE_SCORES[highway_tag]     # footway=90, residential=70, primary=30, etc.
+       10 if lit=yes
+        5 if sidewalk present
−        3 per 10 km/h above 30
score = clamp(base, 0, 100)
```

**Road type base scores** (from `generate_safety_map.py` lines 56–70):

| Tag | Score |
|-----|-------|
| footway / pedestrian | 90 |
| living_street | 80 |
| path | 75 |
| cycleway | 72 |
| residential | 70 |
| service | 60 |
| unclassified | 55 |
| tertiary | 50 |
| secondary | 40 |
| primary | 30 |
| trunk | 20 |
| motorway | 5 |

**Zone generation**: Groups road segment centroids into H3 resolution-9 hexagons (~150m), averages safety scores per cell, classifies as `safe` (≥70), `cautious` (40–69), `risky` (<40). Stores as `POLYGON(...)` in `safety_zones` table with `ON CONFLICT (zone_id) DO UPDATE`.

**Geographic scope**: Pune, Maharashtra, India. Cached graph at `logic/outputs/pune_walk.graphml`.

### System B: Runtime Feature Engine (`logic/safety_feature_engine.py`)

A 786-line class (`SafetyFeatureEngine`) that computes segment-level safety scores from dynamic incident data. Used for runtime heatmap enrichment and the logic API.

**Scoring formula** (per segment):

```
incident_risk   = min(1.0, nearby_incident_count / 5.0)
lighting_risk   = 1.0 − (lighting_score / 100.0)       # estimated from road type
crowd_risk      = 1.0 − (crowd_density / 100.0)        # road type + intersections
time_risk       = 1.0 − time_of_day_factor              # IST-aware; 1.0 daytime, 0.3 late night

total_risk = (0.45 × incident_risk) + (0.25 × lighting_risk) + (0.20 × crowd_risk) + (0.10 × time_risk)
base_safety_score = (1.0 − total_risk) × 100

final_score = base_safety_score − incident_heat_penalty
```

**Incident heat penalty**: Builds spatial clusters of nearby incidents (120m radius), computes distance-decayed influence (140m + dynamic expansion), multiplied by `incident_heat_penalty_multiplier` (8.0), capped at `max_incident_heat_penalty` (18.0).

### System C: Runtime Route Scoring (`app/services/risk_engine.py`)

The backend's `score_route()` function. Uses the **cached road_segments** (System A data) loaded into an STRtree by `safety_dataset_cache.py`. For each route waypoint pair:

1. Find nearest road segment within 20m of the midpoint.
2. Read its `safety_score` from the cache.
3. Query `incident_reports` for verified incidents near matched segments.
4. Apply dynamic incident penalties: `penalty = min(25, incident_weight × 12)` where weight uses time-decay (7d=1.0, 30d=0.8, 90d=0.55, else=0.3) and category weights (Stalking=1.0, Harassment=0.9, etc.).
5. Final score = `base_safety_score − incident_penalty`, clamped to 0.

**Key constants** (from `risk_engine.py`):
- `ROAD_MATCH_DISTANCE_METERS = 20.0`
- `INCIDENT_PENALTY_SCALE = 12.0`
- `MAX_INCIDENT_PENALTY = 25.0`

---

## 6. Spatial Data Cache (`app/services/safety_dataset_cache.py`)

The backbone of backend performance. A singleton `SafetyDatasetCache` that:

1. Fetches the latest `dataset_version` from `road_segments` and `safety_zones`.
2. Loads all rows into memory as Shapely geometries.
3. Builds two `STRtree` spatial indexes (one for roads, one for zones).
4. Caches the snapshot; re-checks version every `SAFETY_DATASET_REFRESH_SECONDS` (default: 60s, configurable via env var).
5. Warmed at app startup in the `lifespan` handler.

**Key dataclasses**:
- `CachedRoadSegment(segment_id, safety_score, road_type, lighting, geometry)`
- `CachedSafetyZone(zone_id, risk_level, risk_score, dataset_version, geometry)`
- `SafetyDatasetSnapshot` — holds both lists + STRtrees + matching logic

---

## 7. Rate Limiting (`app/services/rate_limiter.py`)

In-process token-bucket algorithm keyed by the authenticated user ID (`request.state.user_id`, set by the auth dependencies), falling back to client IP for anonymous requests. Identity keying keeps clients separate when they share one address (NAT, a demo audience on one wifi, a tunnel).

| Limiter | Max Requests | Window | Used By |
|---------|-------------|--------|---------|
| `report_rate_limiter` | 5 | 1 hour | `POST /reports` |
| `route_rate_limiter` | 60 | 1 minute | `GET /route`, `POST /route/risk`, `GET /route-safe` |
| `emergency_rate_limiter` | 3 | 10 minutes | `POST /reports/emergency` |
| `nearby_rate_limiter` | 20 | 1 minute | `GET /nearby-places` (fans out to Overpass / Nominatim) |

**Proxy awareness**: `TRUSTED_PROXY_DEPTH` env var (default 0) is the number of proxies you control in front of the API. When >0 and the `X-Forwarded-For` chain is at least that long, the entry appended by the outermost trusted proxy (`len - depth`) is used; entries left of it are caller-supplied and ignored. When the chain is shorter than the configured depth the header is not trusted. With the default of 0, a loopback peer (ngrok, cloudflared, a proxy on the same host) still yields the address the tunnel appended last; any other peer uses `request.client.host` directly.

**Not shared across instances**: Single-process only. README note: "For multi-instance deployment, replace with Redis."

---

## 8. External Service Dependencies

| Service | Purpose | Config |
|---------|---------|--------|
| **Valhalla** | Pedestrian routing engine | Self-hosted Docker container; `VALHALLA_BASE_URL` env var (default `http://localhost:8002`); image `ghcr.io/gis-ops/docker-valhalla/valhalla:latest`; downloads `western-zone-latest.osm.pbf` on first run |
| **Supabase** | PostgreSQL database + auth + (future) storage | `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_KEY`, `SUPABASE_JWT_SECRET` env vars; PostGIS extension required |
| **Maptiler** | Map tile rendering in Flutter | `MAPTILER_API_KEY` via `--dart-define`; streets-v2 style |
| **Photon** | Geocoding (place search) | `PHOTON_BASE_URL` env var (default `https://photon.komoot.io`); used in mobile `place_search_service.dart` |
| **ngrok** | HTTPS tunnel for demo APK distribution | Hardcoded domain in CORS config; static domain tunnel |
| **Sentry** | Error monitoring (optional) | `SENTRY_DSN` env var |

---

## 9. Environment Variables — Complete List

### Backend (`backend/.env`)

| Variable | Required | Purpose |
|----------|----------|---------|
| `SUPABASE_URL` | Yes | Supabase project URL |
| `SUPABASE_ANON_KEY` | Yes | Supabase anonymous key |
| `SUPABASE_SERVICE_KEY` | Yes | Supabase service role key |
| `SUPABASE_JWT_SECRET` | For HS256 | JWT symmetric secret |
| `SUPABASE_JWKS` | For ES256 | JWKS JSON string (alternative to fetching dynamically) |
| `DATABASE_URL` | Yes | PostgreSQL connection string (asyncpg) |
| `VALHALLA_BASE_URL` | No | Default: `http://localhost:8002` |
| `PHOTON_BASE_URL` | No | Default: `https://photon.komoot.io` |
| `MAPTILER_API_KEY` | No | Only in `.env.example`; mobile uses `--dart-define` instead |
| `ADMIN_API_KEY` | Yes | Admin moderation key; **app crashes on startup if missing** |
| `SENTRY_DSN` | No | Optional error tracking |
| `SAFETY_DATASET_REFRESH_SECONDS` | No | Default: 60; cache version-check interval |
| `TRUSTED_PROXY_DEPTH` | No | Default: 0; reverse proxy depth for rate limiter |

### Mobile (`--dart-define` at compile time)

| Variable | Purpose |
|----------|---------|
| `API_BASE_URL` | Backend URL (e.g., `http://127.0.0.1:8000` or ngrok domain) |
| `MAPTILER_API_KEY` | Maptiler tile key |
| `SUPABASE_URL` | Supabase project URL |
| `SUPABASE_ANON_KEY` | Supabase anonymous key |

---

## 10. Docker Compose (`backend/docker-compose.yml`)

Single service: Valhalla only. The FastAPI backend is **not containerized**.

```yaml
services:
  valhalla:
    image: ghcr.io/gis-ops/docker-valhalla/valhalla:latest
    ports:
      - "8002:8002"
    volumes:
      - ./valhalla_tiles:/custom_files
    environment:
      - tile_urls=https://download.geofabrik.de/asia/india/western-zone-latest.osm.pbf
      - build_elevation=False
      - build_admins=True
      - build_time_zones=True
      - force_rebuild=False
    restart: unless-stopped
```

**Note**: First run downloads ~500MB OSM extract and builds tiles (10–20 minutes). Tiles persist in `backend/valhalla_tiles/`.

---

## 11. Test Inventory

### Backend (`backend/tests/`)

| Test File | Focus |
|-----------|-------|
| `test_api_endpoints.py` | Integration tests for all API endpoints |
| `test_auth_middleware.py` | JWT parsing, ES256/HS256, edge cases |
| `test_emergency_phase7.py` | Emergency alert creation and response |
| `test_reporting_service.py` | Report CRUD, normalization, aggregation |
| `test_routing_integrity.py` | Route scoring, cache matching, incident penalties |
| `test_routing_phase3.py` | Route fetching from Valhalla |
| `test_routing_phase4.py` | Safety zone serving |
| `test_routing_phase8.py` | Combined route+risk endpoint |

Run: `cd backend && python -m pytest tests/ -v`

### Mobile

Run: `cd mobile && flutter analyze lib/ && flutter test test/widget_test.dart`

---

## 12. Incident Report Categories (Currently in Use)

The `category` field on `incident_reports` is a free-text `TEXT` column (2–120 chars). The system recognizes these categories via scoring weights:

| Category | Scoring Weight (in risk_engine.py) | Scoring Weight (in safety_feature_engine.py) |
|----------|-----------------------------------|---------------------------------------------|
| Stalking | 1.0 | 1.0 |
| Harassment | 0.9 | 0.9 |
| Suspicious Activity | 0.8 | 0.8 |
| Unsafe infrastructure | 0.7 | 0.7 |
| Poor lighting | 0.6 | 0.6 |
| Other (any string) | 0.65 | 0.65 |

**Note**: The mobile app's `incident_modal.dart` (21,711 bytes) renders predefined category buttons. No server-side validation constrains the category to a fixed enum — any string is accepted.

---

## 13. Geographic Constraints

- **City**: Pune, Maharashtra, India
- **Center**: 18.5204°N, 73.8567°E
- **ARCHITECTURE.md states radius**: 2,500m from center
- **Actual graph scope**: `ox.graph_from_place("Pune, Maharashtra, India", network_type="walk")` — downloads the full administrative boundary
- **Valhalla tile set**: `western-zone-latest.osm.pbf` — covers all of western India
- **H3 resolution**: 9 (≈150m per hexagon)

---

## 14. Report Lifecycle

```
Submitted → pending → [admin] → verified → affects safety scores
                    → [admin] → rejected → no effect (terminal state)
```

- Reports enter as `pending` with `confidence=0.5`.
- Only `verified` reports appear in `GET /reports/recent`.
- Only `verified` reports contribute to dynamic incident penalties in route scoring.
- Rejected reports are terminal — cannot transition to verified (enforced in `admin.py`).
- `moderated_at` timestamp is set on verify/reject; `moderated_by` column exists but is never populated.

---

## 15. What Does NOT Exist Yet

These are mentioned in the vision docs or README roadmap but have **zero implementation**:

| Feature | Status |
|---------|--------|
| Media/image upload for reports | Planned; button hidden in v1 |
| SMS/push fan-out for SOS alerts | Mocked; logged as "no SMS gateway connected" |
| Infrastructure reporting (potholes, streetlights) | Not implemented; `category` is free-text |
| Waste management reporting | Not implemented |
| Authority/civic dashboard | Not implemented |
| Scheduled workers / cron jobs | Not implemented; all computation is on-demand or manual |
| Config YAML files (city.yaml, scoring.yaml, etc.) | Do not exist; config is env vars |
| Multi-city support | Hardcoded to Pune |
| Deployment profiles (local/demo/aws/production) | Not implemented; single deployment mode |
| Demo data seeder | Not implemented |
| User management / roles table | Not implemented; auth is Supabase JWT |
| SLA tracking | Not implemented |
| Predictive maintenance | Not implemented |
| Time-of-day scoring in offline ingest | Only in runtime feature engine, not in `generate_safety_map.py` |
| Open civic API | Not implemented |

---

## 16. Key Python Dependencies (`backend/requirements.txt`)

| Package | Version | Purpose |
|---------|---------|---------|
| fastapi | 0.111.0 | Web framework |
| uvicorn[standard] | 0.30.1 | ASGI server |
| alembic | 1.13.1 | Database migrations |
| asyncpg | 0.31.0 | Async PostgreSQL driver |
| sqlalchemy[asyncio] | 2.0.48 | ORM + async engine |
| geoalchemy2 | 0.15.1 | PostGIS support for SQLAlchemy |
| shapely | 2.1.2 | Geometry operations + STRtree |
| h3 | 4.4.2 | Hexagonal spatial indexing |
| httpx | 0.27.0 | Async HTTP client (Valhalla calls) |
| polyline | 2.0.1 | Polyline encoding/decoding |
| pydantic | 2.12.5 | Data validation |
| PyJWT | 2.8.0 | JWT verification |
| cryptography | 42.0.5 | Crypto primitives for JWT |
| pytest | 8.2.0 | Testing |
| pytest-asyncio | 0.23.6 | Async test support |
| python-dotenv | 1.0.1 | .env file loading |
| sentry-sdk[fastapi] | 2.3.0 | Error monitoring |
| supabase | 2.15.3 | Supabase client |

### Key Flutter Dependencies (`mobile/pubspec.yaml`)

| Package | Version | Purpose |
|---------|---------|---------|
| flutter_map | ^8.2.2 | Map rendering |
| latlong2 | ^0.9.1 | Coordinate types |
| geolocator | ^14.0.2 | GPS location |
| supabase_flutter | ^2.5.6 | Auth + client |
| flutter_compass | ^0.8.1 | Heading for navigation |
| hive_flutter | ^1.1.0 | Local storage |
| sms_sender | ^1.0.6 | Device SMS for SOS |
| shared_preferences | ^2.5.4 | Persistent settings |
| polyline_codec | ^0.1.6 | Route polyline decoding |
| http | ^1.6.0 | HTTP client |
