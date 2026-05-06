# OogiCam China Factory QA — Network Architecture

## Overview

Android test devices in a China factory cannot reach Azure directly due to the Great Firewall
and regulatory restrictions on cross-border internet traffic. This system routes all device
traffic through a licensed path: MikroTik router → Alibaba IPsec VPN → China ECS (nginx proxy)
→ Alibaba CEN (private cross-border link) → US ECS (nginx proxy) → Azure.

---

## Network Topology

```
[Android devices — 192.168.88.x]
        │  WiFi: Synap_2.4G
        │
[Factory WiFi AP]
        │  Ethernet → ether3 (MikroTik bridge port)
        │
[MikroTik hEX — RouterOS 7.16.1]
   LAN bridge : ether2–5, IP 192.168.88.1/24
   WAN        : ether1,   IP 192.168.5.71 (factory NAT)
   Public NAT : 223.73.2.164
        │
        │  IPsec IKEv2 tunnel  (traffic selectors 0.0.0.0/0 ↔ 0.0.0.0/0)
        │
[Alibaba VPN Gateway 2.0 — 39.108.115.199]
        │
[Alibaba VPC — 10.2.0.0/16  (China region)]
   China ECS : 10.2.0.100  (public: 120.79.157.95)
   nginx stream proxy — see china-ecs/nginx.conf
        │
        │  CEN (Alibaba Cloud Enterprise Network — licensed private cross-border link)
        │  *** NOT the public internet — bypasses GFW ***
        │
[Alibaba VPC — 10.1.0.0/16  (US region)]
   US ECS    : 10.1.1.96
   nginx stream proxy — see us-ecs/nginx.conf
        │
        ├── TCP 443  → api.oogiservices.net             (Azure App Service)
        ├── TCP 1433 → oogi-aim-management.database.windows.net
        ├── TCP 8883 → synap-iot-production.azure-devices.net
        ├── TCP 8086 → metrics.oogiservices.net
        ├── UDP 1194 → vpn-au / vpn-au2                (Azure OpenVPN servers)
        └── UDP 500/4500 → Azure VPN Gateway

[Azure — australiasoutheast / USA]
   vpn-au  : 4.198.127.118   (OpenVPN server, private 172.23.0.5, UDP 1194)
   vpn-au2 : 23.101.231.126  (OpenVPN server, UDP 1194)
   Azure VPN Gateway: azuregateway-857e0077-c9da-4129-a201-709895d85810-c11bb0dae7e3.vpn.azure.com
```

---

## Why CEN, Not the Public Internet

The Great Firewall (GFW) aggressively blocks outbound UDP on port 1194 (OpenVPN) from China
to overseas IPs. Any direct China ECS → Azure connection on UDP 1194 is silently dropped.

Alibaba CEN is a licensed private cross-border link that bypasses GFW entirely. All traffic
from China ECS to US ECS travels via CEN. US ECS then reaches Azure over the unrestricted
US internet.

**Critical rule:** All `proxy_pass` targets in China ECS nginx must point to US ECS private
IP (`10.1.1.96`), never directly to Azure public IPs.

---

## Traffic Flows

### App traffic (HTTPS, MQTT, SQL, Metrics)
```
Android → MikroTik (IPsec) → Alibaba VPN GW → China ECS :443/:1433/:8883/:8086
→ CEN → US ECS → Azure (app services)
```

DNS: MikroTik resolves all Azure hostnames to `10.2.0.100` (China ECS). Android never
sees a real Azure IP — all connections land on the China ECS nginx, which proxies via CEN.

### OpenVPN tunnel (Android → Azure)
```
Android → MikroTik (IPsec) → Alibaba VPN GW → China ECS :1194 UDP
→ CEN → US ECS :1194 UDP → Azure vpn-au/vpn-au2 :1194 UDP
```

### Azure VPN Gateway (IKEv2 — if used)
```
Android → MikroTik (IPsec) → Alibaba VPN GW → China ECS :500/:4500 UDP
→ CEN → US ECS :500/:4500 UDP → Azure VPN Gateway
```

---

## Component Configuration

### 1. MikroTik hEX Router

**Scripts:** `mikrotik/configure-ipsec.rsc` then `mikrotik/configure-gateway.rsc`

Run in order via Winbox → Files → Import:
```
/import file=configure-ipsec.rsc
/import file=configure-gateway.rsc
```

**IPsec (configure-ipsec.rsc):**

