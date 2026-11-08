"""
Simple in-process rate limiter for ResilientSteps API endpoints.

Uses a token-bucket algorithm keyed by the authenticated user, falling back to
the client address for anonymous requests. Keying on identity keeps clients
separate when many of them share one address (corporate NAT, a demo audience on
one wifi, or a tunnel such as ngrok forwarding every request from 127.0.0.1).
This is a single-process solution — for multi-instance deployments, replace
with a Redis-backed implementation.
"""

import os
import time
from collections import defaultdict
from dataclasses import dataclass, field
from typing import Optional

from fastapi import HTTPException, Request

_TRUSTED_PROXY_DEPTH = int(os.environ.get("TRUSTED_PROXY_DEPTH", "0"))

# Addresses a local tunnel (ngrok, cloudflared, ssh -L) connects from.
_LOOPBACK_HOSTS = frozenset({"127.0.0.1", "::1", "::ffff:127.0.0.1", "localhost"})


@dataclass
class _TokenBucket:
    capacity: int
    tokens: float = 0.0
    last_refill: float = field(default_factory=time.monotonic)

    def try_consume(self, refill_rate: float) -> bool:
        now = time.monotonic()
        elapsed = now - self.last_refill
        self.tokens = min(self.capacity, self.tokens + elapsed * refill_rate)
        self.last_refill = now

        if self.tokens >= 1.0:
            self.tokens -= 1.0
            return True
        return False


class RateLimiter:
    """
    FastAPI-compatible rate limiter.

    Usage as a dependency:

        report_limiter = RateLimiter(max_requests=5, window_seconds=3600)

        @router.post("/report")
        async def submit_report(..., _=Depends(report_limiter)):
            ...
    """

    def __init__(
        self,
        *,
        max_requests: int,
        window_seconds: int,
    ) -> None:
        self._max_requests = max_requests
        self._window_seconds = window_seconds
        self._refill_rate = max_requests / window_seconds
        self._buckets: dict[str, _TokenBucket] = defaultdict(
            lambda: _TokenBucket(capacity=max_requests, tokens=max_requests)
        )
        self._last_cleanup = time.monotonic()
        self._cleanup_interval = max(300.0, window_seconds * 2.0)

    async def __call__(self, request: Request) -> None:
        client_key = self._client_key(request)
        self._maybe_cleanup()

        bucket = self._buckets[client_key]
        if not bucket.try_consume(self._refill_rate):
            raise HTTPException(
                status_code=429,
                detail=(
                    f"Rate limit exceeded. Maximum {self._max_requests} "
                    f"requests per {self._window_seconds} seconds."
                ),
            )

    def _client_key(self, request: Request) -> str:
        """Bucket per user when the request is authenticated, else per address.

        user_id is set by the auth dependencies; those are resolved before the
        limiter on every route that uses both.
        """
        user_id = getattr(request.state, "user_id", None)
        if isinstance(user_id, str) and user_id:
            return f"user:{user_id}"
        return f"ip:{self._client_ip(request)}"

    def _client_ip(self, request: Request) -> str:
        forwarded = request.headers.get("x-forwarded-for")
        parts = (
            [part.strip() for part in forwarded.split(",") if part.strip()]
            if forwarded
            else []
        )
        client = request.client
        peer = client.host if client else None

        if parts:
            if _TRUSTED_PROXY_DEPTH > 0 and len(parts) >= _TRUSTED_PROXY_DEPTH:
                # Each trusted proxy appends the address it received from, so the
                # outermost one is at len - depth. Entries left of it are supplied
                # by the caller and cannot be trusted.
                return parts[len(parts) - _TRUSTED_PROXY_DEPTH]
            if peer in _LOOPBACK_HOSTS:
                # A local tunnel hands us the request from loopback and appends
                # the real client address last, where a spoofed leading entry
                # cannot displace it. Keying on the peer here would put every
                # tunnelled user in one bucket.
                return parts[-1]

        return peer or "unknown"

    def _maybe_cleanup(self) -> None:
        now = time.monotonic()
        if (now - self._last_cleanup) < self._cleanup_interval:
            return

        self._last_cleanup = now
        stale_threshold = now - (self._window_seconds * 2)
        stale_keys = [
            key
            for key, bucket in self._buckets.items()
            if bucket.last_refill < stale_threshold
        ]
        for key in stale_keys:
            del self._buckets[key]


report_rate_limiter = RateLimiter(max_requests=5, window_seconds=3600)
route_rate_limiter = RateLimiter(max_requests=60, window_seconds=60)
emergency_rate_limiter = RateLimiter(max_requests=3, window_seconds=600)
# /nearby-places fans out to Overpass (and Nominatim fallback): keep it strict so
# a client cannot burn the shared public-service quota.
nearby_rate_limiter = RateLimiter(max_requests=20, window_seconds=60)
