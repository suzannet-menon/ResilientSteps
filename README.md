<div align="center">

```text
╔═══════════════════════════════════════════════════════════════════╗
║                     R E S I L I E N T S T E P S                    ║
╚═══════════════════════════════════════════════════════════════════╝
```

**The safer, cooler way to walk.**

*Pedestrian safety & comfort navigation for Pune — routes that prioritise your safety and shade over speed.*

---

[![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?style=flat-square&logo=flutter)](https://flutter.dev)
[![FastAPI](https://img.shields.io/badge/FastAPI-0.100+-009688?style=flat-square&logo=fastapi)](https://fastapi.tiangolo.com)
[![PostGIS](https://img.shields.io/badge/PostGIS-enabled-336791?style=flat-square&logo=postgresql)](https://postgis.net)
[![Valhalla](https://img.shields.io/badge/Routing-Valhalla-FF6B35?style=flat-square)](https://valhalla.github.io)
[![Setup Guide](https://img.shields.io/badge/Setup_Guide-SETUP.md-8B5CF6?style=flat-square)](SETUP.md)
[![License](https://img.shields.io/badge/License-MIT-22C55E?style=flat-square)](LICENSE)

</div>

<p align="center">
  <img src="docs/images/navigation-laptop.png" alt="Live navigation in ResilientSteps"
       width="880"/>
  <br/>
  <em>Live navigation — safety-zone overlay, climate metrics on the route card,
  and one-tap SOS.</em>
</p>

---

## What is ResilientSteps?

Most navigation apps optimise for speed. ResilientSteps optimises for **safety, shade, heat and community well-being**.

Instead of asking "how do I get there fastest?" it asks "how do I get there most safely?". Routing pedestrians through well-lit streets, footpaths, and residential roads while avoiding high-speed arterials, poorly-lit stretches, and areas with recent incident reports.

Built for Pune, India. Designed for anyone who has ever felt uncertain walking home.

---

## How it works

```

Your location
      │
      ▼
 ┌─────────────────────────────────────────────────────┐
 │                   ResilientSteps Backend                  │
 │                                                     │
 │  ┌──────────┐    ┌───────────┐    ┌──────────────┐  │
 │  │ Valhalla │───▶│   Risk    │───▶│  Safe Route │  │
 │  │ Routing  │    │  Engine   │    │   Response   │  │
 │  └──────────┘    └───────────┘    └──────────────┘  │
 │        ▲               ▲                            │
 │        │               │                            │
 │  ┌──────────┐    ┌───────────┐                      │
 │  │   OSM    │    │ PostGIS   │                      │
 │  │  Graph   │    │  + H3     │                      │
 │  │ (Pune)   │    │  Zones    │                      │
 │  └──────────┘    └───────────┘                      │
 └─────────────────────────────────────────────────────┘
      │
      ▼
  Flutter app
  with live navigation,
  safety overlays,
  and incident reporting
```

Every street segment in Pune carries a **safety score** (0–100) derived from:

| Signal | How it's used |
|--------|--------------|
| Nearby incident reports | Reports within 75 m of a segment raise its incident risk (saturates at 5) |
| Road type | Drives lighting & crowd heuristics (arterials read busier/well-lit, footpaths/paths quieter — see scoring reference) |
| Nearby intersections | Intersections boost estimated crowd density |
| Time of day (IST) | Late-night segments score lower than daytime ones at ingest time |

In-motion, the route score additionally subtracts a penalty from **verified
community incident reports** near the road segments being walked.

Before you start walking, the app also shows a **comfort score** built from two
climate signals:

| Signal | How it's used |
|--------|--------------|
| Shade score | OSM tree canopy + green areas around each street segment (live data, not predefined) |
| Heat index | Live Open-Meteo "feels-like" temperature, banded Pleasant / Mild / High / Extreme |

Routes minimise total risk across all segments, not just distance.

### Concrete data flow

1. **Routing** — the app sends `GET /route-safe?start_lat=…&end_lat=…`. The
   backend asks self-hosted Valhalla for a pedestrian route, then `score_route`
   matches the route geometry to precomputed `road_segments` (STRtree cache,
   re-warmed automatically when the dataset version changes) and returns
   per-segment safety/shade/heat plus route comfort. The app renders the
   polyline, the zone overlay (from `/safety-zones`, cached offline in
   `shared_preferences`), and the card metrics.
2. **Destination search / geocoding** — the app calls Nominatim directly
   (search + reverse geocode, cached and rate-gated client-side). No backend
   proxy involved.
3. **Incident reporting** — the app `POST /reports` (Supabase JWT) → stored as
   `pending` in `incident_reports` → an operator verifies/rejects via the admin
   API using the `X-Admin-Key` header → verified reports influence future route
   scores (nearest-segment match within 30 m, weighted by confidence/category/status/recency).
   Nothing touches road segments at moderation time.
4. **SOS** — the app records `POST /reports/emergency` (GPS location + trusted
   contacts → `emergency_alerts`) and the **device** sends SMS to trusted
   contacts on its own. If GPS is unavailable the SOS is blocked.
5. **Precomputed vs live** — segment scores, zone hexagons and shade scores are
   precomputed by the `logic/` pipeline into PostGIS; weather heat penalty is
   fetched live per request (cached 15 min, degrades to 0 on failure);
   reports/scores interplay is live at scoring time.

---

## Features

### Safety-first routing
Routes scored segment-by-segment against the weighted safety model — picking routes that avoid high-incident stretches. The safety score for your route is shown before you start walking.

<p align="center">
  <img src="docs/images/source-destination-safety-heat-shade-laptop.png"
       alt="Climate-Smart route card with safety, shade and heat"
       width="780"/>
  <br/>
  <em>The card explains the pick: safety / shade / heat plus
  <q>Why this route?</q> comfort — Climate-Smart vs Fastest, with nearby essentials.</em>
</p>

### Live danger zone overlay
H3 hexagon polygons colour-coded green / amber / red based on aggregated street safety scores. Toggleable. Cached offline.

### Real-time navigation
- Live GPS position tracking with map auto-pan
- Heading-up mode — map rotates to face your direction of travel
- Route consumption — walked sections fade as you progress
- Automatic rerouting when you drift too far off-route (dynamic threshold,
  roughly 40–80 m depending on GPS fix quality, with a 15 s cooldown)
- Arrival detection near the destination

<p align="center">
  <img src="docs/images/navigation-mobile.jpeg" alt="Navigation on a phone — ETA, shade, heat and safety chips"
       width="300"/>
  <br/>
  <em>Same turn-by-turn state on a phone: ETA, live shade / heat / safety
  chips and the one-tap SOS within thumb reach.</em>
</p>

### SOS alert
One-tap emergency alert. Your phone sends SMS messages to your saved trusted
contacts **directly from the device** (no backend needed for delivery), records
your real GPS location and the contact list against the backend
(`POST /reports/emergency`), and blocks the SOS if GPS is unavailable — never
sends a fake location. The backend records the event; it does not deliver
messages.

### Incident reporting
Report poor lighting, suspicious activity, or unsafe infrastructure. Reports enter a moderation queue — they do not affect safety scores until an operator verifies them.

<p align="center">
  <img src="docs/images/incident-report-modal.png" alt="Incident report modal with category and severity chips"
       width="340"/>
  <br/>
  <em>Category + severity chips in the report modal; the backend's Nugen
  classifier enriches the text after submit (never blocks on it).</em>
</p>

### AI-powered incident classification (Nugen)
Optional backend LLM classifier (Nugen) enriches each submitted report with a
canonical category code, severity (1–5) and model confidence. It runs after the
report is persisted — if Nugen is unconfigured or unavailable, the report keeps
its insert-time values (confidence 0.5) and the pipeline never breaks.

To enable it, add two keys to `backend/.env`:

```env
# Key: platform.nugen.in -> dashboard -> API keys
# Model: pick one with inference_ready=true AND alignment_ready=true:
#   meta-llama/Llama-3.2-3B-Instruct (recommended)
# Optional override (default: https://api.nugen.in/api/v3/inference)
# NUGEN_BASE_URL=https://api.nugen.in/api/v3/inference
NUGEN_API_KEY=your-api-key
NUGEN_MODEL=meta-llama/Llama-3.2-3B-Instruct
```

- Set **both** `NUGEN_API_KEY` and `NUGEN_MODEL` for classification to run.
- Classification stays **OFF** until both are set — everything degrades to the
  base confidence of 0.5 without them (offline-safe by design).
- The model must be OpenAI-compatible (Nugen serves SSE/chat-completions) — the
  recommended first pick is `meta-llama/Llama-3.2-3B-Instruct`.
- The mobile app is never involved; this is purely a backend enrichment step.

### Operator moderation
Simple API-based moderation workflow. Verified reports then affect scores
dynamically (see API reference) — segment data itself is not rewritten.

<p align="center">
  <table>
    <tr>
      <td align="center">
        <img src="docs/images/dashboard-city-overview.png"
             alt="Municipal dashboard — city overview map with report pins"
             width="420"/><br/>
        <em><b>City overview</b> — every complaint pin-mapped; click a pin to
        zoom in and verify</em>
      </td>
      <td align="center">
        <img src="docs/images/dashboard-incident-management.png"
             alt="Municipal dashboard — incident management table"
             width="420"/><br/>
        <em><b>Incident management</b> — AI-enriched severity/confidence, exports,
        moderation history</em>
      </td>
    </tr>
  </table>
</p>

### ngrok-controlled demo URL (optional)
`ngrok` exposes the local backend over a permanent HTTPS URL. Point the mobile app
at that URL so the APK works anywhere — not just on your local network. No public
IP, no cloud VPS, and no VPN required. Detailed setup is in
**[Sharing & distribution](SETUP.md#sharing--distribution)** in SETUP.md.

---

## Tech stack

| Layer | Technology |
|-------|-----------|
| Mobile | Flutter 3.x |
| Backend | FastAPI (Python 3.11) |
| Routing engine | Valhalla (self-hosted via Docker) |
| Database | Supabase PostgreSQL + PostGIS |
| Migrations | Alembic |
| Spatial indexing | STRtree in-memory cache (Shapely) |
| Safety zones | H3 hexagons (resolution 9 ≈ 150m cells) |
| Street data | OpenStreetMap via OSMnx |
| Map tiles | Maptiler streets-v2 |
| Geocoding | Nominatim (called directly by the app) |
| Demo tunnel | ngrok (optional, for sharing) |

---

## Repository layout

```

ResilientSteps/
├── docker-compose.yml            Root stack: valhalla + backend services
├── SETUP.md                      Setup / installation guide + pitfall checklist
├── linuxinstructions.md          Linux-specific setup notes
├── LOCAL_SETUP_STATUS.md         Three-terminal runbook + fresh-vs-stale checklist
├── config/                       City config (city.yaml: city name, OSM place)
├── docs/                         Project documentation
├── scripts/                      Miscellaneous helper scripts

├── backend/                      FastAPI server
│   ├── app/
│   │   ├── core/                 Database, auth middleware, rate limiting
│   │   ├── modules/walksafe/
│   │   │   ├── routers/          routing.py (route/scoring), reports.py (SOS),
│   │   │   │                     admin.py (moderation), nearby tile endpoints
│   │   │   ├── services/         Valhalla integration, risk engine, safety
│   │   │   │                     dataset cache (STRtree), weather (Open-Meteo)
│   │   │   └── schemas/
│   │   └── routers/, services/   Legacy import shims (2–4 lines, re-export
│                                 the app/modules/* code for old tests)
│   ├── alembic/                  Versioned database migrations
│   ├── tests/                    Pytest test suite (100 tests)
│   ├── docker-compose.yml        Same stack, paths relative to backend/
│   ├── requirements.txt
│   └── .env.example              ← copy to .env and fill in values
│
├── mobile/                       Flutter app
│   ├── lib/
│   │   ├── screens/home_screen.dart           Main map screen
│   │   ├── controllers/navigation_controller.dart  Navigation state machine
│   │   ├── widgets/               Map wrapper, nav card, route cards,
│   │   │                          zone overlay, incident modal, nearby sheet
│   │   ├── services/              Routing, place search (Nominatim), safety
│   │   │                          heatmap (offline zone cache), SOS (device
│   │   │                          SMS), trusted contacts, reporting APIs
│   │   └── config/app_config.dart Dart-defines bridge
│   ├── config/dart_defines.json   ← GITIGNORED: create locally with all 4 keys
│   └── .env.example
│
└── logic/                        Spatial data pipeline
    ├── generate_safety_map.py    OSMnx ingest + H3 zone generation
    ├── generate_shade_map.py     Tree-canopy shade_score seed (run AFTER safety map)
    ├── generate_street_graph.py  Standalone street graph builder
    ├── generate_incidents.py     Synthetic demo incident generator
    ├── seed_demo_data.py         Demo categories/reports seeding
    └── safety_feature_engine.py  Weighted-risk scoring engine
```

---

## Getting started

All installation, configuration, run-book, dashboard access, APK sharing and
troubleshooting documentation lives in **[SETUP.md](SETUP.md)** — including a
pitfalls section covering the failure modes of every step (Windows port
conflicts, cold-start timing, dart-define staleness, emulator vs device
addresses, ngrok behaviour, and more).

Quick path:

```text
1. backend/.env  (copy from backend/.env.example — REQUIRED before steps 3 & 6)
2. Database     → alembic upgrade head (backend/.venv)
3. Valhalla     → docker compose up -d valhalla        (10–20 min first run)
4. Safety data  → python generate_safety_map.py        (logic/)
5. Shade data   → python generate_shade_map.py         (logic/, after step 4)
6. Backend      → uvicorn app.main:app :8000, wait for /ready {"ready":true}
7. App          → mobile/config/dart_defines.json + flutter run -d chrome
   Dashboard    → http://localhost:8000/dashboard-ui/  (served by the backend)
```

Endpoint/verification basics stay here: see [API reference](#api-reference)
below. The test-verification commands are in
[Running tests in SETUP.md](SETUP.md#running-tests).

---

## API reference

Interactive docs (FastAPI default, enabled): `http://localhost:8000/docs`

### Routing

```

GET /route?start_lat=&start_lon=&end_lat=&end_lon=
```

Returns a pedestrian route from Valhalla with encoded polyline.

```

POST /route/risk
Body: { "coordinates": [[lat, lon], ...] }
```

Scores a route's safety using the cached road segment data and live verified incidents.

```

GET /route-safe?start_lat=&start_lon=&end_lat=&end_lon=&prefer=balanced
```

Combined route fetch + safety scoring in a single call. Each segment includes
`safety_score`, `shade_score`, `heat_penalty`, and `comfort_score`; the top
level adds the route-wide comfort score/level. `prefer` selects the comfort
weighting: `balanced`, `safety`, `shade`, or `heat`.

```

GET /safety-zones?min_lat=&max_lat=&min_lon=&max_lon=
```

Returns GeoJSON FeatureCollection of H3 polygon safety zones within the bounding box.

### Reporting

```

POST /reports
Authorization: Bearer <supabase-jwt>
Body: { "category": "Poor lighting", "lat": 18.52, "lon": 73.85, "description": "..." }
```

Submit an incident report (auth required). Rate limited to 5 requests/hour per
IP. Enters as `pending`.

```

GET /reports/recent?limit=50
```

Most recent reports for the map feed (limit clamped to 200, no auth).

```

POST /reports/emergency
Authorization: Bearer <supabase-jwt>
Body: { "lat": 18.52, "lon": 73.85, "trusted_contacts": [{"name": "...", "phone": "..."}] }
```

Record an SOS alert with real GPS coordinates and trusted contact list.
Rate limited to 3 requests/10 minutes per IP. The backend only **records** the
alert — message delivery to contacts is done by the phone via on-device SMS.

### Admin moderation

All admin endpoints require `X-Admin-Key: your-admin-key` header.

```

GET  /admin/reports?status=pending
POST /admin/reports/{id}/verify
POST /admin/reports/{id}/reject
```

Verification flips the report's status — it does **not** rewrite road-segment
data. Verified reports affect scores dynamically at scoring time: an incident
report influences the nearest road segment within 30 metres of its location
(weighted by confidence, category, status and recency), and shade-relevant
categories ("no shade / heavy sun", "cool shaded spot / water available") add a
shade correction to that segment. Pending and rejected reports have no effect.

**Example moderation workflow:**

```bash
# List pending reports
curl "http://localhost:8000/admin/reports?status=pending" \
  -H "X-Admin-Key: your-admin-key"

# Verify report ID 42
curl -X POST "http://localhost:8000/admin/reports/42/verify" \
  -H "X-Admin-Key: your-admin-key"
```

---

## Safety scoring reference

Scores come from `logic/safety_feature_engine.py` (pipe:line-time base scores)
plus `backend/.../services/risk_engine.py` (route-time adjustments). There is
**no static road-type lookup table** — the score is a weighted-risk blend:

### Base segment score (`safety_feature_engine.py`)

risk = 0.45 × incident-risk + 0.25 × lighting-risk + 0.20 × crowd-risk
+ 0.10 × time-of-day-risk; score = (1 − risk) × 100, clamped to [0, 100].

Each component is estimated per segment:

| Component | Source | Notes |
|-----------|--------|-------|
| Incident risk | OSM incidents within 75 m of the segment (saturates at 5) | Cluster-driven, see below |
| Lighting score | Road-type heuristics (e.g. motorway 90, residential 58, footway 48, path 42 — **higher = better lit** since arterials carry lit stats) | Unknown road types default to 55 |
| Crowd density | Road-type base + 6 per nearby intersection (max +30) | Residential ≈ 50, pedestrian ≈ 72 |
| Time-of-day factor | 1.0 (07:00–18:00 IST), 0.7 (05–06 / 19–20), 0.5 (21–22), 0.3 (late night) | |

### Incident heat (community reports)

Verified/known incident reports cluster within 120 m and radiate influence
~140 m (grows with cluster size). Each report carries a weight of
confidence × status (verified 1.0, resolved 0.4, pending 0.65) × category
(stalking 1.0, harassment 0.9, suspicious 0.8, poor lighting 0.6) × recency
(≤7 days 1.0 → >90 days 0.3). Segment penalty = min(18, weight × 8).

### Route-time adjustments (`risk_engine.py`)

- Verified incident reports are matched to road segments within **30 m** and
  apply an additional incident penalty.
- Shade corrections from verified "no shade" / "cool shaded spot" reports are
  added to the base shade score (clamped).

### Zone classification

| Safety score | Zone colour | Risk level |
|-------------|-------------|-----------|
| ≥ 70 | 🟢 Green | Safe |
| 40–69 | 🟡 Amber | Cautious |
| < 40 | 🔴 Red | Risky |

## Shade & heat scoring reference

Every route segment also carries a shade score and the route carries live heat
data, which combine into the comfort score shown before you start walking.

### Shade score (`logic/generate_shade_map.py`)

Scores a ~15 m buffer around each street segment against OSM canopy features
(`natural=tree/wood/scrub`, `landuse=forest/grass`, `leisure=park/garden`):

| Component | Contribution |
|-----------|-------------|
| Tree points in buffer | 0.7 × min(1.0, trees ÷ 6) |
| Green-area coverage of buffer | 0.3 × min(1.0, coverage ÷ 0.6) |

Result clamped to [0, 100] and written as `shade_score` with
`shade_source='osm_canopy'`. The visual Shade % on a route is the average
across matched segments.

> **Data caveat:** OSM's canopy tagging in Pune is sparse — most segments
> score 0. A 0% reading is expected in unmapped areas, not a data error.

### Optional upgrade: satellite shade (Google Earth Engine)

Shade accuracy can be upgraded from OSM canopy tags to per-segment NDVI
derived from Sentinel-2 imagery. This is **strictly optional** and off by
default: without `SHADE_DB_URL` set, nothing runs and the OSM shade above is
used everywhere. When enabled, a resumable batch (runnable in slices across
several evenings — no all-day session needed) scores segments into a separate
local sidecar database; the main database is never written to, and verified
citizen reports always correct the satellite estimate on top.

Each score is the **median NDVI over a trailing 365-day window** ending on
the batch run date (a "typical canopy over the last year" value, not a
single-day snapshot; shorter windows are a flag away). After the batch
completes, the app **never contacts Google at runtime** — routes read the
local sidecar only; GEE is touched again solely when someone re-runs the
batch for a seasonal refresh. Full setup, monitoring and stop/resume:
[SETUP.md — Step 5b](SETUP.md#step-5b--optional-satellite-shade-google-earth-engine).

### Heat penalty (`backend/.../services/weather_service.py`)

Live Open-Meteo `apparent_temperature` (keyless, no API account):

| Feels-like temp | Heat penalty |
|----------------|-------------|
| ≥ 42 °C | 30 |
| ≥ 38 °C | 20 |
| ≥ 32 °C | 12 |
| ≥ 28 °C | 5 |
| below 28 °C | 0 |

UV index ≥ 8 adds +5. Weather failures **degrade, never block**: heat penalty
falls back to `0.0`, displayed as "Pleasant".

### Comfort score

Weighted blend of the safety, shade and heat signals. The `prefer` query
parameter on `/route-safe` selects the weighting profile: `balanced`,
`safety`, `shade`, or `heat`.

---

## Known limitations

- **Pune-only geography.** The Valhalla tile set covers an OSM western-India
  extract while the OSMnx scoring pipeline is scoped to Pune. Extending to other
  cities requires re-running the data pipeline and re-preprocessing Valhalla
  tiles.
- **Demo dependency on local laptop.** The ngrok distribution model requires the
  host machine to remain online. A proper cloud deployment (VPS with Docker
  Compose) would remove this constraint.
- **Road-type heuristics, not point tags.** The pipeline does not currently
  read point-level OSM tags like `lit=` or `sidewalk=` — lighting and crowd
  inputs come from road-type heuristics and intersection density. Unmapped/unknown
  road types fall back to middle-of-the-road defaults.
- **Sparse canopy data.** OSM tree/park tagging is sparse in Pune — most street
  segments shade-score 0, so route Shade % is often `0%`/`<1%` unless the route
  passes mapped greenery. Upgrading to satellite-derived canopy would fix this.
- **Heading on emulators.** Map rotation during navigation requires a real
  device with a compass. Android emulators return a constant heading of 0 or -1.
- **Media uploads.** Attaching photos to incident reports is planned for a future
  release. The button is hidden in v1.

---

## Privacy, security & safety disclaimer

Grounded in what the code actually does:

- **Location data sent to the backend:** your origin/destination coordinates go
  to the backend with every route request. Active navigation uses the device GPS
  fixes on-device only (camera anchoring, off-route detection); report/SOS
  submissions include the GPS coordinate recorded at that moment. The backend
  does not continuously track you.
- **Incident reports** are stored with the coordinates and link back to your
  Supabase user ID (JWT-derived hash on the server); they enter `pending` and
  are only surfaced on the map/reports feed.
- **SOS alerts** are stored in `emergency_alerts` together with the GPS
  coordinate, a timestamp and the trusted-contact list you supplied for that
  alert. Delivery happens via on-device SMS; the backend does not message
  anyone.
- **Trusted-contact details** are stored in the alert record and on-device
  (`shared_preferences`); they are not used beyond SMS fan-out and emergency
  records.
- **Secrets:** the Supabase service-role key, JWT secret, `ADMIN_API_KEY` and
  `DATABASE_URL` are server-side secrets in `backend/.env` (gitignored). The
  mobile app only needs the two public values (`SUPABASE_URL`,
  `SUPABASE_ANON_KEY`) plus the MapTiler key and `API_BASE_URL`.
- **Safety-score honesty:** scores are *estimates* derived from OSM tags and
  community reports — they can be stale, biased or wrong. They are decision
  support only, **not** a guarantee that a street is safe or dangerous.
- **Not an emergency service.** The SOS feature is an aid, never a substitute
  for contacting police/ambulance services (call 112 in India).

---

## Roadmap

- [ ] Cloud VPS deployment with Docker Compose (remove ngrok dependency)
- [ ] Play Store release with release keystore and proper signing
- [ ] Scheduled safety data refresh (weekly OSMnx re-ingest via cron — currently manual)
- [ ] Media upload support for incident reports (Supabase Storage)
- [ ] Backend-driven emergency fan-out (push notifications; on-device SMS already works today)
- [ ] Per-request time-of-day scoring (the pipeline currently bakes a time factor at ingest; route-time night penalties are not computed live)
- [ ] Expand beyond Pune to other Indian cities

---

## Contributing

ResilientSteps is a private project in active development. If you have been given
access to this repository:

1. Do not push directly to `main` — branch, PR, and wait for review
2. Keep `backend/.env` and `mobile/config/dart_defines.json` out of all commits —
   both are gitignored
3. `logic/generate_safety_map.py` may have local dataset changes — check before
   staging; never commit anything under `logic/outputs/`, `logic/cache/` or
   `backend/valhalla_tiles/`
4. Before committing:
   - Backend: `cd backend; .\\.venv\\Scripts\\python.exe -m pytest tests\\ -q` (expected: all pass)
   - Mobile: `flutter analyze` (expected clean apart from 2 pre-existing plugin
     deprecation infos) and `flutter test` (expected all pass)
5. PRs should update this README if they change endpoints or scoring behaviour,
   and [SETUP.md](SETUP.md) if they change installation, configuration or
   run-book steps

License: MIT (see [LICENSE](LICENSE)).

---

## Acknowledgements

ResilientSteps is built on the shoulders of genuinely excellent open-source work:

- **[OpenStreetMap](https://www.openstreetmap.org)** — the street data that makes safety scoring possible
- **[Valhalla](https://github.com/valhalla/valhalla)** — open-source routing engine with excellent pedestrian costing
- **[OSMnx](https://github.com/gboeing/osmnx)** — street network analysis in Python
- **[H3](https://h3geo.org)** — Uber's hexagonal spatial indexing system
- **[flutter_map](https://github.com/fleaflet/flutter_map)** — Flutter map rendering
- **[Supabase](https://supabase.com)** — open-source Firebase alternative
- **[Maptiler](https://www.maptiler.com)** — clean map tiles for production apps

---

<div align="center">

*Built for the people of Pune who deserve to walk home safely.*

</div>
