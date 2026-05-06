# OogiCam China Factory QA — Network Setup Status

## Goal
Route Android test devices (manufactured in China factory) through a China ECS proxy to reach Azure services (OogiCam backend). Devices connect to factory WiFi AP (`Synap_2.4G`), traffic goes MikroTik → IPsec tunnel → Alibaba ECS → Azure USA.

---

## Network Topology

```
[Android devices]
      │ WiFi: Synap_2.4G (192.168.88.0/24)
      │
[Synap WiFi AP]
      │ Ethernet → ether3 (MikroTik bridge port)
      │
[MikroTik hEX — RouterOS 7.16.1]
  LAN bridge: ether2-5, bridge IP 192.168.88.1
  WAN: ether1, IP 192.168.5.71 (factory NAT)
  Public NAT IP: 223.73.2.164
      │
      │ IPsec IKEv2 tunnel (0.0.0.0/0 → 0.0.0.0/0)
      │
[Alibaba VPN Gateway 2.0 — 39.108.115.199]
      │
[Alibaba VPC / ECS — 10.2.0.0/16]
  China ECS proxy: 10.2.0.100
      │ nginx reverse proxy
      │
[Azure Services — USA]
  api.oogiservices.net, storage, streaming, IoT Hub, etc.
```

---

## Factory PC (Windows — on factory LAN)
- Connected via **Ethernet** to MikroTik LAN (gets 192.168.88.x via DHCP)
- Connected via **WiFi** to factory network (192.168.5.x, gateway 192.168.5.1)
- User in South Africa remotes into this PC via AnyDesk (AnyDesk rides WiFi — never touch WiFi or its default route)
- Winbox manages MikroTik over Ethernet (192.168.88.x)
- WiFi is the AnyDesk path; Ethernet is the MikroTik management path

---

## What Is Working

### IPsec Tunnel
- SA established: `active-peers print` shows `established`
- Two SAs installed with `SE` flags (seen-traffic both directions)
- Phase 1: AES-128, SHA1, MODP1024, IKEv2, lifetime 24h
- Phase 2: AES-128-CBC, SHA1, MODP1024, lifetime 24h
- PSK: `Oogi12345`

### MikroTik-originated traffic
- `ping 10.2.0.100 src-address=192.168.88.1` → replies ✓
- `ping 8.8.8.8 src-address=192.168.88.1` → replies ✓ (Alibaba SNAT added for 192.168.88.0/24)

### LAN client forwarding ✓ (FIXED 2026-04-21)
- Android (192.168.88.253) pings 192.168.88.1 (MikroTik) ✓
- Android (192.168.88.253) pings 8.8.8.8 via IPsec tunnel ✓
- Full path confirmed: Android → bridge → IPsec → Alibaba → internet

### DNS
- MikroTik DNS overrides resolve all OogiCam hostnames to `10.2.0.100`
- `allow-remote-requests=yes` enabled
- DHCP pushes `gateway=192.168.88.1` and `dns-server=192.168.88.1` to LAN clients

---

## Root Causes Found and Fixed (2026-04-21)

Four issues were blocking LAN client forwarding through the IPsec tunnel:

### 1. Bridge HW-offload (`hw=yes` → `hw=no`)
L2 switching was happening in the switch chip, bypassing the CPU/IP stack entirely.
```
/interface bridge port set [find interface=ether2] hw=no
/interface bridge port set [find interface=ether3] hw=no
/interface bridge port set [find interface=ether4] hw=no
/interface bridge port set [find interface=ether5] hw=no
```

### 2. Bridge `use-ip-firewall=no` → `yes`
With the default `no`, bridge traffic bypassed the IP firewall and routing stack. Packets arrived on the bridge but were L2-switched rather than IP-routed.
```
/interface bridge settings set use-ip-firewall=yes
```

### 3. Bridge `fast-forward=yes` → `no`
A bridge-level forwarding shortcut that bypassed normal IP routing for certain unicast packets.
```
/interface bridge set [find name=bridge] fast-forward=no
```

### 4. Global `allow-fast-path=yes` → `no`
IP-level FastPath shortcut bypassing the firewall chains.
```
/ip settings set allow-fast-path=no
```

### 5. Missing IPsec bypass policy for LAN return traffic (CRITICAL)
The `0.0.0.0/0 → 0.0.0.0/0` encrypt policy was re-encrypting return traffic destined for LAN clients (`dst=192.168.88.0/24`) and sending it back to Alibaba instead of forwarding it to the device. This affected both:
- Router replies to Android pings (ICMP reply → re-encrypted → lost)
- Return traffic from internet via tunnel (decrypted by IPsec → re-encrypted → lost)

Fix: add a bypass (none) policy for traffic destined to the LAN, placed before the encrypt policy:
```
/ip ipsec policy add src-address=0.0.0.0/0 dst-address=192.168.88.0/24 action=none place-before=0
```

### 6. DHCP not pushing default gateway
`configure-gateway.rsc` was only setting `dns-server`, not `gateway`. Fixed in script and applied manually:
```
/ip dhcp-server network set [find] gateway=192.168.88.1 dns-server=192.168.88.1
```

---

## What Is NOT Working

### Android DHCP gateway not received
Despite MikroTik DHCP being correctly configured (`gateway=192.168.88.1`), Android 9 devices do not receive the default gateway option in their DHCP lease. Likely an Android 9 DHCP client quirk.

**Workaround (temporary, lost on WiFi reconnect):** From adb shell with root:
```
ip route add default via 192.168.88.1 dev wlan0
```

