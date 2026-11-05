import os
import re
import logging
from pathlib import Path
from typing import Any, Dict, Optional
import yaml

LOGGER = logging.getLogger(__name__)

# Find project root directory containing config/
_CURRENT_DIR = Path(__file__).resolve().parent
_PROJECT_ROOT = _CURRENT_DIR
while _PROJECT_ROOT.parent != _PROJECT_ROOT:
    if (_PROJECT_ROOT / "config").exists() or (_PROJECT_ROOT / "backend").exists():
        break
    _PROJECT_ROOT = _PROJECT_ROOT.parent

# Default to project root / config if found, else fallback relative to app
CONFIG_DIR = _PROJECT_ROOT / "config"
if not CONFIG_DIR.exists():
    CONFIG_DIR = _CURRENT_DIR.parent.parent.parent / "config"


_ENV_VAR_PATTERN = re.compile(r"\$\{([^}]+)\}")
_YAML_CACHE: Dict[Path, Dict[str, Any]] = {}


def _interpolate_env_vars(raw_text: str) -> str:
    """
    Interpolate ${ENV_VAR} or ${ENV_VAR:-default} references in YAML raw text.
    """
    def _replacer(match: re.Match) -> str:
        var_expr = match.group(1)
        if ":-" in var_expr:
            var_name, default_val = var_expr.split(":-", 1)
            return os.environ.get(var_name, default_val)
        return os.environ.get(var_expr, "")

    return _ENV_VAR_PATTERN.sub(_replacer, raw_text)


def _load_yaml(path: Path) -> Dict[str, Any]:
    if not path.exists():
        LOGGER.warning("Config file not found at: %s", path)
        return {}

    try:
        mtime = path.stat().st_mtime
    except OSError:
        mtime = 0.0

    cached = _YAML_CACHE.get(path)
    if cached is not None and cached["mtime"] == mtime:
        if not cached["has_env"]:
            return cached["data"]
        env_snapshot = tuple(
            (var, os.environ.get(var, default))
            for var, default in cached["env_deps"]
        )
        if env_snapshot == cached["env_snapshot"]:
            return cached["data"]

    try:
        with open(path, "r", encoding="utf-8") as f:
            raw = f.read()
    except Exception as exc:
        LOGGER.error("Failed to read config from %s: %s", path, exc)
        return {}

    has_env = "${" in raw
    env_deps = []
    if has_env:
        for match in _ENV_VAR_PATTERN.finditer(raw):
            expr = match.group(1)
            if ":-" in expr:
                v, d = expr.split(":-", 1)
                env_deps.append((v, d))
            else:
                env_deps.append((expr, ""))

    interpolated = _interpolate_env_vars(raw) if has_env else raw
    try:
        data = yaml.safe_load(interpolated)
        parsed = data if isinstance(data, dict) else {}
    except Exception as exc:
        LOGGER.error("Failed to parse YAML from %s: %s", path, exc)
        parsed = {}

    env_snapshot = tuple(
        (var, os.environ.get(var, default)) for var, default in env_deps
    )
    _YAML_CACHE[path] = {
        "mtime": mtime,
        "has_env": has_env,
        "env_deps": env_deps,
        "env_snapshot": env_snapshot,
        "data": parsed,
    }
    return parsed

class ConfigLoader:
    def __init__(self, config_dir: Optional[Path] = None):
        self.config_dir = config_dir or CONFIG_DIR

    def load_config(self, profile_name: Optional[str] = None) -> Dict[str, Any]:
        profile = profile_name or os.environ.get("CITYOS_PROFILE", "local")

        city_data = _load_yaml(self.config_dir / "city.yaml")
        scoring_data = _load_yaml(self.config_dir / "scoring.yaml")
        profile_path = self.config_dir / "profiles" / f"{profile}.yaml"
        profile_data = _load_yaml(profile_path)

        if not profile_data and not profile_path.exists():
            LOGGER.warning("Profile '%s' file does not exist at %s", profile, profile_path)

        return {
            "profile_name": profile,
            "city": city_data.get("city", city_data),
            "scoring": scoring_data,
            "profile": profile_data,
        }


# Global instance
_loader = ConfigLoader()


def load_config(profile_name: Optional[str] = None) -> Dict[str, Any]:
    return _loader.load_config(profile_name)


def get_city_config() -> Dict[str, Any]:
    return load_config().get("city", {})


def get_scoring_config() -> Dict[str, Any]:
    return load_config().get("scoring", {})


def get_profile_config() -> Dict[str, Any]:
    return load_config().get("profile", {})
