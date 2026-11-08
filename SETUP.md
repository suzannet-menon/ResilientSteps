# Setup & Installation Guide

This is the setup/installation documentation for **ResilientSteps**. For the
product overview, features and architecture, see the main
[README.md](README.md).

One-line summary of the process: clone → configure two env files → run
migrations → build the map datasets → start Valhalla → start the backend → run
the app.

---

## Table of contents

1. [Prerequisites](#prerequisites)
2. [Step 1 — Clone and configure the backend](#step-1--clone-and-configure)
3. [Environment configuration reference](#environment-configuration-reference)
4. [Step 2 — Database & migrations](#step-2--set-up-the-database)
5. [Step 3 — Valhalla](#step-3--start-valhalla-routing-engine)
6. [Step 4 — Safety dataset](#step-4--populate-the-safety-database)
7. [Step 5 — Shade scores](#step-5--populate-the-shade-scores)
8. [Step 6 — Backend](#step-6--start-the-backend)
9. [Step 7 — Mobile app](#step-7--run-the-mobile-app)
10. [Dashboard](#dashboard)
11. [Sharing & distribution (ngrok APK)](#sharing--distribution)
12. [Running tests](#running-tests)
13. [Common pitfalls & troubleshooting](#common-pitfalls--troubleshooting)

---

## Prerequisites

- [Flutter SDK](https://docs.flutter.dev/get-started/install) (stable channel)
- [Python 3.11+](https://www.python.org/downloads/)
- [Docker Desktop](https://www.docker.com/products/docker-desktop/) (for Valhalla)
- A [Supabase](https://supabase.com) project with PostGIS enabled
- A [Maptiler](https://www.maptiler.com) free account (for map tiles)
- [ngrok](https://ngrok.com) free account with a static domain (only for demo sharing)

---

## Step 1 — Clone and configure

```bash
git clone https://github.com/suzannet-menon/ResilientSteps.git
cd ResilientSteps
cp backend/.env.example backend/.env
```

Open `backend/.env` and set:

```env
# Supabase
SUPABASE_URL=https://your-project-ref.supabase.co
SUPABASE_ANON_KEY=your-anon-key
SUPABASE_SERVICE_KEY=your-service-role-key
SUPABASE_JWT_SECRET=your-jwt-secret

# Database (Supabase direct connection string)
DATABASE_URL=postgresql+asyncpg://postgres:password@db.your-project-ref.supabase.co:5432/postgres

# Routing
VALHALLA_BASE_URL=http://localhost:8002

# Admin moderation (generate with: python -c "import secrets; print(secrets.token_urlsafe(36))")
ADMIN_API_KEY=choose-a-long-random-string

# Optional: crash reporting
SENTRY_DSN=your-sentry-dsn
```

> `docker compose` and the Alembic migrations both validate/consume this file,
> so it must exist **before** Step 3 and Step 2.

## Environment configuration reference

The backend reads `backend/.env` at runtime; the Flutter app receives its values
baked in at build time (dart-defines / `mobile/config/dart_defines.json`).
Privileged keys (service role, admin key, JWT secret) belong only in the backend
`.env` — never in dart-defines, never in Git.

| Variable | Purpose | Required | Belongs in |
|---|---|---|---|
| `SUPABASE_URL` | Supabase REST/auth base URL | Yes | Backend + mobile |
| `SUPABASE_ANON_KEY` | Public anon key (RLS-enforced reads) | Yes | Backend + mobile |
| `SUPABASE_SERVICE_KEY` | Privileged service-role operations | Yes | **Backend only** |
| `SUPABASE_JWT_SECRET` | Local Supabase JWT validation (HS256) | Yes (auth) | **Backend only** |
| `DATABASE_URL` | Postgres/PostGIS async connection | Yes | **Backend only** |
| `VALHALLA_BASE_URL` | Routing engine (default `http://localhost:8002`) | Yes | Backend |
| `ADMIN_API_KEY` | Header key for `/admin/*` moderation | Yes (moderation) | **Backend only** |
| `MAPTILER_API_KEY` | Map tile access | Yes | Mobile (dart-define) |
| `SENTRY_DSN` | Crash reporting | Optional | Backend |
| `PHOTON_BASE_URL` | Placeholder in `.env.example`; not read by backend code today | Optional | Backend |
| `SHADE_DB_URL` | Local satellite-shade sidecar (Step 5b; leave unset for OSM-only shade) | Optional | **Backend only** |

---

## Step 2 — Set up the database

Enable the PostGIS extension in your Supabase admin panel:

> Database → Extensions → search "postgis" → enable

Then create the schema with Alembic, **from a project virtual environment**
(do not install the dependencies into a global Python):

```bash
cd backend
python -m venv .venv

# Windows
.\\.venv\\Scripts\\activate

# macOS / Linux
source .venv/bin/activate

pip install -r requirements.txt
alembic upgrade head
```

---

## Step 3 — Start Valhalla (routing engine)

The root `docker-compose.yml` defines both `valhalla` and `backend`:

```bash
# From the project root
docker compose up -d valhalla
```

The first start downloads the OSM western-India extract (~500 MB) and builds
the routing tiles — expect **10–20 minutes** with no response on port 8002;
subsequent starts reuse the `valhalla_tiles` volume and come up in seconds.
The backend service mounts `./backend/.env` and compose validates it, so that
file must exist.

Wait until the terminal shows `Valhalla server running on port 8002`, then verify:

```bash
curl http://localhost:8002/status
# Expected: JSON response with tileset_last_modified
```

---

## Step 4 — Populate the safety database

Score every walkable street in the city (Pune) and generate H3 safety zones:

```bash
cd logic
python generate_safety_map.py
```

Takes 10–20 minutes on first run; the OSMnx graph is cached locally so re-runs
are fast. On success you will see (counts illustrative — they depend on current
OSM data):

```text
Written 449,342 segments to database.
Written 1,204 safety zone polygons.
Done. Dataset version: 20250103-141200 | Time: 847.3s
```

This step **inserts new rows under a new `dataset_version`** each full run. If
an existing dataset is already live, re-running creates a second version — make
sure that is intended before re-running against a populated database.

## Step 5 — Populate the shade scores

Safety-map rows start with `shade_score = NULL`; without this step every route
shows "Shade: -". The script fetches OSM canopy features (trees, parks, forests,
grass) once, scores a ~15 m buffer around each street segment, and **updates the
rows written by `generate_safety_map.py`** — it never inserts segments, so it
must run *after* step 4. It reads the same `DATABASE_URL` from `backend/.env`
and creates the `(osm_way_id, dataset_version)` index it needs on first run.
Expect 10–30 minutes on first run (Overpass download); afterwards it runs from
the local cache.

```bash
cd logic
python generate_shade_map.py
```

Output (counts illustrative):

```text
Updating shade for dataset_version 20250103-141200...
Done writing 450,000 rows, committing...
Scored 450,000 segments. Mean shade 1.9 (skipped 1,102 edges without an OSM way id).
Done. Time: 1234.5s
```

> The shade job is **idempotent** — re-running rewrites the same rows and does not
> re-ingest geometry. Both seed scripts never touch the DB schema and can be re-run
> safely.

---

## Step 5b — OPTIONAL: satellite shade accuracy (Google Earth Engine)

**Skip this section entirely and the app still works.** Everything below is
opt-in: the backend only touches the satellite shade sidecar when
`SHADE_DB_URL` is set. Unset (the default), routes use the OSM-canopy shade
from Step 5 and nothing extra runs — no Docker service, no GEE account, no
batch. `docker compose up` never starts the sidecar unless you ask for it:

```bash
docker compose up -d shade-db   # optional, local Postgres on port 5433
```

**Why bother:** OSM canopy tags are sparse in most cities (91% of Pune's
segments score 0 from tags alone). The satellite batch derives per-segment
NDVI from Sentinel-2 imagery, which fixes exactly that data gap.

**What it writes:** a *separate local* Postgres table (`segment_shade`), keyed
by `(road_segment_id, dataset_version)`. The main database from Step 1 is
**never written to** by the batch — it is only read. Route-time, the backend
merges: satellite value where available, OSM value otherwise, and your
verified citizen reports always correct on top.

**What you need:** a Google Cloud project registered for Earth Engine
noncommercial use (free), a service-account JSON key, and two Python packages
that are deliberately **not** in `requirements.txt` (optional dependency):

```bash
.\.venv\Scripts\python.exe -m pip install earthengine-api google-auth
```

See the agent log entries S-072–S-092 for the registration walk-through if
you need it.

**Run it in slices — you do NOT need a full-day session.** The batch is
checkpointed after every 2,000 segments and fully resumable, so run it across
several evenings:

```bash
cd logic

# 1. Pilot: score 6 segments and eyeball them before any writes
python generate_shade_map_v2.py --pilot 6 --project YOUR_GEE_PROJECT_ID

# 2. Write the pilot into the sidecar (only after reviewing the dry-run)
python generate_shade_map_v2.py --pilot 6 --apply --project YOUR_GEE_PROJECT_ID

# 3. Expand as much as you like per session; --limit keeps it short
python generate_shade_map_v2.py --limit 20000 --apply --project YOUR_GEE_PROJECT_ID

# 4. Later sessions resume from the checkpoint exactly where it stopped
python generate_shade_map_v2.py --apply --resume --chunk-size 2000 --project YOUR_GEE_PROJECT_ID
```

Default mode is **dry-run** (computes and reports, writes nothing). Add
`--apply` only when you want sidecar writes. Point the backend at the sidecar
by adding `SHADE_DB_URL` to `backend/.env` (template value is in
`.env.example`), then restart the backend. Coverage grows segment-by-segment
as you run more slices; routes blend whatever is available at request time.

Typical full-city time: 10–16 hours of mostly GEE queue-waiting. There is no
penalty for stopping at any point — partial coverage is fully functional.

### What the scores mean (imagery vintage)

Each sidecar value is the **median NDVI of all cloud-free Sentinel-2 pixels**
over that segment's ~10 m corridor across a **trailing 365-day window ending
on the day you run the batch** (default `--days 365`; override with
`--start YYYY-MM-DD --end YYYY-MM-DD`, or `--days 90` for a season-specific
pass). So a score reads as "typical canopy over the last year" — not a
single-day snapshot. The `updated_at` column is the *write* timestamp, not
the imagery date. A full-year median blends seasons; re-run with a shorter
window if you need worst-case (pre-monsoon) or greenest-case shading.

### Monitoring, stopping, resuming

Progress lives in three places (nothing appears in the GEE web UI — see
below):

```bash
# one line per 2,000-row chunk (processed / gee / fallback / elapsed)
tail -f logic/outputs/shade_v2_full.log

# live row count and % of the city
docker exec resilientsteps_shade_db psql -U shade -d shade_db \
  -tc "SELECT count(*) FROM segment_shade;"

# exact resume checkpoint
cat logic/outputs/shade_v2_state.json
```

Stop any time by killing the batch process only (leave the backend alone):

```bash
# Windows: kill only processes whose command line contains the script name
Get-CimInstance Win32_Process -Filter "Name='python.exe'" |
  Where-Object { $_.CommandLine -like "*generate_shade_map_v2*" } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
```

Resume later with the same command plus `--resume` — it continues from the
checkpoint; at most one in-flight chunk (~2,000 rows) is lost. Upserts are
idempotent (`ON CONFLICT ... DO UPDATE`), so nothing is ever duplicated.
Completion writes a summary to `logic/outputs/shade_v2_last_run.txt`.

### What you will (and won't) see on Google's side

- **Task Manager on code.earthengine.google.com stays empty** — interactive
  API calls are not recorded as tasks, and the batch creates no Earth Engine
  assets.
- **Cloud Console → Earth Engine API → Quotas/Metrics** shows the request
  waves (each hump = one chunk).
- The consumer "Google Earth" app is unrelated and shows nothing.

### After the run — zero runtime dependence on Google

The app **never calls GEE at request time**. `/route-safe` reads the local
sidecar (millisecond queries); if Google were unreachable tomorrow, every
route scores identically. GEE is contacted only when a human re-runs the
batch — e.g. a quarterly seasonal refresh with the same `--apply --resume`
command. Nothing is scheduled, nothing is billed (noncommercial tier is
free), and nothing keeps running after the batch exits.

---

## Step 6 — Start the backend

```bash
cd backend
python -m uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload
```

`--host 0.0.0.0` is required for anything other than Chrome on the same machine
(see [the address table](#step-7--run-the-mobile-app)).

Verify ** readiness is two-stage**:

```bash
curl http://localhost:8000/
# {"message":"ResilientSteps API is running","status":"online"}

curl http://localhost:8000/ready
# 503 until the safety dataset cache is warmed, then {"ready":true}
```

Do not launch the mobile app until `/ready` returns `{"ready": true}` — see
[pitfall #2](#pitfall-2--starting-the-app-before-ready-green).

### Dashboard

The operator dashboard is served by the backend itself — no separate server:

```text
http://localhost:8000/dashboard-ui/
```

It asks for the `ADMIN_API_KEY` value from `backend/.env` on first use. It is
reachable whenever the backend is running.

---

## Step 7 — Run the mobile app

The app reads four compile-time constants (dart-defines). Create
`mobile/config/dart_defines.json` (gitignored — never committed) with all four
keys; the app asserts on all of them at startup:

```json
{
  "API_BASE_URL": "http://127.0.0.1:8000",
  "MAPTILER_API_KEY": "your-maptiler-key",
  "SUPABASE_URL": "https://your-project-ref.supabase.co",
  "SUPABASE_ANON_KEY": "your-anon-key"
}
```

Then run with the override for your target (dart-defines are **baked at build
time** — after any change, rebuild; APKs do not pick up new values from commits):

```bash
cd mobile
flutter pub get

# Flutter web (Chrome) on the same machine:
flutter run -d chrome --dart-define-from-file=config/dart_defines.json

# Android emulator (10.0.2.2 = host loopback from inside the emulator):
flutter run -d <emulator-id> --dart-define-from-file=config/dart_defines.json \
  --dart-define=API_BASE_URL=http://10.0.2.2:8000

# Physical Android device (same Wi-Fi network as the host machine):
flutter run -d <device-id> --dart-define-from-file=config/dart_defines.json \
  --dart-define=API_BASE_URL=http://YOUR-LAN-IP:8000
```

### Which address for the mobile app?

| Target | `API_BASE_URL` |
|---|---|
| Flutter web (Chrome) on the same machine | `http://127.0.0.1:8000` |
| Android emulator | `http://10.0.2.2:8000` — Android's alias for the host loopback; plain `localhost` refers to the *emulator itself* |
| Physical phone | `http://<host LAN IP>:8000` — phone and computer must be on the same Wi-Fi and the backend must have been started with `--host 0.0.0.0` |
| Shared demo APK | ngrok HTTPS URL (see [Sharing & distribution](#sharing--distribution)) |

> **Diagnosis tip:** if the app's route card shows no shade score **and** no
> heat index at all, suspect `API_BASE_URL` first. The backend always returns
> `heat_penalty` (it degrades to `0.0` → "Pleasant" if the weather API is down),
> so a missing heat index means the app never received the scored payload.
> Verify with:
> `curl "http://API_BASE_URL/route-safe?start_lat=18.5204&start_lon=73.8567&end_lat=18.53&end_lon=73.86"`

---

## Sharing & distribution

Instead of shipping a local-only APK or provisioning a dedicated server, use
**ngrok** to expose the local backend through a single HTTPS URL that anyone can
open on their phone. The APK then works on any device on the internet, and you
can keep iterating locally while the tunnel stays up.

### 1 — Sign up and claim a static domain

1.  Create a free account at [ngrok.com](https://ngrok.com).
2.  Claim a static domain at [dashboard.ngrok.com/domains](https://dashboard.ngrok.com/domains) (free tier allows a handful of domains).
3.  Install ngrok (brew, winget, or the [downloads page](https://ngrok.com/downloads) for your OS).

A *static* domain is strongly recommended: without one, the tunnel URL changes
on every restart and every installed APK would need a rebuild.

### 2 — Authenticate the CLI

```bash
ngrok config add-authtoken YOUR_AUTHTOKEN
```

Token available at [dashboard.ngrok.com/get-started/your-authtoken](https://dashboard.ngrok.com/get-started/your-authtoken).

### 3 — Start the tunnel

Open three terminals:

```bash
# Terminal 1 — Valhalla
docker compose -f backend/docker-compose.yml up valhalla

# Terminal 2 — Backend
cd backend
python -m uvicorn app.main:app --host 0.0.0.0 --port 8000

# Terminal 3 — ngrok tunnel
ngrok http --domain=your-static-domain.ngrok-free.app 8000
```

Verify at `https://your-static-domain.ngrok-free.app/` — you should see the
backend health response.

### 4 — Bake the ngrok URL into the APK

`dart-defines` are frozen at build time, so the mobile build must include the
ngrok URL:

```bash
cd mobile
flutter build apk --release \
  --dart-define-from-file=config/dart_defines.json \
  --dart-define=API_BASE_URL=https://your-static-domain.ngrok-free.app
```

APK output:

```text
mobile/build/app/outputs/flutter-apk/app-release.apk
```

Share the file via any channel. Recipients install it by opening the file on
their Android device ("Install from unknown sources" — Play Protect's
"install anyway" confirmation is expected for debug-signed builds).

> **Note:** the app requires the host machine to be running and ngrok to be
> active. If the host sleeps, the app shows connection errors until the stack is
> restarted. The ngrok URL is a demo-only hostname; do not commit it into Git.

---

## Running tests

```bash
# Backend tests (run with the project venv interpreter — see pitfall #8)
cd backend
.\\.venv\\Scripts\\python.exe -m pytest tests\\ -q   # Windows
# or: python -m pytest tests/ -v                  (macOS/Linux, venv activated)

cd ..

# Flutter checks
cd mobile
flutter pub get
flutter analyze     # expected clean
flutter test        # expected all pass
```

---

## Common pitfalls & troubleshooting

Lessons absorbed from real installation/operation runs. Each entry
states the symptom, the mechanism, and the fix.

### Pitfall 1 — Port 8000 already in use (`WinError 10013`)

**Symptom:** uvicorn dies immediately with `WinError 10013` (or `EADDRINUSE`),
usually after a second server was started while the first was still running.

**Fix:** only one server ever listens on 8000. Find and stop the old process
first, then start:

```powershell
# Windows
Get-NetTCPConnection -LocalPort 8000 | Select-Object OwningProcess
Stop-Process -Id <PID> -Force
```

### Pitfall 2 — Starting the app before `/ready` is green

**Symptom:** the app loads, then every route request fails with a
connection/timeout error that looks like a network bug; after an app restart it
suddenly works.

**Mechanism:** on startup the backend performs an aggregate-result cache
warm-up and serves `503` on `/ready` until the snapshot load completes. The app
does not retry failed backend requests.

**Fix:** respect the start order — Valhalla → backend → wait for
`curl http://localhost:8000/ready` → `{"ready": true}` → *then* launch the app.

### Pitfall 3 — Wrong host alias for the target device

**Symptom (emulator):** requests fail from the emulator while the same setup
works in Chrome.

**Mechanism:** on Android, `127.0.0.1`/`localhost` refers to the device's own
loopback, not the host machine.

**Fix:** pick the correct `API_BASE_URL` for the target:

| Target | Value |
|---|---|
| Chrome on the same machine | `http://127.0.0.1:8000` |
| Android emulator | `http://10.0.2.2:8000` |
| Physical phone | `http://<host LAN IP>:8000`, backend started with `--host 0.0.0.0`, same Wi-Fi |

To find the LAN IP on Windows: `ipconfig`. Loopback addresses never work from a
physical device.

### Pitfall 4 — Stale dart-defines after configuration changes

**Symptom:** the app keeps talking to an old address (or shows placeholder
tiles) after editing the defines file.

**Mechanism:** dart-defines are baked into the binary at compilation time.
`--dart-define-from-file` applies per invocation, and an already-installed build
does not update itself from commits or file changes.

**Fix:** re-run `flutter run` (or `flutter build apk --release`) after any
address/key change; distribute a freshly built APK — an installed build never
refreshes itself.

### Pitfall 5 — Route card shows no shade and no heat at all

**Symptom:** "Shade: -" and no heat banner.

**Mechanism:** the backend's heat source has a fallback (returns
`heat_penalty: 0` on failure), and the shade pipeline writes a real value for
every segment. If *both* are missing, the app likely received no scored payload
at all — i.e. the request went to nothing.

**Fix:** run `curl "http://API_BASE_URL/route-safe?..."`; if curl succeeds with
scores in the response, the app is pointed at the wrong `API_BASE_URL`.
(Pitfall 3/4 usually co-apply.)

### Pitfall 6 — Valhalla cold start looks hung

**Symptom:** `curl http://localhost:8002/status` returns nothing for 10–20 min,
while Docker shows the container running.

**Mechanism:** the very first start downloads the ~500 MB OSM extract and builds
the tileset. Progress lives in the container logs, not on port 8002.

**Fix:** `docker compose logs -f valhalla` to watch the build; `/status` gets a
response once the tiles are loaded. Later restarts start in seconds from
`valhalla_tiles`.

Also note that `docker compose` **validates `./backend/.env`** (the backend
service mounts it) — running compose before that file exists fails with an env
error even for Valhalla-only invocations.

### Pitfall 7 — Wrong compose file

**Mechanism:** `docker-compose.yml` (root) and `backend/docker-compose.yml`
define the same stack, but run differently with different path assumptions.

**Fix:** be deliberate: from the project root `docker compose up -d valhalla`
works; from anywhere else use `docker compose -f backend/docker-compose.yml up
valhalla` and be aware that mounted paths are resolved relative to the compose
file directory.

### Pitfall 8 — System Python / wrong interpreter for tests

**Symptom:** `pytest: No module named pytest` (or an import error) although
testing was otherwise confirmed.

**Mechanism:** the working environment has its own `backend/.venv`; dependencies
installed there are not visible to the system Python, and commands launched
without an active venv silently use the interpreter's global environment.

**Fix:** always invoke the venv explicitly:

```bash
# Windows
cd backend
.\\.venv\\Scripts\\python.exe -m pytest tests\\ -q

# macOS/Linux (venv activated)
python -m pytest tests/ -q
```

The same rule applies to Alembic (`venv python -m alembic upgrade head` from
`backend/`).

### Pitfall 9 — Android APK build fails with a Java version error

**Mechanism:** a very new JDK can be incompatible with the project's Gradle
version (e.g. Gradle 8.14 pairs with JDK 21; a JDK substantially newer fails the
build).

**Fix:** pin a compatible JDK via `flutter config --jdk-dir=<path>` and confirm
with `flutter doctor`.

### Pitfall 10 — ngrok URL changes on every restart

**Mechanism:** without a reserved domain, ngrok allocates a fresh random URL on
each tunnel start. APK `API_BASE_URL`s are baked at build time (pitfall 4), so a
new URL voids every installed build.

**Fix:** claim a free static domain and run
`ngrok http --domain=<static>.ngrok-free.app 8000`.

Browser note: first visit to an ngrok tunnel URL with a browser shows an ngrok
interstitial click-through page, not a backend error. Programmatic clients can
send `ngrok-skip-browser-warning: 1` if the interstitial intercepts requests.

### Pitfall 11 — Dashboard unreachable

**Mechanism:** the dashboard is served by the backend (there is no separate
dashboard server or port).

**Fix:** it is up whenever the backend is up: `http://localhost:8000/dashboard-ui/`.
Login takes the `ADMIN_API_KEY` value from `backend/.env` — this is a
backend-only secret and is unrelated to the mobile dart-defines.

---

Back to [README.md](README.md).