**Permanent fix options:**
- Configure static IP on each Android device (Settings → WiFi → Modify → Static IP, gateway=192.168.88.1)
- Use `adb shell settings put global network_avoid_bad_wifi 0` to suppress Android's "avoid bad WiFi" suppression
- Investigate if a DHCP option set can force the gateway on Android 9

---

## Alibaba VPN Gateway — Known Quirks

1. **Traffic selectors must be `0.0.0.0/0`** — Narrow TS (`192.168.88.0/24 → 10.2.0.0/16`) is rejected with `TS_UNACCEPTABLE`. Verified by test — tunnel dropped when narrow TS was applied.

2. **`my-id` / `remote-id` required** — MikroTik is behind NAT. Without explicit IDs, IKE sends private WAN IP as identity → Alibaba rejects with `AUTHENTICATION_FAILED`.
   ```
   my-id=address:223.73.2.164
   remote-id=address:39.108.115.199
   ```

3. **`local-address=192.168.5.71` required on peer** — Without it, `sa-src-address=0.0.0.0` and no IKE is initiated.

4. **Destination-based route on Alibaba VPN Gateway** — `192.168.88.0/24 → IPsec connection`, "Publish to VPC" enabled. Required for return path from ECS back to LAN clients.

5. **Alibaba Internet NAT Gateway SNAT** — SNAT rule for `192.168.88.0/24` added to Alibaba NAT Gateway so tunnel traffic can reach internet (8.8.8.8, etc.).

6. **Customer gateway public IP** — Currently `223.73.2.164`. This IP is assigned by the factory ISP and **can rotate** without notice. When it changes, update both sides: MikroTik identity (`my-id`) and Alibaba tunnel RemoteID + customer gateway. Symptom is `AUTHENTICATION_FAILED` in MikroTik IPsec logs. Last changed: 2026-04-28 (`223.73.2.134` → `223.73.2.164`).

7. **IPsec bypass policy for LAN required** — Because traffic selectors are `0.0.0.0/0`, return traffic to LAN clients matches the encrypt policy. A `dst=192.168.88.0/24 action=none` policy placed before the encrypt policy is mandatory.

8. **`in-template-mismatches` counter** — Alibaba VPN Gateway sends probe/keepalive packets through the tunnel using LAN addresses as inner IPs. These arrive as `in:ether1 out:ether1` in the forward chain log. Harmless — do not try to suppress.

---

## Current MikroTik IPsec Policy Table
```
# Policy order matters — more specific (none) before catch-all (encrypt)
/ip ipsec policy
add src-address=0.0.0.0/0 dst-address=192.168.88.0/24 action=none          # bypass: LAN return traffic
add src-address=0.0.0.0/0 dst-address=0.0.0.0/0 tunnel=yes action=encrypt \
    proposal=alibaba-ipsec peer=alibaba-peer                                 # encrypt: all other traffic
```

---

## MikroTik Config Files

| File | Purpose |
|------|---------|
| `mikrotik/configure-ipsec.rsc` | IPsec IKEv2: profile, peer, identity, proposal, policy, NAT bypass |
| `mikrotik/configure-gateway.rsc` | DNS static overrides + DHCP gateway + DNS server push |

---

## Diagnostic Commands (run on MikroTik)

```
/ip ipsec active-peers print
/ip ipsec installed-sa print
/ip ipsec statistics print
/ping 10.2.0.100 src-address=192.168.88.1
/ping 8.8.8.8 src-address=192.168.88.1
/ip firewall filter print terse
/ip firewall nat print terse
/interface bridge port print detail
/interface bridge settings print
/ip dhcp-server network print detail
/ip dhcp-server lease print
/tool sniffer quick ip-address=192.168.88.253 interface=bridge
/tool sniffer quick interface=ether1 ip-address=39.108.115.199
/log print where message~"192.168.88.253"
```

---

## Next Steps

### 1. Fix Android DHCP gateway (PRIMARY)
Android 9 devices must get their default route automatically — the manual `ip route add` workaround is lost on reconnect. Options:
- Set static IP on each Android test device via Settings → WiFi
- Or investigate a DHCP option set that forces Android to accept the gateway

### 2. Test OogiCam endpoints end-to-end
From an Android device (with default route set):
```
ping api.oogiservices.net       # should resolve to 10.2.0.100
curl http://api.oogiservices.net
```

### 3. Android "Avoid bad WiFi" suppression
If Android still drops the WiFi default route due to connectivity check failure:
```
adb shell settings put global network_avoid_bad_wifi 0
```
MikroTik DNS overrides `connectivitycheck.gstatic.com → 10.2.0.100` and ECS nginx serves HTTP 204, which should satisfy Android's check.

### 4. Cleanup
- Set admin password on MikroTik
- Export config backup: `/export file=oogi-qa-backup`

---

## Critical Safety Rule
**Never compromise remote access to the MikroTik router.** User is in South Africa, router is in China. A lockout requires physical factory intervention (factory reset button). Safe-mode (`/safe-mode` = Ctrl+X in terminal) auto-reverts if connection drops within ~9 minutes. Use it for any risky changes.

Do NOT touch: bridge enable/disable, ether1 config, firewall rules blocking Winbox port 8291, `/system reset-configuration`.

**AnyDesk safety:** AnyDesk rides the factory PC's WiFi (192.168.5.x). Never disable WiFi, lower Ethernet metric below WiFi, or run `ipconfig /renew` on the factory PC's Ethernet adapter — any of these would steal the default route from WiFi and drop the AnyDesk session.
