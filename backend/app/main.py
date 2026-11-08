from contextlib import asynccontextmanager
import logging
import sys

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles
from pathlib import Path
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.middleware.gzip import GZipMiddleware
from starlette.requests import Request

from app.core.database import AsyncSessionLocal
from app.modules.walksafe import router as walksafe_router
from app.modules.infrastructure import router as infra_router
from app.modules.waste import router as waste_router
from app.modules.dashboard import router as dashboard_router
from app.modules.walksafe.services.safety_dataset_cache import safety_dataset_cache
from app.core.config import load_config

LOGGER = logging.getLogger(__name__)
_cache_ready = False


@asynccontextmanager
async def lifespan(_: FastAPI):
    global _cache_ready
    _cache_ready = False

    if "pytest" not in sys.modules:
        try:
            async with AsyncSessionLocal() as session:
                await safety_dataset_cache.warm_cache(session)
            _cache_ready = True
        except Exception as exc:  # pragma: no cover - startup should degrade gracefully
            LOGGER.warning("Safety dataset cache warmup skipped: %s", exc)
    else:
        _cache_ready = True

    yield


app = FastAPI(
    title="ResilientSteps API",
    description="ResilientSteps API — Safety & Comfort-Aware Walking Navigation",
    version="1.0.0",
    lifespan=lifespan,
)

config_data = load_config()
profile_cfg = config_data.get("profile", {})
raw_cors = profile_cfg.get("cors", {}).get("origins", ["*"])
if isinstance(raw_cors, str):
    cors_origins = [o.strip() for o in raw_cors.split(",") if o.strip()]
elif isinstance(raw_cors, list):
    cors_origins = raw_cors
else:
    cors_origins = ["*"]

app.add_middleware(
    CORSMiddleware,
    allow_origins=cors_origins,
    allow_credentials=False,
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["Content-Type", "Authorization", "ngrok-skip-browser-warning"],
)
app.add_middleware(GZipMiddleware, minimum_size=1000)


class NgrokHeaderMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        response = await call_next(request)
        response.headers["ngrok-skip-browser-warning"] = "true"
        return response


app.add_middleware(NgrokHeaderMiddleware)

app.include_router(walksafe_router, prefix="/walksafe", tags=["ResilientSteps"])
app.include_router(walksafe_router)

app.include_router(infra_router, prefix="/infra", tags=["Infrastructure"])

app.include_router(waste_router, prefix="/waste", tags=["Waste Management"])

app.include_router(dashboard_router, prefix="/dashboard", tags=["Dashboard"])

# Mount static web dashboard UI with Cache-Control headers for static assets
class CachedStaticFiles(StaticFiles):
    def __init__(self, *args, cache_control: str = "public, max-age=86400", **kwargs):
        super().__init__(*args, **kwargs)
        self.cache_control = cache_control

    def file_response(self, *args, **kwargs):
        resp = super().file_response(*args, **kwargs)
        path = str(args[0]) if args else str(kwargs.get("full_path", ""))
        if path.endswith(".html"):
            resp.headers["Cache-Control"] = "no-cache, must-revalidate"
        else:
            resp.headers["Cache-Control"] = self.cache_control
        return resp


static_dir = Path(__file__).resolve().parent.parent / "static" / "dashboard"
if static_dir.exists():
    app.mount("/dashboard-ui", CachedStaticFiles(directory=str(static_dir), html=True), name="dashboard-ui")

@app.get("/")
async def root():
    return {"message": "ResilientSteps API is running", "status": "online"}


@app.get("/city")
async def get_city_info():
    """
    Returns city metadata (name, center coordinates, timezone) for mobile/client initialization.
    """
    cfg = load_config()
    city = cfg.get("city", {})
    return {
        "city": city.get("name", "Pune"),
        "state": city.get("state", "Maharashtra"),
        "country": city.get("country", "India"),
        "center": city.get("center", {"lat": 18.5204, "lon": 73.8567}),
        "h3_resolution": city.get("h3_resolution", 9),
        "timezone": city.get("timezone", "Asia/Kolkata"),
    }


@app.get("/ready")
async def readiness():
    """
    Kubernetes/load-balancer style readiness probe.
    Returns 200 when the safety dataset cache is warmed and ready to serve requests.
    Returns 503 during startup warmup.
    """
    if not _cache_ready:
        return JSONResponse(
            status_code=503,
            content={
                "ready": False,
                "reason": "Safety dataset cache warming up",
            },
        )
    return {"ready": True}
