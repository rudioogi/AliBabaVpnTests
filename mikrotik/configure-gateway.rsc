# OogiCam Factory QA — MikroTik Gateway Configuration
# Run after OpenVPN client (alibaba-vpn) is connected and showing R flag
# Upload to MikroTik via Winbox Files, then run:
#   /import file=configure-gateway.rsc

# ── DNS: enable and add static overrides ─────────────────
/ip dns set allow-remote-requests=yes

/ip dns static
add name=api.oogiservices.net                      address=10.2.0.100
add name=storage.oogiservices.net                  address=10.2.0.100
add name=streaming.oogiservices.net                address=10.2.0.100
add name=streaming-za.oogiservices.net             address=10.2.0.100
add name=metrics.oogiservices.net                  address=10.2.0.100
add name=synap-iot-production.azure-devices.net    address=10.2.0.100
add name=staging-synapinc-iothub.azure-devices.net address=10.2.0.100
add name=connectivitycheck.gstatic.com             address=10.2.0.100

# ── Routing: send Azure traffic through VPN ───────────────
/ip route
add dst-address=10.2.0.100/32 gateway=alibaba-vpn comment="OogiCam-QA: China ECS via VPN"

# ── DHCP: ensure MikroTik is DNS server for LAN clients ──
/ip dhcp-server network
set [find] dns-server=192.168.80.1

:log info "OogiCam-QA gateway configuration applied"