| Parameter | Value |
|-----------|-------|
| Mode | IKEv2 |
| Peer address | 39.108.115.199/32 (Alibaba VPN Gateway) |
| Local address | 192.168.5.71 (MikroTik WAN) |
| my-id | address:223.73.2.164 (public NAT IP) |
| remote-id | address:39.108.115.199 |
| Phase 1 enc | AES-128, SHA1, MODP1024, lifetime 24h |
| Phase 2 enc | AES-128-CBC, SHA1, MODP1024, lifetime 24h |
| Traffic selectors | 0.0.0.0/0 ↔ 0.0.0.0/0 (required by Alibaba VPN GW 2.0) |
| PSK | Oogi12345 |

**Policy table (order matters):**
```
1. src=0.0.0.0/0  dst=192.168.88.0/24    action=none    ← bypass: LAN return traffic
2. src=0.0.0.0/0  dst=114.114.114.114/32 action=none    ← bypass: DNS upstream
3. src=0.0.0.0/0  dst=154.0.7.222/32     action=none    ← bypass: RustDesk SA server
4. src=0.0.0.0/0  dst=0.0.0.0/0          action=encrypt ← encrypt: everything else
```

**Why bypass policies use `src=0.0.0.0/0`:** RouterOS runs srcnat (masquerade) **before**
IPsec policy lookup. By the time IPsec evaluates the packet, the source is already the WAN
IP (`192.168.5.71`), not the original LAN client IP. Using the LAN subnet as src would never
match.

**Why DNS needs a bypass:** MikroTik's own DNS resolver queries use `src=192.168.5.71`
(WAN IP), which is outside the Alibaba SNAT range (`192.168.88.0/24`). Without the bypass,
DNS queries go into the tunnel but are dropped by Alibaba — causing all general internet DNS
to fail for LAN clients. Android is unaffected because all its hostnames are in the local
overrides and never forwarded upstream.

**DNS overrides (configure-gateway.rsc):** All of the following resolve to `10.2.0.100`:
- `api.oogiservices.net`
- `storage.oogiservices.net`
- `streaming.oogiservices.net`
- `streaming-za.oogiservices.net`
- `metrics.oogiservices.net`
- `synap-iot-production.azure-devices.net`
- `staging-synapinc-iothub.azure-devices.net`
- `oogi-aim-management.database.windows.net`
- `connectivitycheck.gstatic.com`
- `www.msftconnecttest.com` ← Windows NCSI connectivity check
- `vpnau.oogiservices.net`
- `vpnau2.oogiservices.net`
- `azuregateway-857e0077-c9da-4129-a201-709895d85810-c11bb0dae7e3.vpn.azure.com`

Special DNS entry (not proxied, direct IP):
- `dns.msftncsi.com` → `131.107.255.255` (Windows NCSI DNS check)

**Bridge settings required for IPsec forwarding:**

| Setting | Value | Why |
|---------|-------|-----|
| `ip settings allow-fast-path` | no | FastPath bypasses firewall/routing |
| `interface bridge settings use-ip-firewall` | yes | Without this, bridge traffic skips IP stack |
| `interface bridge fast-forward` | no | Shortcut bypasses IP routing |
| `interface bridge port hw` (ether2–5) | no | HW offload bypasses CPU/IP stack |

**DHCP:** Pushes `gateway=192.168.88.1` and `dns-server=192.168.88.1` to all LAN clients.

**Known issue — Android 9 DHCP gateway:**
Android 9 devices may not apply the DHCP gateway. Workaround: set static IP on the device
(Settings → WiFi → Modify → Static IP, gateway=192.168.88.1), or:
```bash
adb shell ip route add default via 192.168.88.1 dev wlan0
```

---

### 2. Alibaba Setup

See `ALIBABA_SETUP.md` for the full step-by-step Alibaba Console guide.

Summary:
- VPN Gateway 2.0 in China VPC, connected to customer gateway `223.73.2.164`
- Route: `192.168.88.0/24` → IPsec connection, published to VPC
- NAT Gateway: SNAT for `192.168.88.0/24` (allows factory LAN devices to reach internet)
- CEN: connects China VPC (`10.2.0.0/16`) to US VPC (`10.1.0.0/16`)

---

### 3. China ECS — nginx Stream Proxy

**Host:** `10.2.0.100` (public: `120.79.157.95`)
**Config:** `china-ecs/nginx.conf`

| Port | Protocol | Destination | Notes |
|------|----------|-------------|-------|
| 443 | TCP | `10.1.1.96:443` (default) | ssl_preread routes by SNI; connectivity check hostnames → local |
| 1194 | UDP | `10.1.1.96:1194` | **Must go to US ECS via CEN — not directly to Azure** |
| 1433 | TCP | `10.1.1.96:1433` | |
| 8883 | TCP | `10.1.1.96:8883` | |
| 8086 | TCP | `10.1.1.96:8086` | |
| 500 | UDP | `10.1.1.96:500` | IKE |
| 4500 | UDP | `10.1.1.96:4500` | IKE NAT-T |
| 80 | TCP | local (204) | Android connectivity check |
| 8443 | TCP | local SSL (204) | Android connectivity check (HTTPS) |

