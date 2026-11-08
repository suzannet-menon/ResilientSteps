"""
Supabase JWT Authentication Middleware for FastAPI.

Provides two FastAPI dependencies:
  - require_auth: rejects unauthenticated requests with 401.
  - optional_auth: returns the user_id if authenticated, None otherwise.

Usage:
    @router.post("/reports")
    async def submit_report(
        user_id: str = Depends(require_auth),
    ):
        ...

The middleware verifies JWTs locally using SUPABASE_JWKS or SUPABASE_JWT_SECRET.
If neither is configured, require_auth will reject all requests
and optional_auth will pass through unauthenticated.
"""

import json
import logging
import os
import time

import httpx
import jwt
from jwt import PyJWKSet
from dotenv import load_dotenv
from fastapi import HTTPException, Request

load_dotenv()

LOGGER = logging.getLogger(__name__)

SUPABASE_JWKS = os.environ.get("SUPABASE_JWKS", "")
SUPABASE_URL = os.environ.get("SUPABASE_URL", "")
SUPABASE_JWT_SECRET = os.environ.get("SUPABASE_JWT_SECRET", "")

_jwk_set_cache = None
_jwk_set_last_fetched = 0.0
_JWK_CACHE_TTL = 3600.0  # 1 hour


def _get_jwk_set() -> PyJWKSet | None:
    """
    Get the PyJWKSet instance for verifying ES256 JWTs.
    Tries static SUPABASE_JWKS env var first, then fetches dynamically from Supabase.
    """
    global _jwk_set_cache, _jwk_set_last_fetched

    if SUPABASE_JWKS:
        try:
            return PyJWKSet.from_dict(json.loads(SUPABASE_JWKS))
        except Exception as exc:
            LOGGER.error("Failed to parse SUPABASE_JWKS env variable: %s", exc)

    now = time.time()
    if _jwk_set_cache and (now - _jwk_set_last_fetched < _JWK_CACHE_TTL):
        return _jwk_set_cache

    if SUPABASE_URL:
        jwks_url = f"{SUPABASE_URL.rstrip('/')}/auth/v1/.well-known/jwks.json"
        try:
            LOGGER.info("Fetching Supabase JWKS dynamically from %s", jwks_url)
            with httpx.Client(timeout=5.0) as client:
                resp = client.get(jwks_url)
                resp.raise_for_status()
                jwks_data = resp.json()
                _jwk_set_cache = PyJWKSet.from_dict(jwks_data)
                _jwk_set_last_fetched = now
                return _jwk_set_cache
        except Exception as exc:
            LOGGER.error("Failed to fetch JWKS dynamically from Supabase: %s", exc)
            if _jwk_set_cache:
                LOGGER.info("Using stale JWKS cache as fallback")
                return _jwk_set_cache

    return None


def _extract_token(request: Request) -> str | None:
    """Extract the Bearer token from the Authorization header."""
    auth_header = request.headers.get("authorization", "")
    if not auth_header.lower().startswith("bearer "):
        return None
    return auth_header[7:].strip() or None


def _decode_token(token: str) -> dict | None:
    """
    Decode and verify a Supabase JWT.
    Supports both ES256 (JWKS-based) and HS256 (secret-based) signature verification.
    Returns the decoded payload or None if verification fails.
    """
    try:
        header = jwt.get_unverified_header(token)
        alg = header.get("alg")
        kid = header.get("kid")
    except Exception as exc:
        LOGGER.debug("Failed to parse JWT header: %s", exc)
        return None

    if alg == "ES256":
        jwk_set = _get_jwk_set()
        if not jwk_set:
            LOGGER.warning(
                "ES256 token received but no JWKS available. "
                "Configure SUPABASE_JWKS or SUPABASE_URL in your environment."
            )
            return None

        key = None
        for k in jwk_set.keys:
            if k.key_id == kid:
                key = k
                break

        if not key:
            LOGGER.debug("No key found matching kid %s in JWKS", kid)
            return None

        try:
            payload = jwt.decode(
                token,
                key.key,
                algorithms=["ES256"],
                # Supabase tokens always carry aud="authenticated"; we verify
                # the signature only, so audience checking must stay off
                # (PyJWT raises InvalidAudienceError otherwise).
                options={"require": ["sub", "exp"], "verify_aud": False},
            )
            return payload
        except jwt.ExpiredSignatureError:
            LOGGER.debug("JWT token has expired")
            return None
        except jwt.InvalidTokenError as exc:
            LOGGER.debug("JWT verification failed: %s", exc)
            return None

    elif alg == "HS256":
        if not SUPABASE_JWT_SECRET:
            LOGGER.warning("HS256 token received but SUPABASE_JWT_SECRET is not configured")
            return None

        try:
            payload = jwt.decode(
                token,
                SUPABASE_JWT_SECRET,
                algorithms=["HS256"],
                # Supabase tokens always carry aud="authenticated"; we verify
                # the signature only, so audience checking must stay off
                # (PyJWT raises InvalidAudienceError otherwise).
                options={"require": ["sub", "exp"], "verify_aud": False},
            )
            return payload
        except jwt.ExpiredSignatureError:
            LOGGER.debug("JWT token has expired")
            return None
        except jwt.InvalidTokenError as exc:
            LOGGER.debug("JWT verification failed: %s", exc)
            return None

    else:
        LOGGER.debug("Unsupported JWT algorithm: %s", alg)
        return None


async def require_auth(request: Request) -> str:
    """
    FastAPI dependency that enforces authentication.
    Returns the authenticated user's ID (the 'sub' claim).
    Raises 401 if the token is missing, invalid, or expired.
    """
    token = _extract_token(request)
    if token is None:
        raise HTTPException(
            status_code=401,
            detail="Authentication required. Supply a valid Bearer token in the Authorization header.",
        )

    payload = _decode_token(token)
    if payload is None:
        raise HTTPException(
            status_code=401,
            detail="Invalid or expired authentication token.",
        )

    user_id = payload.get("sub")
    if not user_id:
        raise HTTPException(
            status_code=401,
            detail="Token does not contain a valid user identifier.",
        )

    # Published on request.state so the rate limiter can bucket per user.
    request.state.user_id = str(user_id)
    return str(user_id)


async def optional_auth(request: Request) -> str | None:
    """
    FastAPI dependency that extracts the user ID if a valid token is present,
    but does not reject unauthenticated requests.
    Returns the user ID or None.
    """
    token = _extract_token(request)
    if token is None:
        return None

    payload = _decode_token(token)
    if payload is None:
        return None

    user_id = payload.get("sub")
    if not user_id:
        return None

    # Published on request.state so the rate limiter can bucket per user.
    request.state.user_id = str(user_id)
    return str(user_id)
