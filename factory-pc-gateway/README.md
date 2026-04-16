# Factory PC Gateway — Android Device Testing

Use the factory Windows PC as a WiFi gateway for Android devices, routing all
Azure service traffic through the Alibaba Cloud VPN + nginx proxy chain.

No per-device configuration required — devices just connect to the WiFi hotspot.

```
[Android OogiCam device]
    │  connects to Windows Mobile Hotspot WiFi
    │  DHCP assigns 192.168.137.1 as DNS + gateway (automatic)
    ▼
[Factory Windows PC — 192.168.137.1]
    │  Windows hosts file → Azure domains resolve to 192.168.137.1
    │  nginx stream proxy → TCP passthrough on 443, 8883, 1433
    │  forwards through Alibaba SSL VPN to China ECS private IP
    ▼
[China ECS — 10.2.0.100 (nginx TCP passthrough)]
    │  Port 443  → 10.1.1.96:443
    │  Port 8883 → 10.1.1.96:8883
    │  Port 1433 → 10.1.1.96:1433
    │
    │  CEN (Alibaba licensed cross-border link)
    ▼
[US ECS — 10.1.1.96 (nginx TCP passthrough)]
    │
    ▼
[Azure: API · IoT Hub · SQL Server · Storage · Streaming]
```

**Why this works for custom Android 9 (no GMS):**
- No Google Play Services = no Google DNS bypass
- No Chrome DoH = no DNS-over-HTTPS to Google
- Standard Android DNS resolver respects DHCP-assigned DNS
- Windows Mobile Hotspot automatically assigns itself (192.168.137.1) as DNS
- The factory PC hosts file controls name resolution for all connected devices

**No TLS is broken.** The nginx proxies do TCP passthrough — the TLS handshake
goes end-to-end between the Android device and Azure. Azure's real certificates
are validated by the device. No custom CA needed.

---

## Prerequisites

| What | Status |
|------|--------|
| Factory PC connected to Alibaba SSL VPN | OpenVPN showing connected, 172.16.100.x IP |
| nginx for Windows downloaded | Extract to `factory-pc-gateway\nginx\` (see below) |
| `setup-gateway.bat` configured | CHINA_ECS_IP set to your China ECS private IP |

### Download nginx for Windows

Download the stable Windows zip from `nginx.org/en/download.html` and extract
the contents so that `nginx.exe` is at:

```
factory-pc-gateway\
├── nginx\
│   ├── nginx.exe
│   ├── conf\          ← setup-gateway.bat generates nginx.conf here
│   └── ...
├── setup-gateway.bat
├── verify-gateway.bat
├── teardown-gateway.bat
└── README.md
```

---

## Quick Start

### 1. Configure

Edit `setup-gateway.bat` — change line 17:

```batch
set CHINA_ECS_IP=10.2.0.100
```

Replace `10.2.0.100` with your actual China ECS private VPC IP.

### 2. Setup

Run **as Administrator**:

```cmd
setup-gateway.bat
```

This will:
- Generate the nginx config pointing to your China ECS
- Start nginx listening on 192.168.137.1 (ports 443, 8883, 1433)
- Add Azure hostname entries to the Windows hosts file
- Flush DNS cache

### 3. Enable Mobile Hotspot

Windows Settings → Network & Internet → Mobile Hotspot → **Turn on**

Note the hotspot SSID and password.

### 4. Connect Android Device

On the Android device:
- Settings → WiFi → connect to the hotspot SSID
- That's it — no other device configuration needed

### 5. Verify

Run:

```cmd
verify-gateway.bat
```

This checks: VPN connected, nginx running, ports listening, DNS resolving, TCP
connectivity through the proxy chain.

### 6. Test

Run the OogiCam app on the Android device. The app's connections to:
- `api.oogiservices.net` → port 443 → factory PC → VPN → China ECS → CEN → Azure API
- `synap-iot-production.azure-devices.net` → port 8883 → same chain → Azure IoT Hub
- `streaming.oogiservices.net` → port 443 → same chain → streaming server

All resolved via the factory PC's DNS, proxied through nginx, tunneled through VPN.

### 7. Teardown (after testing)

Run **as Administrator**:

```cmd
teardown-gateway.bat
```

This stops nginx, removes hosts file entries, flushes DNS. Turn off Mobile
Hotspot manually.

---

## How It Works — Step by Step

### DNS Resolution

1. Android device connects to Windows Mobile Hotspot
2. Windows DHCP assigns `192.168.137.x` IP to device, `192.168.137.1` as DNS
3. Device app resolves `api.oogiservices.net`
4. DNS query goes to `192.168.137.1` (factory PC)
5. Windows checks its hosts file → finds `192.168.137.1 api.oogiservices.net`
6. Returns `192.168.137.1` to the device

### Traffic Routing

7. Device opens TCP connection to `192.168.137.1:443`
8. nginx on factory PC accepts the connection
9. nginx opens upstream connection to `10.2.0.100:443` (China ECS via VPN)
10. China ECS nginx forwards to `10.1.1.96:443` (US ECS via CEN)
11. US ECS nginx forwards to Azure
12. TLS handshake completes end-to-end (device ↔ Azure)
13. Device validates Azure's real TLS certificate — no custom CA needed

### Why DNS Works Without Extra Software

Windows Mobile Hotspot uses ICS (Internet Connection Sharing) internally. The ICS
DHCP server always assigns `192.168.137.1` as both the default gateway and the DNS
server. When Windows receives a DNS query on its ICS interface, it resolves it using
its own resolver — which checks the hosts file first. This means the hosts file
entries added by `setup-gateway.bat` apply to all devices on the hotspot.

No Acrylic DNS, no dnsmasq, no extra DNS software needed.

---

## Troubleshooting

### Device can't connect to WiFi hotspot

- Is Mobile Hotspot turned on?
- Is the device within range?
- Try toggling hotspot off and on
- Check Windows: Settings → Network → Mobile Hotspot → max devices not exceeded

### Device connects but app can't reach API

1. **Check VPN is connected**: `ipconfig | findstr 172.16.100`
2. **Check nginx is running**: `tasklist | findstr nginx`
3. **Check nginx is listening**: `netstat -an | findstr 192.168.137.1`
4. **Check hosts file**: `findstr oogiservices %SystemRoot%\System32\drivers\etc\hosts`
5. **Test from factory PC itself**: `curl.exe -v https://api.oogiservices.net/swagger/index.html`