**SNI routing on port 443:**
- `connectivitycheck.gstatic.com` → local (returns 204, satisfies Android WiFi check)
- `clients3.google.com` → local
- `azuregateway-*.vpn.azure.com` → `13.68.128.105:443` (Azure VPN Gateway)
- default → `10.1.1.96:443` (US ECS)

---

### 4. US ECS — nginx Stream Proxy

**Host:** `10.1.1.96`
**Config:** `us-ecs/nginx.conf`

| Port | Protocol | Destination |
|------|----------|-------------|
| 443 | TCP | `api.oogiservices.net:443` |
| 1433 | TCP | `oogi-aim-management.database.windows.net:1433` |
| 8883 | TCP | `synap-iot-production.azure-devices.net:8883` |
| 8086 | TCP | `metrics.oogiservices.net:8086` |
| 1194 | UDP | `vpn_backends` (load balanced: `4.198.127.118`, `23.101.231.126`) |
| 500 | UDP | `azuregateway-*.vpn.azure.com:500` |
| 4500 | UDP | `azuregateway-*.vpn.azure.com:4500` |

OpenVPN backend uses `hash $remote_addr consistent` for session stickiness (required for UDP).

---

### 5. Azure OpenVPN Server (vpn-au)

| Parameter | Value |
|-----------|-------|
| VM name | vpn-au |
| Resource group | synap-infrastructure-production |
| Public IP | 4.198.127.118 (vpn-au-ip) |
| Private IP | 172.23.0.5 (eth0) |
| Region | australiasoutheast |
| Protocol | UDP 1194 |
| Config | /etc/openvpn/server/server.conf |
| Status log | /etc/openvpn/server/openvpn-status.log |
| VPN subnet | 10.11.0.0/18 (tun0) |
| NSG | vpn-au-nsg (allows UDP 1194 from * at priority 310) |

Second server: `vpn-au2` at `23.101.231.126:1194`

---

## Alibaba VPN Gateway — Known Quirks

1. **Traffic selectors must be `0.0.0.0/0`** — Narrowing to `192.168.88.0/24 → 10.2.0.0/16`
   causes `TS_UNACCEPTABLE`. Verified by test.

2. **`my-id` / `remote-id` required** — MikroTik is behind NAT. Without explicit IDs,
   IKE sends the private WAN IP as identity → Alibaba rejects with `AUTHENTICATION_FAILED`.

3. **`local-address=192.168.5.71` required on peer** — Without it, `sa-src-address=0.0.0.0`
   and IKE is never initiated.

4. **Destination-based route on Alibaba VPN Gateway** — `192.168.88.0/24 → IPsec connection`
   with "Publish to VPC" enabled. Required for return path from ECS back to LAN clients.

5. **NAT Gateway SNAT for `192.168.88.0/24`** — Allows factory LAN devices to reach internet
   (e.g., `ping 8.8.8.8`) via Alibaba.

6. **Customer gateway public IP** — Assigned by the factory ISP and **can rotate** without notice. Currently `223.73.2.155`. Symptom of a stale IP: `AUTHENTICATION_FAILED` in MikroTik IPsec logs with `ph2-state=no-phase2`.

   **Recovery is automated** — see `IP_RECOVERY.md`. A scheduler task on MikroTik polls the public IP every 5 minutes via OpenDNS. On change it calls `https://vpn-updater.oogiservices.net/update-vpn-ip` (China ECS), which creates a new Alibaba customer gateway and updates the tunnel RemoteID. MikroTik then updates its local `my-id` and flushes the SAs. Manual intervention is only needed if the automation itself fails.

   IP change history: `223.73.2.134` → `223.73.2.164` (2026-04-28) → `223.73.2.155` (2026-04-30).

7. **IPsec bypass policy for LAN return traffic** — Because traffic selectors are `0.0.0.0/0`,
   return traffic to LAN clients matches the encrypt policy. A `dst=192.168.88.0/24 action=none`
   policy placed before the encrypt policy is mandatory.

8. **`in-template-mismatches` counter** — Alibaba VPN Gateway sends keepalive probes using
   LAN addresses as inner IPs. These appear as `in:ether1 out:ether1` in the forward chain.
   Harmless — do not suppress.

---

## Windows PCs on the MikroTik AP

