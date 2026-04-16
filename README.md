# OogiCam China Factory QA — Connection Test Tool

Self-contained test tool for verifying Azure service connectivity from a factory PC
in China, through the Alibaba Cloud VPN + nginx proxy chain.

No .NET runtime installation required — the published exe includes everything.

---

## Architecture Under Test

```
[Factory PC]
    │  Alibaba SSL VPN (OpenVPN)
    │  Factory PC gets private VPC IP (172.16.100.x)
    ▼
[China ECS — nginx TCP passthrough]
    │  Port 443  → 10.1.1.96:443
    │  Port 1433 → 10.1.1.96:1433
    │  Port 8883 → 10.1.1.96:8883
    │
    │  CEN (Alibaba licensed cross-border link)
    ▼
[US ECS — nginx TCP passthrough]
    │
    ▼
[Azure Services]
    ├── api.oogiservices.net                    (HTTPS :443)
    ├── synap-iot-production.azure-devices.net   (MQTT  :8883)
    ├── *.database.windows.net                   (TDS   :1433)
    ├── *.blob.core.windows.net                  (HTTPS :443)
    ├── streaming.oogiservices.net               (HTTPS :443)
    ├── storage.oogiservices.net                 (HTTPS :443)
    ├── oogiservices.b2clogin.com                (HTTPS :443)
    └── login.microsoftonline.com                (HTTPS :443)
```

No TLS is terminated at any proxy. Certificates are validated end-to-end
between the factory PC and Azure. No custom CA certificates are needed.

---

## Prerequisites

| Requirement | Detail |
|------------|--------|
| Alibaba SSL VPN connected | OpenVPN client showing "Connected", private VPC IP assigned |
| Hosts file updated | Azure hostnames pointing to China ECS private IP |
| Security group | China ECS allows TCP 443, 1433, 8883 from VPN client subnet |
| appsettings.json | Connection strings filled in (see Configuration below) |

---

## Deployment

1. Copy the entire `publish` folder to the factory Windows PC:
   ```
   publish/
   ├── AliVpnTests.exe      (self-contained, ~80MB)
   ├── appsettings.json      (edit before running)
   └── AliVpnTests.pdb       (optional debug symbols)
   ```

2. Edit `appsettings.json` with your Azure connection strings (see Configuration)
3. Run `AliVpnTests.exe` as Administrator (needed for some network tests)

---

## Configuration — appsettings.json

### Service Connection Strings

These are required for the authenticated service tests (Section 3). If left as
`YOUR_*` placeholders, those tests are automatically skipped — not failed.

```json
{
  "SqlServer": {
    "ConnectionString": "Server=<your-server>.database.windows.net;Database=<db>;User Id=<user>;Password=<pass>;TrustServerCertificate=True;Encrypt=True;"
  },
  "IotHub": {
    "DeviceConnectionString": "HostName=synap-iot-production.azure-devices.net;DeviceId=<device-id>;SharedAccessKey=<key>"
  },
  "BlobStorage": {
    "ConnectionString": "DefaultEndpointsProtocol=https;AccountName=<account>;AccountKey=<key>;EndpointSuffix=core.windows.net"
  }
}
```

**Where to find these values:**

| Setting | Source |
|---------|--------|
| SQL Server connection string | Azure Portal → SQL Database → Connection strings, or the `SqlDBConnection` environment variable from the Synap.Api deployment |
| IoT Hub device connection string | Azure Portal → IoT Hub → Devices → select a test device → Primary connection string. Use format: `HostName=synap-iot-production.azure-devices.net;DeviceId=<id>;SharedAccessKey=<key>` |
| Blob Storage connection string | Azure Portal → Storage Account → Access keys, or the `AzureBlobConnectionString` environment variable from the Synap.Api deployment |

### TCP Endpoints

Pre-configured in `appsettings.json` under `TcpEndpoints`. These test raw TCP
connectivity — no credentials needed. Add or remove endpoints as needed:

