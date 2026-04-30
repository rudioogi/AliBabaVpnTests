# Automated IPsec Recovery on Public IP Change

## How It Works

```
MikroTik scheduler (every 5 min)
    └─ check-public-ip script
           │
           ├─ :resolve myip.opendns.com @208.67.222.222 (bypasses IPsec tunnel)
           │
           ├─ unchanged → exit quietly
           │
           └─ changed → POST https://120.79.157.95:8444/update-vpn-ip
                                │
                                ├─ CreateCustomerGateway (new IP, or reuse existing)
                                ├─ ModifyTunnelAttribute (tun-wz9gip67wfcp1ro8x3ffu)
                                │     └─ CustomerGatewayId = new/existing CGW
                                │     └─ TunnelIkeConfig.RemoteId = new IP
                                └─ return {"status":"ok","newCgwId":"..."}
                                │
                         MikroTik (on ok):
                                ├─ /ip ipsec identity set my-id=address:<newIp>
                                └─ /ip ipsec installed-sa flush
                                     └─ IKEv2 re-negotiation begins (~5-15s)
```

## Infrastructure

| Component | Value |
|---|---|
| MikroTik LAN IP | 192.168.88.1 |
| MikroTik WAN IP | 192.168.5.71 |
| Public NAT IP | 223.73.2.155 |
| Alibaba VPN Gateway | 39.108.115.199 |
| China ECS | 120.79.157.95 |
| Tunnel ID | tun-wz9gip67wfcp1ro8x3ffu |
| VPN Connection ID | vco-wz9vhc7agvvp9sop9k7vt |
| Alibaba Region | cn-shenzhen |

## Setup

### 1. China ECS — vpn-updater service

See `china-ecs/vpn-updater/INSTALL.md` for full steps. Key points:

- nginx must include conf.d in the http block — add to `/etc/nginx/nginx.conf`:
  ```nginx
  http {
      include /etc/nginx/conf.d/*.conf;
      ...
  }
  ```
- Copy `china-ecs/vpn-updater/nginx-vpn-updater.conf` to `/etc/nginx/conf.d/vpn-updater.conf`
- Credentials at `/etc/oogi-vpn-updater/credentials` must include `VPN_CONNECTION_ID`

### 2. MikroTik — load the script

In Winbox: **System → Scripts → check-public-ip** → paste contents of `mikrotik/check-public-ip.rsc` into Source field → OK.

> Note: load via Winbox editor paste, not file import. File-based loading has had reliability issues.

Verify script is valid (no `I` flag):
```
/system script print where name="check-public-ip"
```

### 3. MikroTik — install scheduler

Run `configure-ip-monitor.rsc` once (handles bypass policies + scheduler):
```
/import file-name=configure-ip-monitor.rsc
```

Or manually:
```
/system scheduler add name="oogi-public-ip-check" interval=5m on-event="/system script run check-public-ip" start-time=startup
```

## Manual Override

If the automation fails, recover manually:

**On MikroTik:**
```
/ip ipsec identity set [find peer=alibaba-peer] my-id=address:<NEW_IP>
/ip ipsec installed-sa flush
```

**On China ECS (or Alibaba console):**
1. Create customer gateway with new IP
2. ModifyTunnelAttribute on `tun-wz9gip67wfcp1ro8x3ffu` — set new CGW + RemoteID

## Checking Status

**MikroTik logs:**
```
/log print where message~"oogi-vpn"
```

**Verify tunnel recovered:**
```
/ip ipsec active-peers print
```

**Force a test run (clears stored IP to trigger update):**
```
/system script set [find name="oogi-last-public-ip"] source=""
/system script run check-public-ip
/log print where message~"oogi-vpn"
```

**Check updater service on China ECS:**
```bash
sudo systemctl status oogi-vpn-updater
sudo journalctl -u oogi-vpn-updater -n 50 --no-pager
```

## Rotating the Shared Secret

1. Generate new secret: `python3 -c "import secrets; print(secrets.token_hex(32))"`
2. Update `OOGI_SHARED_SECRET` in `/etc/oogi-vpn-updater/credentials` on China ECS → `sudo systemctl restart oogi-vpn-updater`
3. Update `sharedSecret` in `mikrotik/check-public-ip.rsc` and reload via Winbox

## Old Customer Gateways

Old CGWs are intentionally not deleted automatically (rollback option). Clean them up via
Alibaba Console → VPN Gateway → Customer Gateways. The naming pattern is `mikrotik-factory-<unixts>`.

## IPsec Bypass Policies Required

These bypass policies must be in place (configured by `configure-ip-monitor.rsc`):

| Destination | Purpose |
|---|---|
| `208.67.222.222/32` | OpenDNS resolver — IP detection |
| `208.67.220.220/32` | OpenDNS resolver — fallback |
| `120.79.157.95/32` | China ECS public — HTTPS update call |

Without these, monitor traffic goes through the (broken) IPsec tunnel and the recovery loop never fires.