Windows PCs connected to the MikroTik AP work identically to Android devices for Azure
services — DNS overrides resolve all Azure hostnames to `10.2.0.100`, traffic goes through
the IPsec tunnel and proxy chain automatically. No per-PC configuration required.

### Remote Access (RustDesk)

RustDesk server runs on a Raspberry Pi in South Africa (`154.0.7.222`). The China PC's
RustDesk traffic is bypassed from the IPsec tunnel and routed directly out ether1 (factory
internet) to the SA Pi.

**RustDesk client config (on each PC):**
- ID Server: `154.0.7.222`
- Relay Server: `154.0.7.222`
- Key: contents of `~/rustdesk/data/id_ed25519.pub` on the Pi

**Pi setup:** `rustdesk-compose/docker-compose.yml` — run `docker compose up -d`

**SA router port forwarding (TP-Link Archer C5 → Pi at `192.168.1.126`):**

| Port | Protocol |
|------|----------|
| 21115 | TCP |
| 21116 | TCP + UDP |
| 21117 | TCP |

### Split-Tunneling Implementation

To add bypass for additional direct-internet destinations (e.g. AnyDesk relay IPs):

```
/ip ipsec policy add src-address=0.0.0.0/0 dst-address=<IP>/32 action=none \
    comment="bypass: <service>" place-before=[/ip ipsec policy find action=encrypt]
```

**Critical:** `src-address` must be `0.0.0.0/0`, NOT the LAN subnet (`192.168.88.0/24`).
RouterOS runs `srcnat` (masquerade) **before** IPsec policy lookup. By the time IPsec
evaluates the packet, the source IP is already the WAN IP (`192.168.5.71`), not the
original LAN client IP. Using the LAN subnet as src would never match.

### Forward Chain Rule

A firewall forward rule is required to allow new LAN→WAN connections for bypassed traffic:

```
chain=forward connection-state=new in-interface-list=LAN out-interface-list=WAN action=accept
```

IPsec-encrypted traffic (Android → Azure) is accepted by the existing `ipsec-policy=out,ipsec`
rule and is unaffected by this change.

---

## Critical Safety Rules

**MikroTik remote access:** User is in South Africa; router is in China. Lockout requires
physical factory intervention (reset button). Always use safe-mode (`Ctrl+X` in terminal)
for risky changes — auto-reverts if connection drops within ~9 minutes.

Never touch: bridge enable/disable, ether1 config, firewall rules blocking Winbox port 8291,
`/system reset-configuration`.

**Factory PC AnyDesk:** Rides the factory PC's WiFi (192.168.5.x). Never disable WiFi,
lower Ethernet metric below WiFi, or run `ipconfig /renew` on the Ethernet adapter —
any of these drops the AnyDesk session.

---

## Diagnostic Commands

### MikroTik
```
/ip ipsec active-peers print
/ip ipsec installed-sa print
/ip ipsec statistics print
/ping 10.2.0.100 src-address=192.168.88.1
/ping 8.8.8.8 src-address=192.168.88.1
/ip firewall filter print terse
/ip firewall nat print terse
/interface bridge port print detail
/ip dhcp-server network print detail
/ip dhcp-server lease print
```

### China ECS

> **pip installs on China ECS:** Always use Alibaba's PyPI mirror — direct PyPI is slow and
> prone to dropped connections from China.
> `pip install -i https://mirrors.aliyun.com/pypi/simple/ <packages>`

```bash
sudo tcpdump -n -i any udp port 1194          # verify Android packets arriving + forwarding
sudo nginx -t && sudo systemctl reload nginx   # after config changes
sudo systemctl status nginx
```

### US ECS
```bash
sudo tcpdump -n -i any udp port 1194          # verify packets arriving from China ECS
sudo tcpdump -n -i any host 4.198.127.118     # verify packets reaching Azure
```

### Azure VM (vpn-au)
```bash
sudo tcpdump -n -i any udp port 1194          # verify packets arriving from US ECS
sudo grep '^CLIENT_LIST' /etc/openvpn/server/openvpn-status.log   # connected clients
sudo systemctl status openvpn-server@server
```

---

## Setup Order (fresh deployment)

1. Configure Alibaba VPN Gateway (see `ALIBABA_SETUP.md`)
2. Import `mikrotik/configure-ipsec.rsc` — verify SA established
3. Import `mikrotik/configure-gateway.rsc` — verify DNS and DHCP
4. Deploy `china-ecs/nginx.conf` to China ECS — reload nginx
5. Deploy `us-ecs/nginx.conf` to US ECS — reload nginx
6. Test connectivity from Android device
