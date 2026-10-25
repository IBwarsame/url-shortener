from src import cache


class FakeRedis:
    def __init__(self):
        self.data = {}

    def get(self, key):
        return self.data.get(key)

    def set(self, key, value, ex=None):
        self.data[key] = value


class BrokenRedis:
    def get(self, key):
        raise ConnectionError("redis down")

    def set(self, key, value, ex=None):
        raise ConnectionError("redis down")


def test_no_redis_url_is_a_miss(monkeypatch):
    monkeypatch.setattr(cache, "_client", None)
    monkeypatch.delenv("REDIS_URL", raising=False)
    assert cache.get_cached_url("abc") is None
    cache.set_cached_url("abc", "https://example.com")  # must not raise


def test_roundtrip(monkeypatch):
    monkeypatch.setattr(cache, "_client", FakeRedis())
    cache.set_cached_url("abc", "https://example.com")
    assert cache.get_cached_url("abc") == "https://example.com"


def test_fails_open_when_redis_is_down(monkeypatch):
    monkeypatch.setattr(cache, "_client", BrokenRedis())
    assert cache.get_cached_url("abc") is None
    cache.set_cached_url("abc", "https://example.com")  # must not raise
