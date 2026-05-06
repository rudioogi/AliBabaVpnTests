# China Factory Pi — Gateway Setup
# Automated setup guide — execute all commands via SSH as user `oogi`

## Overview

Raspberry Pi 3, Raspberry Pi OS Lite 64-bit. Acts as a backup gateway for China factory
Android devices when the MikroTik is unavailable.

```
[Android devices — 192.168.88.x]
        │  WiFi: xinmeishen
        │
[Pi wlan0 AP — 192.168.88.55]
        │  IPsec IKEv2 tunnel
        │
[Alibaba VPN Gateway — 39.108.115.199]
        │  CEN
        │
[China ECS — 10.2.0.100]
        │  CEN
        │
[US ECS — 10.1.1.96]
        │
[Azure services]
```

**Two modes:**
- **Internet mode** (SA setup): wlan0 = client (internet), eth0 = unused
- **Factory mode** (deployed): eth0 = factory internet, wlan0 = AP for Android devices

---

## Phase 1 — Complete in SA (internet via wlan0)

### Step 1 — Pi-hole DNS overrides ✅ Already done

Verify overrides are in place:
```bash
cat /etc/pihole/custom.list
```

Should list all Azure hostnames pointing to `10.2.0.100`. If empty, re-run:
```bash
sudo tee /etc/pihole/custom.list << 'EOF'
10.2.0.100 api.oogiservices.net
10.2.0.100 storage.oogiservices.net
10.2.0.100 streaming.oogiservices.net
10.2.0.100 streaming-za.oogiservices.net
10.2.0.100 metrics.oogiservices.net
10.2.0.100 synap-iot-production.azure-devices.net
10.2.0.100 staging-synapinc-iothub.azure-devices.net
10.2.0.100 connectivitycheck.gstatic.com
10.2.0.100 vpnau.oogiservices.net
10.2.0.100 vpnau2.oogiservices.net
10.2.0.100 azuregateway-857e0077-c9da-4129-a201-709895d85810-c11bb0dae7e3.vpn.azure.com
EOF
sudo pihole restartdns
```

Verify:
```bash
dig api.oogiservices.net @127.0.0.1 +short
# Expected: 10.2.0.100
```

---

### Step 2 — Install StrongSwan (IPsec IKEv2)

```bash
sudo apt update
sudo apt install -y strongswan strongswan-pki libcharon-extra-plugins libcharon-extauth-plugins
```

---

### Step 3 — Configure StrongSwan

Write the IPsec connection config:
```bash
sudo tee /etc/ipsec.conf << 'EOF'
config setup
    charondebug="ike 1, knl 1, cfg 0"
    uniqueids=no

# ── Main tunnel to Alibaba VPN Gateway ───────────────────────────────────────
conn alibaba-vpn
    keyexchange=ikev2
    left=%defaultroute
    leftid=223.73.2.134
    leftsubnet=0.0.0.0/0
    right=39.108.115.199
    rightid=39.108.115.199
    rightsubnet=0.0.0.0/0
    authby=secret
    ike=aes128-sha1-modp1024!
    esp=aes128-sha1-modp1024!
    ikelifetime=24h
    lifetime=24h
    type=tunnel
    auto=start
    dpdaction=restart
    dpddelay=30s
    dpdtimeout=120s

# ── Bypass: return traffic to wlan0 AP subnet ────────────────────────────────
# Prevents re-encryption of decrypted return traffic destined for Android devices.
conn bypass-wlan-ap
    left=%any
    leftsubnet=0.0.0.0/0
    right=%any
    rightsubnet=192.168.88.0/24
    type=passthrough
    auto=route

# ── Bypass: factory LAN (management SSH, local routing) ──────────────────────
conn bypass-factory-lan
    left=%any
    leftsubnet=0.0.0.0/0
    right=%any
    rightsubnet=192.168.5.0/24
    type=passthrough
    auto=route
EOF
```

Write the PSK:
```bash
sudo tee /etc/ipsec.secrets << 'EOF'
: PSK "Oogi12345"
EOF
sudo chmod 600 /etc/ipsec.secrets
```

---

### Step 4 — Enable IP forwarding

```bash
sudo tee /etc/sysctl.d/99-oogicam-forward.conf << 'EOF'
net.ipv4.ip_forward=1
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
EOF
sudo sysctl -p /etc/sysctl.d/99-oogicam-forward.conf
```

---

### Step 5 — iptables rules

```bash
# Accept forwarded traffic from/to wlan0 AP
sudo iptables -A FORWARD -i wlan0 -j ACCEPT
sudo iptables -A FORWARD -o wlan0 -j ACCEPT
sudo iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT

# Accept IPsec/IKE traffic
sudo iptables -A INPUT -p udp --dport 500 -j ACCEPT
sudo iptables -A INPUT -p udp --dport 4500 -j ACCEPT
sudo iptables -A INPUT -p esp -j ACCEPT

# Save rules (install iptables-persistent)
sudo apt install -y iptables-persistent
sudo netfilter-persistent save
```

---

### Step 6 — Install hostapd and DHCP server

```bash
sudo apt install -y hostapd dnsmasq
```

Write hostapd config (pre-configured for factory, not yet activated):
```bash
sudo tee /etc/hostapd/hostapd.conf << 'EOF'
interface=wlan0
driver=nl80211
ssid=xinmeishen
hw_mode=g
channel=6
wmm_enabled=1
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=xms202009
wpa_key_mgmt=WPA-PSK
wpa_pairwise=CCMP
rsn_pairwise=CCMP
EOF
```

