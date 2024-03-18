import argparse
from dataclasses import dataclass
from typing import List
from flask import Flask, render_template
import requests
import json

app = Flask(__name__)

parser = argparse.ArgumentParser()
parser.add_argument('--config', default='config.json', help='Path to the config file')
parser.add_argument('--debug', default=False, action='store_true', help='Run in debug mode')
args = parser.parse_args()

@dataclass
class ServiceConfig:
    name: str
    url: str
    check_url: str = None

    @property
    def url_short(self):
        return self.url.replace('http://', '').replace('https://', '')

@dataclass
class Config:
    services: List[ServiceConfig]

with open(args.config) as f:
    config_json = json.load(f)
    config = Config(
        services=[ServiceConfig(**s) for s in config_json['services']]
    )

def check_service(service: ServiceConfig):
    url = service.check_url if service.check_url else service.url
    try:
        response = requests.get(url, verify=False, timeout=5)
        print('Service {url} status: {response.ok}'.format(url=url, response=response))
        if not response.ok:
            print(response.status_code, response.content)
        return {
            'up': response.ok,
            'status_code': response.status_code
        }
    except requests.ConnectionError as e:
        print('Failed to reach service {url}: {e}'.format(url=url, e=e))
        return {
            'up': False,
            'status_code': None
        }

@app.route('/')
def home():
    return render_template('index.html.j2', services=config.services)

@app.route('/status/<name>')
def status(name):
    service = next((s for s in config.services if s.name == name), None)
    if not service:
        return 'Service not found', 404
    return check_service(service)

if __name__ == '__main__':
    app.run(host="0.0.0.0", port=80, debug=args.debug)
