import os
from flask import Flask, render_template, jsonify
import routeros_api

app = Flask(__name__)

username = os.getenv("ROUTER_USERNAME")
password = os.getenv("ROUTER_PASSWORD")


def get_dhcp_leases():
    connection = routeros_api.RouterOsApiPool(
        "router.lan", username=username, password=password, plaintext_login=True
    )
    api = connection.get_api()
    leases = api.get_resource("/ip/dhcp-server/lease").get()
    connection.disconnect()
    return leases


@app.route("/")
def page_index():
    return render_template("index.html")


@app.route("/devices")
def page_devices():
    return render_template("devices.html")


@app.route("/api/leases")
def api_leases():
    leases = get_dhcp_leases()
    return jsonify(leases)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5001, debug=True)