Configure dnsmasq for DHCP-only on wlan0 (DNS is handled by Pi-hole FTL):
```bash
sudo tee /etc/dnsmasq.d/wlan0-dhcp.conf << 'EOF'
# DHCP only — DNS is handled by Pi-hole
port=0
interface=wlan0
dhcp-range=192.168.88.100,192.168.88.200,24h
dhcp-option=3,192.168.88.55
dhcp-option=6,192.168.88.55
EOF
```

Do NOT start hostapd or dnsmasq yet — they activate in factory mode.

```bash
sudo systemctl disable hostapd
sudo systemctl disable dnsmasq
```

---

### Step 7 — Mode switch scripts

Write the factory mode activation script:
```bash
sudo tee /usr/local/bin/gateway-mode-factory.sh << 'SCRIPT'
#!/bin/bash
# Run this script at the factory after plugging in eth0 to the factory network.
# Switches internet from wlan0 (SA WiFi) to eth0, and turns wlan0 into AP.
set -e

echo "[1/7] Stopping wlan0 client mode..."
sudo systemctl stop wpa_supplicant 2>/dev/null || true
sudo wpa_cli -i wlan0 disconnect 2>/dev/null || true
sudo ip addr flush dev wlan0

echo "[2/7] Setting wlan0 static IP (AP mode)..."
sudo ip addr add 192.168.88.55/24 dev wlan0
sudo ip link set wlan0 up

echo "[3/7] Starting hostapd..."
sudo systemctl start hostapd
sudo systemctl enable hostapd

echo "[4/7] Starting DHCP server on wlan0..."
sudo systemctl start dnsmasq
sudo systemctl enable dnsmasq

echo "[5/7] Bringing up eth0 via DHCP (factory internet)..."
sudo dhclient eth0

echo "[6/7] Starting IPsec tunnel..."
sudo systemctl start strongswan-starter
sudo systemctl enable strongswan-starter

echo "[7/7] Updating Pi-hole to listen on wlan0..."
sudo pihole restartdns

echo ""
echo "Factory mode active."
echo "  wlan0 AP: xinmeishen / xms202009 — 192.168.88.55"
echo "  IPsec tunnel: check with 'sudo ipsec status'"
echo "  Verify tunnel: ping 10.2.0.100 from Pi"
SCRIPT
sudo chmod +x /usr/local/bin/gateway-mode-factory.sh
```

Write the internet mode script (for restoring SA WiFi client mode if needed):
```bash
sudo tee /usr/local/bin/gateway-mode-internet.sh << 'SCRIPT'
#!/bin/bash
# Restores wlan0 to WiFi client mode for internet access.
set -e

echo "[1/4] Stopping factory services..."
sudo systemctl stop hostapd 2>/dev/null || true
sudo systemctl stop dnsmasq 2>/dev/null || true
sudo systemctl stop strongswan-starter 2>/dev/null || true
sudo ip addr flush dev wlan0

echo "[2/4] Restoring wlan0 client mode..."
sudo systemctl start wpa_supplicant
sudo dhclient wlan0

echo "[3/4] Releasing eth0..."
sudo dhclient -r eth0 2>/dev/null || true

echo "[4/4] Done. wlan0 is now in client (internet) mode."
SCRIPT
sudo chmod +x /usr/local/bin/gateway-mode-internet.sh
```

---

### Step 8 — Configure Pi-hole to listen on wlan0 (for factory mode)

Pi-hole needs to serve DNS on wlan0 when in factory mode. Pre-configure it to listen on all interfaces:
```bash
sudo pihole -a -i all
sudo pihole restartdns
```

---

## Phase 2 — At Factory (run after eth0 plugged in)

SSH into the Pi from the factory PC's terminal (local IP on eth0, or ask for it via `ip addr show eth0`):

```bash
sudo gateway-mode-factory.sh
```

Verify tunnel:
```bash
sudo ipsec status
ping -c 3 10.2.0.100
```

Verify DNS overrides from Pi:
```bash
dig api.oogiservices.net @192.168.88.55 +short
# Expected: 10.2.0.100
```

Connect an Android device to WiFi `xinmeishen` (password: `xms202009`) and verify app connectivity.

---

## Network Summary

| Interface | SA mode | Factory mode |
|-----------|---------|--------------|
| eth0 | unused | DHCP from factory (192.168.5.x) |
| wlan0 | client (internet) | AP — 192.168.88.55/24 |

| Service | Port | Notes |
|---------|------|-------|
| Pi-hole DNS | 53 | Overrides Azure hostnames → 10.2.0.100 |
| DHCP (wlan0) | 67 | Serves 192.168.88.100–200, GW+DNS = 192.168.88.55 |
| IPsec IKE | 500/4500 UDP | Alibaba VPN Gateway 39.108.115.199 |
| SSH | 22 | Key: factory-pi (ed25519) |

## Key Parameters

| Parameter | Value |
|-----------|-------|
| Pi LAN IP | 192.168.88.55 |
| WiFi SSID | xinmeishen |
| WiFi Password | xms202009 |
| Alibaba VPN peer | 39.108.115.199 |
| Alibaba PSK | Oogi12345 |
| Factory public IP | 223.73.2.134 |
| China ECS | 10.2.0.100 |