```json
"TcpEndpoints": [
  { "Name": "API (HTTPS)",            "Host": "api.oogiservices.net",                    "Port": 443  },
  { "Name": "Streaming US",           "Host": "streaming.oogiservices.net",              "Port": 443  },
  { "Name": "IoT Hub (MQTT)",         "Host": "synap-iot-production.azure-devices.net",  "Port": 8883 },
  ...
]
```

### HTTP Endpoints

Pre-configured under `HttpEndpoints`. These test full HTTPS round-trips to
endpoints that don't require authentication:

```json
"HttpEndpoints": [
  { "Name": "API Swagger",     "Url": "https://api.oogiservices.net/swagger/index.html" },
  { "Name": "B2C OpenID",      "Url": "https://oogiservices.b2clogin.com/..." },
  ...
]
```

---

## Test Sections Explained

### Section 1: TCP Port Connectivity

**What it does:** Opens a raw TCP socket connection to each endpoint on the
specified port. No TLS, no HTTP — just tests if the port is reachable.

**What a PASS means:** The TCP three-way handshake completed. The factory PC can
reach the endpoint through the VPN → nginx → CEN proxy chain.

**What a FAIL means:** One of:
- Hostname not in the Windows hosts file (DNS resolves to Azure public IP, not
  the China ECS private IP, so traffic goes direct and hits the GFW)
- China ECS security group blocks the port from the VPN client subnet
- nginx on China ECS not listening on that port
- CEN link down or US ECS not forwarding that port

**How to fix a FAIL:**
1. Verify the hostname is in the hosts file pointing to the China ECS private IP
2. Check `nslookup` vs `ping` — `nslookup` bypasses hosts file, `ping` uses it
3. Verify the China ECS security group allows TCP on that port from `172.16.100.0/24`
4. SSH into the China ECS and run `ss -tlnp | grep <port>` to verify nginx is listening
5. From the China ECS, run `nc -zv 10.1.1.96 <port>` to verify the CEN link

### Section 2: HTTPS Endpoint Tests

**What it does:** Makes a full HTTPS GET request to endpoints that don't require
authentication. Tests the entire chain: DNS → TCP → TLS handshake → HTTP request/response.

**What a PASS means:** The full round-trip works. TLS validated against Azure's
real certificate. The response came back from the actual Azure service.

**What a FAIL means (when TCP passed):**
- TLS handshake failure — could indicate the US ECS nginx is not forwarding the
  SNI correctly, or the upstream Azure service is unreachable from the US ECS
- HTTP error — the connection works but the service returned an error

**Expected results:**

| Endpoint | Expected Response |
|----------|-------------------|
| API Swagger | HTTP 200 (OK) — Swagger UI HTML page |
| B2C OpenID | HTTP 200 (OK) — JSON OpenID configuration document |
| Azure AD OpenID | HTTP 200 (OK) — JSON OpenID configuration document |

### Section 3: Service Connection Tests

**What it does:** Establishes actual authenticated connections to Azure services
using the connection strings from `appsettings.json`.

**Tests performed:**

| Service | Protocol | What it does | What success looks like |
|---------|----------|-------------|----------------------|
| SQL Server | TDS (port 1433) | Opens a SQL connection, runs `SELECT @@VERSION` | Prints the SQL Server version string |
| IoT Hub | MQTT (port 8883) | Creates a DeviceClient, opens MQTT connection, sends a test telemetry message `{"test":"china-qa"}` | "MQTT connected, telemetry sent" |
| Blob Storage | HTTPS (port 443) | Connects to the storage account, retrieves service properties | "storage account reachable" |

**What a FAIL means (when TCP passed):**
- Authentication failure — connection string is incorrect or expired
- Timeout — the connection was established but the service didn't respond (proxy
  forwarding issue on the US ECS side)
- Protocol error — TLS version mismatch or certificate validation failure

**All service tests have a 15-second timeout** — if a connection hangs (common
when traffic is silently dropped), it fails with a timeout rather than hanging
the tool forever.

**Tests with `YOUR_*` placeholders are automatically skipped**, not failed. Fill
in only the services you need to test.

---

## Interpreting Results

