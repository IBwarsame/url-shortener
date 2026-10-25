"""
Redis cache-aside for short_id -> url lookups.

Set REDIS_URL to enable. Without it (or if Redis is unreachable) every call
is a no-op / miss, so the API keeps working straight from the database.
A short_id is the hash of its URL, so a cached mapping never changes and
needs no invalidation; the TTL only bounds memory use.
"""

import os
import logging

logger = logging.getLogger(__name__)

TTL_SECONDS = int(os.environ.get("CACHE_TTL_SECONDS", "300"))

_client = None


def _get_client():
    global _client
    if _client is not None:
        return _client

    url = os.environ.get("REDIS_URL")
    if not url:
        return None

    import redis
    _client = redis.Redis.from_url(
        url,
        decode_responses=True,
        socket_connect_timeout=0.25,
        socket_timeout=0.25,
    )
    return _client


def get_cached_url(short_id: str):
    client = _get_client()
    if not client:
        return None
    try:
        return client.get(f"url:{short_id}")
    except Exception as e:
        logger.warning(f"Cache read failed: {e}")
        return None


def set_cached_url(short_id: str, url: str):
    client = _get_client()
    if not client:
        return
    try:
        client.set(f"url:{short_id}", url, ex=TTL_SECONDS)
    except Exception as e:
        logger.warning(f"Cache write failed: {e}")
