# OogiCam — IP Monitor Installer
# Run once via Winbox terminal or /import file=configure-ip-monitor.rsc
#
# What this does:
#   1. Adds IPsec bypass policies for OpenDNS resolvers (IP detection) and China ECS (update endpoint)
#   2. Registers the check-public-ip script
#   3. Schedules it every 5 minutes
#
# Prereqs: configure-ipsec.rsc already imported, IPsec tunnel established.
# After this: paste the shared secret into the check-public-ip script source.

# ── Bypass policies (same pattern as DNS upstream / RustDesk bypasses) ───────
# Must be before the 0.0.0.0/0 encrypt policy.

:foreach ip in={"208.67.222.222"; "208.67.220.220"} do={
    :if ([:len [/ip ipsec policy find dst-address=($ip . "/32") action=none]] = 0) do={
        /ip ipsec policy add src-address=0.0.0.0/0 dst-address=($ip . "/32") \
            action=none comment="bypass: OpenDNS (IP detection)" \
            place-before=[/ip ipsec policy find action=encrypt]
    }
}

# China ECS public IP — needed so the HTTPS update call works even when tunnel is down
:local chinaEcsPublic "120.79.157.95"
:if ([:len [/ip ipsec policy find dst-address=($chinaEcsPublic . "/32") action=none]] = 0) do={
    /ip ipsec policy add src-address=0.0.0.0/0 dst-address=($chinaEcsPublic . "/32") \
        action=none comment="bypass: China ECS public (vpn-updater)" \
        place-before=[/ip ipsec policy find action=encrypt]
}

# ── Register the monitor script ──────────────────────────────────────────────
# Source is loaded from the .rsc file content — paste it here or keep it as
# a separate file and import via /system script add source=[/file get ...]
:if ([:len [/system script find name="check-public-ip"]] = 0) do={
    /system script add name="check-public-ip" \
        comment="oogi-vpn: detects public IP change and triggers Alibaba update" \
        source=""
    :log info "oogi-vpn: created script stub 'check-public-ip' — paste content from check-public-ip.rsc"
} else={
    :log info "oogi-vpn: script 'check-public-ip' already exists, not overwritten"
}

# ── Create a script to store the last known public IP ────────────────────────
:if ([:len [/system script find name="oogi-last-public-ip"]] = 0) do={
    /system script add name="oogi-last-public-ip" source="" comment="oogi-vpn: do not delete — stores last known public IP"
}

# ── Scheduler: run every 5 minutes ──────────────────────────────────────────
:if ([:len [/system scheduler find name="oogi-public-ip-check"]] = 0) do={
    /system scheduler add \
        name="oogi-public-ip-check" \
        interval=5m \
        on-event="/system script run check-public-ip" \
        comment="oogi-vpn: monitors public IP and recovers IPsec on change" \
        start-time=startup
}

:log info "oogi-vpn: IP monitor installed — scheduler runs every 5 minutes"
:log info "oogi-vpn: NEXT STEP: set sharedSecret in /system script edit check-public-ip"
