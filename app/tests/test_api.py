import pytest
from fastapi.testclient import TestClient

from src import main


@pytest.fixture
def client(monkeypatch):
    # No real DB, Redis or SQS in unit tests: stub every outside call.
    monkeypatch.setattr(main, "publish_click_event", lambda **kw: None)
    monkeypatch.setattr(main, "increment_clicks", lambda short_id: None)
    return TestClient(main.app, follow_redirects=False)


def test_healthz(client, monkeypatch):
    monkeypatch.setattr(main, "get_backend_type", lambda: "postgres")
    resp = client.get("/healthz")
    assert resp.status_code == 200
    assert resp.json()["status"] == "ok"


def test_shorten_returns_8_char_id_and_stores_it(client, monkeypatch):
    stored = {}
    monkeypatch.setattr(main, "put_mapping", lambda s, u: stored.update({s: u}))
    resp = client.post("/shorten", json={"url": "https://example.com"})
    assert resp.status_code == 200
    short = resp.json()["short"]
    assert len(short) == 8
    assert stored[short] == "https://example.com"


def test_shorten_requires_url(client):
    assert client.post("/shorten", json={}).status_code == 400


def test_resolve_cache_hit_skips_database(client, monkeypatch):
    monkeypatch.setattr(main, "get_cached_url", lambda s: "https://example.com")

    def boom(_):
        raise AssertionError("database must not be read on a cache hit")

    monkeypatch.setattr(main, "get_mapping", boom)
    resp = client.get("/abc12345")
    assert resp.status_code == 307
    assert resp.headers["location"] == "https://example.com"


def test_resolve_cache_miss_reads_database_and_fills_cache(client, monkeypatch):
    cached = {}
    monkeypatch.setattr(main, "get_cached_url", lambda s: None)
    monkeypatch.setattr(main, "set_cached_url", lambda s, u: cached.update({s: u}))
    monkeypatch.setattr(main, "get_mapping", lambda s: {"url": "https://example.com"})
    resp = client.get("/abc12345")
    assert resp.status_code == 307
    assert cached == {"abc12345": "https://example.com"}


def test_resolve_unknown_id_is_404(client, monkeypatch):
    monkeypatch.setattr(main, "get_cached_url", lambda s: None)
    monkeypatch.setattr(main, "get_mapping", lambda s: None)
    assert client.get("/nope1234").status_code == 404


def test_stats(client, monkeypatch):
    monkeypatch.setattr(main, "get_mapping", lambda s: {"url": "https://example.com", "clicks": 3})
    assert client.get("/stats/abc12345").json() == {
        "short": "abc12345", "url": "https://example.com", "clicks": 3,
    }
