# OogiCam Factory QA — MikroTik IPsec IKEv2 Configuration
# Replaces SSL VPN (OpenVPN had comp-lzo incompatibility with RouterOS 7.x)
# Upload via Winbox Files, then run: /import file=configure-ipsec.rsc

# ── Disable SSL VPN ───────────────────────────────────────
/interface ovpn-client disable [find name=alibaba-vpn]

# ── Remove old OpenVPN routes and NAT rules ───────────────
/ip route remove [find comment="OogiCam-QA: China ECS via VPN"]
/ip firewall nat remove [find out-interface=alibaba-vpn]
/ip firewall filter remove [find comment="OogiCam-QA: accept VPN input"]

# ── IPsec Profile (Phase 1 / IKE) ────────────────────────
/ip ipsec profile
add name=alibaba-ike enc-algorithm=aes-128 auth-algorithm=sha1 dh-group=modp1024 lifetime=24h nat-traversal=yes

# ── IPsec Peer ────────────────────────────────────────────
/ip ipsec peer
add name=alibaba-peer address=39.108.115.199/32 profile=alibaba-ike exchange-mode=ike2

# ── IPsec Identity (pre-shared key) ──────────────────────
/ip ipsec identity
add peer=alibaba-peer auth-method=pre-shared-key secret="Oogi12345"

# ── IPsec Proposal (Phase 2 / ESP) ───────────────────────
/ip ipsec proposal
add name=alibaba-ipsec auth-algorithms=sha1 enc-algorithms=aes-128-cbc pfs-group=modp1024 lifetime=24h

# ── IPsec Policy (encrypt LAN traffic to China ECS) ──────
/ip ipsec policy
add src-address=192.168.80.0/20 dst-address=10.2.0.0/16 tunnel=yes action=encrypt proposal=alibaba-ipsec peer=alibaba-peer

# ── NAT bypass (don't masquerade IPsec traffic) ───────────
/ip firewall nat add chain=srcnat src-address=192.168.80.0/20 dst-address=10.2.0.0/16 action=accept comment="OogiCam-QA: no NAT for IPsec" place-before=0

:log info "OogiCam-QA IPsec IKEv2 configuration applied"
