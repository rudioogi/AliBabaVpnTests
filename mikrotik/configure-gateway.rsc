# OogiCam Factory QA — MikroTik Gateway Configuration
# Run AFTER configure-ipsec.rsc shows an active SA.
# Upload to MikroTik via Winbox Files, then run:
#   /import file=configure-gateway.rsc

# ── DNS: enable and add static overrides ─────────────────
/ip dns
set allow-remote-requests=yes

:local oogiHosts {
    "api.oogiservices.net";
    "storage.oogiservices.net";
    "streaming.oogiservices.net";
    "streaming-za.oogiservices.net";
    "metrics.oogiservices.net";
    "synap-iot-production.azure-devices.net";
    "staging-synapinc-iothub.azure-devices.net";
    "oogi-aim-management.database.windows.net";
    "connectivitycheck.gstatic.com";
    "www.msftconnecttest.com";
    "vpnau.oogiservices.net";
    "vpnau2.oogiservices.net";
    "azuregateway-857e0077-c9da-4129-a201-709895d85810-c11bb0dae7e3.vpn.azure.com"
}

# Windows NCSI DNS check — resolves to specific Microsoft IP (not proxied)
:if ([:len [/ip dns static find name="dns.msftncsi.com"]] = 0) do={
    /ip dns static add name="dns.msftncsi.com" address=131.107.255.255
} else={
    /ip dns static set [find name="dns.msftncsi.com"] address=131.107.255.255
}

:foreach h in=$oogiHosts do={
    :if ([:len [/ip dns static find name=$h]] = 0) do={
        /ip dns static add name=$h address=10.2.0.100
    } else={
        /ip dns static set [find name=$h] address=10.2.0.100
    }
}

# ── DHCP: push gateway + DNS server to LAN clients ────────
/ip dhcp-server network
set [find] gateway=192.168.88.1 dns-server=192.168.88.1

# ── Bridge: enable IP-level routing for LAN clients ───────
# These four settings are required for LAN client traffic to be
# routed through the IPsec tunnel. Without them, bridge traffic
# bypasses the IP stack entirely and forwarding silently fails.
/ip settings
set allow-fast-path=no

/interface bridge settings
set use-ip-firewall=yes

/interface bridge
set [find name=bridge] fast-forward=no

/interface bridge port
set [find interface=ether2] hw=no
set [find interface=ether3] hw=no
set [find interface=ether4] hw=no
set [find interface=ether5] hw=no

# ── IPsec bypass for direct internet destinations ────────
# IMPORTANT: src must be 0.0.0.0/0 (not the LAN subnet).
# RouterOS runs srcnat (masquerade) BEFORE IPsec policy lookup, so by the
# time IPsec evaluates the packet, the source is already the WAN IP
# (192.168.5.71), not the original LAN client IP. Using the LAN subnet as
# src would never match and the encrypt policy would catch the packet instead,
# routing it through the Alibaba tunnel rather than directly to the internet.
# ── IPsec bypass for MikroTik DNS upstream ───────────────
# MikroTik's own DNS queries use src=192.168.5.71 (WAN IP), which is outside
# the Alibaba SNAT range (192.168.88.0/24). Without this bypass, queries to
# the upstream DNS server go through the tunnel but get dropped by Alibaba.
# Bypassing sends them directly via ether1 (factory internet), which works.
:local dnsServer "114.114.114.114"

:if ([:len [/ip ipsec policy find dst-address=($dnsServer . "/32") action=none]] = 0) do={
    /ip ipsec policy add src-address=0.0.0.0/0 dst-address=($dnsServer . "/32") \
        action=none comment="bypass: DNS upstream" \
        place-before=[/ip ipsec policy find action=encrypt]
}

:local openDns1 "208.67.222.222"
:local openDns2 "208.67.220.220"
:local chinaEcsPublic "120.79.157.95"

:foreach ip in={$openDns1; $openDns2} do={
    :if ([:len [/ip ipsec policy find dst-address=($ip . "/32") action=none]] = 0) do={
        /ip ipsec policy add src-address=0.0.0.0/0 dst-address=($ip . "/32") \
            action=none comment="bypass: OpenDNS (IP detection)" \
            place-before=[/ip ipsec policy find action=encrypt]
    }
}

:if ([:len [/ip ipsec policy find dst-address=($chinaEcsPublic . "/32") action=none]] = 0) do={
    /ip ipsec policy add src-address=0.0.0.0/0 dst-address=($chinaEcsPublic . "/32") \
        action=none comment="bypass: China ECS public (vpn-updater)" \
        place-before=[/ip ipsec policy find action=encrypt]
}

:local rustdeskServer "154.0.7.222"

:if ([:len [/ip ipsec policy find dst-address=($rustdeskServer . "/32") action=none]] = 0) do={
    /ip ipsec policy add src-address=0.0.0.0/0 dst-address=($rustdeskServer . "/32") \
        action=none comment="bypass: RustDesk SA server" \
        place-before=[/ip ipsec policy find action=encrypt]
} else={
    /ip ipsec policy set [find dst-address=($rustdeskServer . "/32") action=none] src-address=0.0.0.0/0
}

# ── Firewall: accept new LAN to WAN connections ──────────
# Required for bypassed (non-IPsec) traffic from LAN to reach WAN (ether1).
# IPsec-encrypted traffic is already accepted by the ipsec-policy=out,ipsec rule.
# Without this rule, new LAN→WAN connections not going through IPsec are dropped.
:if ([:len [/ip firewall filter find chain=forward action=accept in-interface-list=LAN out-interface-list=WAN]] = 0) do={
    /ip firewall filter add chain=forward connection-state=new \
        in-interface-list=LAN out-interface-list=WAN action=accept \
        comment="accept new LAN to WAN" \
        place-before=[/ip firewall filter find chain=forward action=drop connection-state=invalid]
}

:log info "OogiCam-QA gateway configuration applied"
