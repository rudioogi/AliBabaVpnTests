"""oogi-vpn-updater: receives MikroTik public IP change events and updates
Alibaba customer gateway + tunnel remote-id accordingly."""

from __future__ import annotations

import ipaddress
import logging
import os
import re
import time
from functools import wraps

from flask import Flask, jsonify, request

import alibaba_client

app = Flask(__name__)
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger(__name__)

# Allow requests up to 60s old to tolerate MikroTik clock drift.
TIMESTAMP_TOLERANCE = 60
# Minimum seconds between successful updates (server-side rate limit).
RATE_LIMIT_SECONDS = 30

_last_update_time: float = 0.0


def _require_bearer(f):
    @wraps(f)
    def wrapper(*args, **kwargs):
        expected = os.environ.get("OOGI_SHARED_SECRET", "")
        auth = request.headers.get("Authorization", "")
        if not auth.startswith("Bearer ") or auth[7:] != expected:
            log.warning("Rejected request from %s: bad token", request.remote_addr)
            return jsonify({"status": "error", "reason": "unauthorized"}), 401
        return f(*args, **kwargs)
    return wrapper


@app.post("/update-vpn-ip")
@_require_bearer
def update_vpn_ip():
    global _last_update_time

    data = request.get_json(silent=True, force=True) or {}
    new_ip = data.get("newIp", "").strip()
    timestamp = data.get("timestamp")

    # Validate IP
    try:
        ipaddress.IPv4Address(new_ip)
    except ValueError:
        return jsonify({"status": "error", "reason": f"invalid IP: {new_ip}"}), 400

    # Validate timestamp (basic replay protection — requires NTP on MikroTik)
    if timestamp is not None:
        try:
            skew = abs(int(time.time()) - int(timestamp))
            if skew > TIMESTAMP_TOLERANCE:
                return jsonify({"status": "error", "reason": f"timestamp skew too large: {skew}s"}), 400
        except (ValueError, TypeError):
            return jsonify({"status": "error", "reason": "invalid timestamp"}), 400

    # Rate limit
    since_last = time.time() - _last_update_time
    if since_last < RATE_LIMIT_SECONDS:
        return jsonify({"status": "error", "reason": f"rate limited, retry in {int(RATE_LIMIT_SECONDS - since_last)}s"}), 429

    tunnel_id = os.environ["TUNNEL_ID"]
    cgw_name = f"mikrotik-factory-{int(time.time())}"

    log.info("Creating customer gateway: name=%s ip=%s", cgw_name, new_ip)
    try:
        new_cgw_id = alibaba_client.create_customer_gateway(cgw_name, new_ip)
    except Exception as e:
        log.error("CreateCustomerGateway failed: %s", e)
        return jsonify({"status": "error", "reason": f"CreateCustomerGateway failed: {e}"}), 502

    log.info("Modifying tunnel %s: cgw=%s remoteId=%s", tunnel_id, new_cgw_id, new_ip)
    try:
        alibaba_client.modify_tunnel_attribute(tunnel_id, new_cgw_id, new_ip)
    except Exception as e:
        log.error("ModifyTunnelAttribute failed: %s — new CGW %s left in place for manual cleanup", e, new_cgw_id)
        return jsonify({"status": "error", "reason": f"ModifyTunnelAttribute failed: {e}", "newCgwId": new_cgw_id}), 502

    _last_update_time = time.time()
    log.info("VPN IP update complete: newIp=%s newCgwId=%s tunnelId=%s", new_ip, new_cgw_id, tunnel_id)
    return jsonify({"status": "ok", "newCgwId": new_cgw_id, "tunnelId": tunnel_id}), 200


@app.get("/healthz")
def healthz():
    return jsonify({"status": "ok"}), 200