### IoT Hub connects but API doesn't (or vice versa)

Different ports use different proxy paths. Check each independently:

| Service | Port | Check nginx | Check CEN |
|---------|------|-------------|-----------|
| API/HTTPS | 443 | `netstat -an \| findstr 192.168.137.1:443` | SSH to China ECS: `nc -zv 10.1.1.96 443` |
| IoT Hub | 8883 | `netstat -an \| findstr 192.168.137.1:8883` | SSH to China ECS: `nc -zv 10.1.1.96 8883` |
| SQL | 1433 | `netstat -an \| findstr 192.168.137.1:1433` | SSH to China ECS: `nc -zv 10.1.1.96 1433` |

### DNS not working — device resolves real Azure IP

This means the device is not using the hotspot DNS. Check:
- Is the device connected to the hotspot WiFi (not mobile data or another WiFi)?
- Settings → Network → Private DNS → set to **Off**
- If the device has a static DNS configured, remove it

### nginx error: "bind() to 192.168.137.1:443 failed"

- Mobile Hotspot must be enabled BEFORE starting nginx (the IP doesn't exist until
  the hotspot is on)
- Another process is using port 443 on that IP — check with `netstat -an | findstr :443`

### nginx error: "host not found" for upstream

- The CHINA_ECS_IP in the nginx config is an IP address, not a hostname — it should
  not need DNS resolution
- Check the VPN is connected and the China ECS IP is reachable: `ping 10.2.0.100`

---

## Upgrading to OpenWrt Router

When the dedicated QA router arrives, the factory PC gateway is no longer needed.
The router replaces the factory PC's role entirely:

| Factory PC Gateway | OpenWrt Router |
|---|---|
| Windows Mobile Hotspot | Router WiFi AP |
| Windows hosts file | dnsmasq `address=` entries |
| nginx for Windows | Not needed (router routes via VPN directly) |
| OpenVPN on Windows | OpenVPN on router |
| Per-session setup/teardown | Always on, zero maintenance |

See `docs/china-qa-vpn-setup.md` in the OogiCam repo for the VPN architecture
overview and `docs/china-qa-wireguard-setup.md` for the OpenWrt router setup
(to be updated when the router arrives).
