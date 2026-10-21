from unittest.mock import MagicMock, patch

import pytest
import requests

import main
from main import ServiceConfig


@pytest.fixture(autouse=True)
def clear_cache():
    main.icon_cache.clear()


@pytest.fixture
def client(monkeypatch):
    svc = ServiceConfig(name="svc", url="http://svc.test")
    monkeypatch.setattr(main.config, "services", [svc])
    return main.app.test_client()


def resp(ok=True, status=200, content=b"x", headers=None, text="", url="http://svc.test"):
    r = MagicMock()
    r.ok, r.status_code, r.content = ok, status, content
    r.headers, r.text, r.url = headers or {}, text, url
    return r


def test_service_defaults_and_replacements():
    s = ServiceConfig(
        name="a",
        url="http://a.$d",
        check_url="http://a.$d/health",
        url_replacements={"$d": "lan"},
        display_url_replacements={"http://": ""},
    )
    assert s.url == "http://a.lan"
    assert s.check_url == "http://a.lan/health"
    assert s.display_url == "a.$d"
    assert ServiceConfig(name="b", url="http://b").check_url == "http://b"


def test_read_config(tmp_path):
    p = tmp_path / "c.json"
    p.write_text('{"services": [{"name": "x", "url": "http://x"}]}')
    assert main.read_config(str(p)).services[0].name == "x"


def test_ping(client):
    assert client.get("/ping").data == b"Pong"


def test_unknown_route_redirects_home(client):
    r = client.get("/nope")
    assert r.status_code == 302 and r.headers["Location"] == "/"


def test_home_renders(client):
    assert client.get("/").status_code == 200


def test_status_not_found(client):
    assert client.get("/status/missing").status_code == 404


def test_status_up(client):
    with patch("main.requests.get", return_value=resp()):
        data = client.get("/status/svc").get_json()
    assert data["up"] is True and data["status_code"] == 200


def test_status_down_on_error(client):
    with patch("main.requests.get", side_effect=requests.ConnectionError("boom")):
        data = client.get("/status/svc").get_json()
    assert data["up"] is False and "boom" in data["error"]


def test_check_service_not_ok():
    with patch("main.requests.get", return_value=resp(ok=False, status=500)):
        assert main.check_service(ServiceConfig(name="a", url="http://a"))["up"] is False


def test_fetch_icon_from_link_tag():
    page = resp(text='<link rel="icon" href="/i.png">')
    icon = resp(content=b"png", headers={"Content-Type": "image/png"})
    with patch("main.requests.get", side_effect=[page, icon]) as g:
        result = main.fetch_icon(ServiceConfig(name="a", url="http://svc.test"))
    assert result == ("image/png", b"png")
    assert g.call_args_list[1].args[0] == "http://svc.test/i.png"


def test_fetch_icon_falls_back_to_favicon():
    page = resp(text="<html></html>")
    ico = resp(content=b"ico", headers={})
    with patch("main.requests.get", side_effect=[page, ico]) as g:
        result = main.fetch_icon(ServiceConfig(name="a", url="http://svc.test"))
    assert result == ("image/x-icon", b"ico")
    assert g.call_args_list[1].args[0] == "http://svc.test/favicon.ico"


def test_fetch_icon_none_when_oversized_or_missing():
    big = resp(content=b"x" * (main.ICON_MAX_BYTES + 1), headers={"Content-Type": "image/png"})
    with patch("main.requests.get", side_effect=[resp(text=""), big]):
        assert main.fetch_icon(ServiceConfig(name="a", url="http://a")) is None


def test_icon_route(client):
    with patch("main.fetch_icon", return_value=("image/png", b"png")) as f:
        r = client.get("/icon/svc")
        client.get("/icon/svc")
    assert r.data == b"png" and r.content_type == "image/png"
    assert f.call_count == 1  # cached


def test_icon_route_missing(client):
    assert client.get("/icon/missing").status_code == 404
    with patch("main.fetch_icon", return_value=None):
        assert client.get("/icon/svc").status_code == 404
