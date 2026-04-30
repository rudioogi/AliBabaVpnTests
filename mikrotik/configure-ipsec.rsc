# OogiCam Factory QA — MikroTik IPsec IKEv2 Configuration
# Upload via Winbox Files, then run: /import file=configure-ipsec.rsc
#
# Prereqs (set these on router before importing):
#   :global wanIp "192.168.5.71"       # MikroTik WAN address (behind factory NAT)
#   :global publicIp "223.73.2.134"    # Public IP seen by Alibaba (NAT'd)
# Or edit the values below directly.

:local wanIp       "192.168.5.71"
:local publicIp    "223.73.2.155"
:local alibabaIp   "39.108.115.199"
:local psk         "Oogi12345"
:local lanSubnet   "192.168.88.0/24"
:local chinaSubnet "10.2.0.0/16"

# ── IPsec Profile (Phase 1 / IKE) ────────────────────────
/ip ipsec profile
add name=alibaba-ike enc-algorithm=aes-128 hash-algorithm=sha1 dh-group=modp1024 lifetime=24h nat-traversal=yes

# ── IPsec Peer (local-address pinned to WAN IP) ──────────
/ip ipsec peer
add name=alibaba-peer address=($alibabaIp . "/32") profile=alibaba-ike exchange-mode=ike2 local-address=$wanIp

# ── IPsec Identity (my-id / remote-id required for NAT'd peer) ──
/ip ipsec identity
add peer=alibaba-peer auth-method=pre-shared-key secret=$psk \
    my-id=("address:" . $publicIp) remote-id=("address:" . $alibabaIp)

# ── IPsec Proposal (Phase 2 / ESP) ───────────────────────
/ip ipsec proposal
add name=alibaba-ipsec auth-algorithms=sha1 enc-algorithms=aes-128-cbc pfs-group=modp1024 lifetime=24h

# ── IPsec Policy: bypass for LAN return traffic ──────────
# Must be placed BEFORE the catch-all encrypt policy.
# Without this, return traffic from the tunnel (dst=LAN) is re-encrypted
# and sent back to Alibaba instead of being forwarded to the LAN client.
:if ([:len [/ip ipsec policy find dst-address=$lanSubnet action=none]] = 0) do={
    /ip ipsec policy add src-address=0.0.0.0/0 dst-address=$lanSubnet action=none place-before=0
}

# ── IPsec Policy: encrypt all other traffic via Alibaba ──
# Alibaba VPN Gateway 2.0 requires 0.0.0.0/0 traffic selectors.
# Narrowing to 192.168.88.0/24 → 10.2.0.0/16 causes TS_UNACCEPTABLE.
:if ([:len [/ip ipsec policy find dst-address=0.0.0.0/0 action=encrypt]] = 0) do={
    /ip ipsec policy add src-address=0.0.0.0/0 dst-address=0.0.0.0/0 tunnel=yes action=encrypt \
        proposal=alibaba-ipsec peer=alibaba-peer
}

# ── NAT bypass for LAN → China ECS traffic ───────────────
/ip firewall nat
add chain=srcnat src-address=$lanSubnet dst-address=$chinaSubnet action=accept \
    comment="OogiCam-QA: no NAT for IPsec" place-before=0

:log info "OogiCam-QA IPsec IKEv2 configuration applied"