### All TCP tests pass, HTTPS tests fail

The proxy chain is routing TCP correctly, but TLS is failing. This usually means
the US ECS nginx needs `ssl_preread` and SNI-based routing to forward different
hostnames to different Azure backends. Without it, all port 443 traffic goes to
one destination.

### Some TCP tests pass, some fail

Check which endpoints fail — they likely need:
1. A hosts file entry on the factory PC (hostname → China ECS private IP)
2. A matching nginx `stream` server block on the China ECS for that port
3. A matching nginx server block on the US ECS
4. A security group rule on the China ECS allowing the port

### TCP and HTTPS pass, service tests fail

The network path is working end-to-end. The issue is at the application layer:
- Check connection strings are correct
- Check credentials haven't expired
- For IoT Hub: verify the device exists in the hub and the SharedAccessKey matches

### B2C / Azure AD tests fail but API works

The US ECS nginx is likely forwarding all port 443 traffic to a single backend
(e.g., `api.oogiservices.net`). To support B2C and Azure AD, the US ECS needs
SNI-based routing:

```nginx
# US ECS nginx — SNI-based routing for multiple HTTPS backends
stream {
    map $ssl_preread_server_name $backend {
        api.oogiservices.net                  <azure-api-ip>:443;
        oogiservices.b2clogin.com             <b2c-ip>:443;
        login.microsoftonline.com             <aad-ip>:443;
        ~\.blob\.core\.windows\.net$          <blob-ip>:443;
        default                               <azure-api-ip>:443;
    }

    server {
        listen 443;
        ssl_preread on;
        proxy_pass $backend;
    }
}
```

This reads the SNI from the TLS ClientHello and routes to the correct Azure
backend. The China ECS nginx stays unchanged (dumb passthrough).

---

## Hosts File Reference

All endpoints that need to go through the proxy must be in the factory PC hosts
file. Open `C:\Windows\System32\drivers\etc\hosts` as Administrator and add:

```
# OogiCam QA — China ECS private IP (replace with your actual IP)
10.2.0.100  api.oogiservices.net
10.2.0.100  storage.oogiservices.net
10.2.0.100  streaming.oogiservices.net
10.2.0.100  streaming-za.oogiservices.net
10.2.0.100  metrics.oogiservices.net
10.2.0.100  synap-iot-production.azure-devices.net
10.2.0.100  staging-synapinc-iothub.azure-devices.net

# Additional entries needed if testing B2C auth or Blob Storage:
10.2.0.100  oogiservices.b2clogin.com
10.2.0.100  login.microsoftonline.com
10.2.0.100  YOUR_STORAGE_ACCOUNT.blob.core.windows.net
```

After editing, flush DNS: `ipconfig /flushdns`

**Remember:** `nslookup` bypasses the hosts file. Use `ping` to verify:
```cmd
ping api.oogiservices.net
# Should show 10.2.0.100, not a public Azure IP
```

---

## Rebuilding

If you need to modify tests or configuration and rebuild:

```cmd
cd C:\Dev\Repos\AliVpnTests
publish.bat
```

Or manually:
```cmd
dotnet publish -c Release -r win-x64 --self-contained -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o publish
```

The output in `publish\` is fully self-contained — no .NET runtime needed on the
factory PC.

---

## Troubleshooting Checklist

| Step | Check |
|------|-------|
| 1 | VPN connected? OpenVPN shows "Connected" with a `172.16.100.x` IP |
| 2 | Can you ping the China ECS private IP? `ping 10.2.0.100` |
| 3 | Hosts file correct? `ping api.oogiservices.net` returns `10.2.0.100` |
| 4 | DNS flushed? `ipconfig /flushdns` after any hosts file change |
| 5 | Security group open? TCP 443/1433/8883 from `172.16.100.0/24` |
| 6 | nginx running? SSH to ECS: `ss -tlnp \| grep -E '443\|1433\|8883'` |
| 7 | CEN link up? From China ECS: `nc -zv 10.1.1.96 443` |
| 8 | Connection strings valid? Check Azure Portal for current values |
