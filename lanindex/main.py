import argparse
from dataclasses import dataclass
from typing import List
from flask import Flask, render_template
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

        if self.url_replacements:
            for k, v in self.url_replacements.items():
                self.url = self.url.replace(k, v)


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
    url = service.check_url if service.check_url else service.url
    try:
        response = requests.get(url, verify=False, timeout=5)
        print("Service {url} status: {response.ok}".format(url=url, response=response))
        if not response.ok:
            print(response.status_code, response.content)
        return {"up": response.ok, "status_code": response.status_code}
    except requests.ConnectionError as e:
        print("Failed to reach service {url}: {e}".format(url=url, e=e))
        return {"up": False, "status_code": None}


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


@app.route("/ping")
def ping():
    return "Pong"


@app.route("/status/<name>")
def status(name):
    service = next((s for s in config.services if s.name == name), None)
    if not service:
        return "Service not found", 404
    return check_service(service)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=80, debug=args.debug)
