# OpenVPN Connection Status (updated 2026-04-29)

## Current Status
✅ IPsec tunnel established  
⏳ OpenVPN from Android — not yet retested after tunnel restore (2026-04-29)

---

## Incident: Tunnel Down (2026-04-28)

### Symptom
- Android devices could not connect to OpenVPN
- China ECS could not ping MikroTik (regression — had been working)
- MikroTik: `ph2-state=no-phase2`, no active peers
- MikroTik logs: `AUTHENTICATION_FAILED` from Alibaba VPN gateway

### Root Cause
Factory ISP rotated the public NAT IP from `223.73.2.134` to `223.73.2.164`.

The MikroTik IPsec identity was pinned to the old IP (`my-id=address:223.73.2.134`).
Alibaba's tunnel RemoteID was also still set to the old IP. IKE phase 1 failed immediately
on every negotiation attempt with `AUTHENTICATION_FAILED`.

### Fix Applied
1. MikroTik: `/ip ipsec identity set [find peer=alibaba-peer] my-id=address:223.73.2.164`
2. Alibaba console: updated customer gateway IP + IPsec tunnel RemoteID to `223.73.2.164`
3. `configure-ipsec.rsc`: updated `$publicIp` variable to `223.73.2.164`

### How to Diagnose Next Time
```
/ip ipsec active-peers print          # no output = tunnel down
/log print where topics~"ipsec"       # look for AUTHENTICATION_FAILED
/tool fetch url="https://ifconfig.me/ip" output=user   # check current public IP
                                      # NOTE: will fail if tunnel is down (level=require)
                                      # Use a PC/phone on the same network instead
```

If `AUTHENTICATION_FAILED` appears in logs, compare the current public IP against
`$publicIp` in `configure-ipsec.rsc` and the Alibaba customer gateway / tunnel RemoteID.

---

## Known: China ECS Cannot Ping MikroTik

MikroTik's input chain firewall drops ICMP arriving from the China ECS via the tunnel
because the packets come in on ether1 (WAN) and the default firewall has a WAN drop rule.

**Fix (not yet applied):**
```
/ip firewall filter add chain=input src-address=10.2.0.0/16 \
    ipsec-policy=in,ipsec action=accept comment="accept from China ECS via IPsec" \
    place-before=[/ip firewall filter find chain=input action=drop]
```

This does not affect Android or app traffic — only MikroTik reachability from China ECS.

---

## OpenVPN Traffic Flow

```
Android (192.168.88.x)
  → MikroTik IPsec tunnel
  → Alibaba VPN Gateway (39.108.115.199)
  → China ECS (10.2.0.100:1194 UDP) — nginx stream proxy
  → CEN (private cross-border link)
  → US ECS (10.1.1.96:1194 UDP) — nginx stream proxy, hash load balanced
  → Azure vpn-au (4.198.127.118:1194) or vpn-au2 (23.101.231.126:1194)
```

**Important:** China ECS must proxy to US ECS (`10.1.1.96`), never directly to Azure.
Direct China → Azure UDP 1194 is blocked by the Great Firewall.

---

## Azure OpenVPN Servers

| | vpn-au | vpn-au2 |
|---|---|---|
| Public IP | 4.198.127.118 | 23.101.231.126 |
| Private IP | 172.23.0.5 | — |
| Region | australiasoutheast | australiasoutheast |
| Protocol | UDP 1194 | UDP 1194 |
| Config | /etc/openvpn/server/server.conf | — |
| Status log | /etc/openvpn/server/openvpn-status.log | — |
| VPN subnet | 10.11.0.0/18 | — |

OpenVPN listens on the **private** IP only (`local 172.23.0.5`). Azure's network stack
handles the public IP — no additional NAT rule is needed; packets addressed to the public
IP are delivered directly to the VM's NIC.

---

## Verification Commands

**On China ECS — confirm packets arriving from Android:**
```bash
sudo tcpdump -n -i any udp port 1194
```

**On Azure VM:**
```bash
sudo tcpdump -n -i eth0 udp port 1194
sudo grep '^CLIENT_LIST' /etc/openvpn/server/openvpn-status.log
```
