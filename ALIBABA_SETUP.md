# Alibaba Cloud — VPN & Network Setup Guide

For the OogiCam China Factory QA network. See `ARCHITECTURE.md` for the full topology.

---

## Prerequisites

- Alibaba Cloud account with a VPC in the China region (where the factory is located)
- Alibaba Cloud account with a VPC in the US region (connected to Azure via nginx)
- CEN (Cloud Enterprise Network) instance connecting both VPCs
- China ECS instance (`10.2.0.100`) running in the China VPC
- US ECS instance (`10.1.1.96`) running in the US VPC
- MikroTik router at the factory with public NAT IP `223.73.2.134`

---

## Part 1 — VPN Gateway (China VPC)

### 1.1 Create Customer Gateway

The customer gateway represents the MikroTik router at the factory.

**Alibaba Console → VPN Gateway → Customer Gateways → Create**

| Field | Value |
|-------|-------|
| Name | `mikrotik-factory` |
| IP Address | `223.73.2.134` |
| Description | MikroTik hEX at factory — public NAT IP |

> **Common typo:** `227.73.2.134` — double-check the IP.

---

### 1.2 Create VPN Gateway

**Alibaba Console → VPN Gateway → VPN Gateways → Create**

| Field | Value |
|-------|-------|
| Name | `factory-vpn-gw` |
| Region | China region (match factory location) |
| VPC | Your China VPC (`10.2.0.0/16`) |
| vSwitch | Any vSwitch in the VPC |
| Version | **VPN Gateway 2.0** (not 1.0) |
| Network Type | Public |
| Bandwidth | 10 Mbps or higher |
| IPsec-VPN | Enable |
| SSL-VPN | Not required |

After creation, note the **VPN Gateway Public IP** — this is `39.108.115.199` (the MikroTik peer address).

---

### 1.3 Create IPsec Connection

**VPN Gateway → IPsec Connections → Create**

#### Basic Settings

| Field | Value |
|-------|-------|
| Name | `factory-ipsec` |
| VPN Gateway | `factory-vpn-gw` |
| Customer Gateway | `mikrotik-factory` |
| Routing Mode | Destination Routing (not Policy Routing) |
| Effective Immediately | Yes |

#### IKE Configuration (Phase 1)

| Field | Value |
|-------|-------|
| IKE Version | **IKEv2** |
| Negotiation Mode | Main (default for IKEv2) |
| Encryption Algorithm | AES-128 |
| Authentication Algorithm | SHA1 |
| DH Group | Group 2 (MODP1024) |
| SA Lifetime | 86400 (24h) |
| Pre-shared Key | `Oogi12345` |
| Local ID | `39.108.115.199` (VPN Gateway public IP) |
| Remote ID | `223.73.2.134` (MikroTik public NAT IP) |

#### IPsec Configuration (Phase 2)

| Field | Value |
|-------|-------|
| Encryption Algorithm | AES-128 |
| Authentication Algorithm | SHA1 |
| DH Group | Group 2 (MODP1024) |
| SA Lifetime | 86400 (24h) |

#### Traffic Selectors (CRITICAL)

| Field | Value |
|-------|-------|
| Local Network | `0.0.0.0/0` |
| Remote Network | `0.0.0.0/0` |

> **Must be `0.0.0.0/0` on both sides.** Narrowing to `192.168.88.0/24 → 10.2.0.0/16`
> causes Alibaba VPN Gateway 2.0 to reject the connection with `TS_UNACCEPTABLE`.

---

### 1.4 Configure Route Table

**VPN Gateway → Route Tables** (or VPC Route Tables)

Add a destination-based route for the factory LAN:

| Field | Value |
|-------|-------|
| Destination CIDR | `192.168.88.0/24` |
| Next Hop Type | IPsec Connection |
| Next Hop | `factory-ipsec` |
| Publish to VPC | **Yes** |

> "Publish to VPC" is required. Without it, the return path from China ECS back to factory
> LAN devices is missing and traffic is one-way only.

---

### 1.5 NAT Gateway — SNAT for Factory LAN

This allows factory LAN devices (`192.168.88.x`) to reach the internet (e.g., `8.8.8.8`)
through the Alibaba tunnel.

**VPC → NAT Gateways → Select your NAT GW → SNAT Entries → Add**

| Field | Value |
|-------|-------|
| Source Type | CIDR Block |
| Source CIDR | `192.168.88.0/24` |
| Select Public IP | (any EIP attached to the NAT GW) |

---

## Part 2 — CEN (Cloud Enterprise Network)

CEN provides the private cross-border link between the China VPC and US VPC. This bypasses
the Great Firewall — all traffic from China ECS to US ECS travels via CEN, not the public
internet.

**CEN Console → CEN Instances → Select your CEN instance**

Verify both VPCs are attached:
- China VPC (`10.2.0.0/16`) — China region
- US VPC (`10.1.0.0/16`) — US region

If not attached:
**CEN → Networks → Attach Network**
- Select VPC, choose region and VPC, attach.

Do this for both VPCs.

**Verify connectivity after attaching:**
From China ECS: `ping 10.1.1.96` — should succeed.
From US ECS: `ping 10.2.0.100` — should succeed.

---

## Part 3 — China ECS Security Group

The China ECS (`10.2.0.100`) must have inbound rules for all proxied ports.

**ECS Console → Security Groups → Inbound Rules → Add**

| Priority | Action | Protocol | Port | Source |
|----------|--------|----------|------|--------|
| 1 | Allow | TCP | 443 | `192.168.88.0/24` |
| 1 | Allow | UDP | 1194 | `192.168.88.0/24` |
| 1 | Allow | TCP | 1433 | `192.168.88.0/24` |
| 1 | Allow | TCP | 8883 | `192.168.88.0/24` |
| 1 | Allow | TCP | 8086 | `192.168.88.0/24` |
| 1 | Allow | UDP | 500 | `192.168.88.0/24` |
| 1 | Allow | UDP | 4500 | `192.168.88.0/24` |

Also ensure the VPN Gateway's internal IP range can reach the China ECS (usually automatic
within the same VPC).

---

## Part 4 — Verification

### Verify IPsec SA (from MikroTik)
```
/ip ipsec active-peers print
```
Should show `established`, remote address `39.108.115.199`.

```
/ip ipsec installed-sa print
```
Should show two SAs with `SE` flags (seen traffic both directions).

### Verify LAN client routing (from MikroTik)
```
/ping 10.2.0.100 src-address=192.168.88.1
```
Should reply. If not, check the route table "Publish to VPC" step.

### Verify CEN connectivity (from China ECS)
```bash
ping 10.1.1.96
```
Should reply. If not, check CEN attachment for both VPCs.

### Verify full path (from Android device with default route set)
```bash
ping 10.2.0.100    # China ECS via IPsec tunnel
curl http://api.oogiservices.net   # should resolve to 10.2.0.100, return via US ECS → Azure
```
