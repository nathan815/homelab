import argparse
import re
from dataclasses import dataclass
from typing import List
from urllib.parse import urljoin
from flask import Flask, Response, render_template, redirect
import requests
import json


@dataclass
class ServiceConfig:
    name: str
    url: str
    check_url: str = None
    url_replacements: dict = None
    display_url_replacements: dict = None
    display_url: str = ""

    def __post_init__(self):
        self.display_url = self.url
        if self.display_url_replacements:
            for k, v in self.display_url_replacements.items():
                self.display_url = self.display_url.replace(k, v)

        if not self.check_url:
            self.check_url = self.url

        if self.url_replacements:
            for k, v in self.url_replacements.items():
                self.url = self.url.replace(k, v)
                self.check_url = self.check_url.replace(k, v)


@dataclass
class Config:
    services: List[ServiceConfig]


def parse_config(config: dict) -> Config:
    return Config(
        services=[
            ServiceConfig(
                **s,
                url_replacements=config.get("url_replacements"),
                display_url_replacements=config.get("display_url_replacements"),
            )
            for s in config["services"]
        ]
    )


def read_config(config_file: str) -> Config:
    with open(config_file) as f:
        config_json = json.load(f)
        return parse_config(config_json)


def check_service(service: ServiceConfig):
    url = service.check_url
    try:
        response = requests.get(url, verify=False, timeout=5)
        print("Service {url} status: {response.ok}".format(url=url, response=response))
        if not response.ok:
            print(response.status_code, response.content)
        return {
            "up": response.ok,
            "status_code": response.status_code,
            "url": url,
            "content": str(response.content),
        }
    except requests.RequestException as e:
        print("Failed to reach service {url}: {e}".format(url=url, e=e))
        status_code = e.response.status_code if e.response else None
        content = e.response.content if e.response else None
        return {
            "up": False,
            "status_code": status_code,
            "url": url,
            "error": str(e),
            "content": content,
        }


ICON_LINK_RE = re.compile(r"<link\b[^>]*>", re.IGNORECASE)
ICON_MAX_BYTES = 512 * 1024
icon_cache = {}


def fetch_icon(service: ServiceConfig):
    """Find a service's favicon: <link rel=icon> in its page, else /favicon.ico."""
    candidates = []
    try:
        page = requests.get(service.url, verify=False, timeout=5)
        for tag in ICON_LINK_RE.findall(page.text[:100_000]):
            rel = re.search(r'rel=["\']([^"\']*)["\']', tag, re.IGNORECASE)
            href = re.search(r'href=["\']([^"\']*)["\']', tag, re.IGNORECASE)
            if rel and href and "icon" in rel.group(1).lower():
                candidates.append(urljoin(page.url, href.group(1)))
    except requests.RequestException:
        pass
    candidates.append(urljoin(service.url, "/favicon.ico"))

    for url in candidates:
        try:
            r = requests.get(url, verify=False, timeout=5)
        except requests.RequestException:
            continue
        content_type = r.headers.get("Content-Type", "").split(";")[0].strip()
        if (
            r.ok
            and r.content
            and len(r.content) <= ICON_MAX_BYTES
            and (content_type.startswith("image/") or url.endswith(".ico"))
        ):
            return content_type or "image/x-icon", r.content
    return None


parser = argparse.ArgumentParser()
parser.add_argument("--config", default="config.json", help="Path to the config file")
parser.add_argument(
    "--debug", default=False, action="store_true", help="Run in debug mode"
)
args = parser.parse_args()
config = read_config(args.config)

app = Flask(__name__)


@app.route("/")
def home():
    return render_template("index.html.j2", services=config.services)

@app.errorhandler(404)
def page_not_found(e):
    return redirect('/', code=302)

@app.route("/ping")
def ping():
    return "Pong"


@app.route("/status/<name>")
def status(name):
    service = next((s for s in config.services if s.name == name), None)
    if not service:
        return "Service not found", 404
    return check_service(service)


@app.route("/icon/<name>")
def icon(name):
    service = next((s for s in config.services if s.name == name), None)
    if not service:
        return "Service not found", 404
    if name not in icon_cache:
        icon_cache[name] = fetch_icon(service)
    cached = icon_cache[name]
    if not cached:
        return "No icon", 404
    content_type, data = cached
    return Response(
        data, content_type=content_type, headers={"Cache-Control": "max-age=86400"}
    )


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=80, debug=args.debug)
