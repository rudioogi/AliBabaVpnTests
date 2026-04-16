# OogiCam China Factory QA — Test Tool Guide

Self-contained test tool that simulates an OogiCam Android device connecting
to Azure services through the China VPN + nginx proxy chain.

No .NET runtime required — the published exe includes everything.

---

## What This Tool Tests

The tool runs 5 test sections in order. Each section builds on the previous —
if TCP fails, HTTPS will also fail, and so on.

### Section 1: TCP Port Connectivity
**No credentials needed.**

Opens raw TCP sockets to each Azure service endpoint. Tests whether the
VPN + nginx proxy chain is routing traffic correctly.

| Endpoint | Port | What it proves |
|----------|------|---------------|
| api.oogiservices.net | 443 | API reachable |
| streaming.oogiservices.net | 443 | Streaming server reachable |
| streaming-za.oogiservices.net | 443 | ZA streaming reachable |
| storage.oogiservices.net | 443 | Storage CDN reachable |
| synap-iot-production.azure-devices.net | 8883 | IoT Hub MQTT reachable |
| staging-synapinc-iothub.azure-devices.net | 8883 | Staging IoT Hub reachable |
| oogiservices.b2clogin.com | 443 | B2C authentication reachable |
| login.microsoftonline.com | 443 | Azure AD reachable |

**If a test fails here:** the hostname is missing from the hosts file, the
security group is blocking the port, or nginx isn't listening.

### Section 2: HTTPS Endpoint Tests
**No credentials needed.**

Makes full HTTPS requests (TLS handshake + HTTP GET) to endpoints that don't
require authentication. Proves the entire chain works end-to-end including
TLS certificate validation against Azure's real certificates.

| Endpoint | Expected |
|----------|----------|
| API Swagger page | HTTP 200 |
| B2C OpenID configuration | HTTP 200 (JSON) |
| Azure AD OpenID configuration | HTTP 200 (JSON) |

**If TCP passed but HTTPS fails:** the US ECS nginx may need SNI-based routing
to handle multiple hostnames on port 443 (see the factory-pc-gateway README).

### Section 3: Device API Endpoints
**No credentials needed.**

Simulates the HTTP calls that the OogiCam Android app makes to the API:

| Call | What the device does |
|------|---------------------|
| API Root | Loads the API base URL (redirects to Swagger) |
| Config Patch | `GET /DeviceAppVersion/sca/patch/config/{version}/serial/{serial}` — checks for config updates |
| Speed Test | `GET /SpeedTest/download?size=1024` — bandwidth test |

The serial number used is configured in `appsettings.json` under `Device.Serial`.

**Expected:** HTTP 200 or 401 (Unauthorized is fine — it means the API is
reachable and responding, just needs auth).

### Section 4: IoT Hub Device Simulation
**Requires IoT Hub device connection string.**

This is the core test. It simulates the full OogiCam device connection lifecycle
in the exact order the real device does it:

```
Step 1: MQTT Connect
  └─ DeviceClient.OpenAsync() with MQTT transport
  └─ Same as MyIOTConnection.createDeviceClient()

Step 2: Get Device Twin
  └─ Reads desired + reported property versions
  └─ Same as DeviceTwins.twin = client.getTwin()

Step 3: Report Startup Properties
  └─ Reports 11 key device properties:
     applicationVersion, vehicleBatteryLevel, hasWifiNetworkConnection,
     hasMobileNetworkConnection, networkConnectionTimestamp, ignition,
     ignitionTimestamp, wifiIpAddress, assignedCameraPositions,
     activeCameraPositions, os_build_id
  └─ Same as DeviceTwins.reportProperties()

Step 4: Subscribe to Desired Properties
  └─ Listens for cloud-to-device config changes
  └─ Same as deviceClient.subscribeToDesiredProperties()

Step 5: Subscribe to Direct Methods
  └─ Listens for remote commands (start streaming, update, etc.)
  └─ Same as deviceClient.subscribeToMethods()

Step 6: Send Telemetry (1st event)
  └─ Sends a realistic OogiCam telemetry event in the exact JSON format:
     { serial, header: { localDateTime, location: { type, coordinates, ... },
       signalStrength }, event: { eventType, vehicleID, driverID, ... } }
  └─ Location is set to Guangzhou (113.264, 23.129)
  └─ Same as HubMessenger.MessageSender

Step 7: Send Telemetry (2nd event)
  └─ Confirms the MQTT connection is sustained, not just a one-shot

Step 8: Update Reported Properties (runtime)
  └─ Updates battery level and network timestamp
  └─ Same as DeviceTwins.reportWithUpdatedNetworkConnectionProperties()

Step 9: Close Connection
  └─ Clean MQTT disconnect
```

**If this section passes**, an actual OogiCam device will be able to connect
to IoT Hub through the proxy chain. The test uses the same protocol (MQTT),
same message format, and same twin/method subscription pattern.

**If it fails at "MQTT Connect":** port 8883 is blocked (check TCP test) or
the connection string is wrong.

**If it fails at "Send Telemetry":** the MQTT connection established but the
proxy chain dropped the sustained connection. Check nginx timeouts.

### Section 5: Backend Services
**Requires SQL/Blob connection strings.**

These are NOT device connections — the OogiCam device never connects to SQL
Server or Blob Storage directly. These test the proxy chain for the backend
API services:

| Service | Protocol | Port | What it tests |
|---------|----------|------|--------------|
| SQL Server | TDS | 1433 | Opens connection, runs `SELECT @@VERSION` |
| Blob Storage | HTTPS | 443 | Connects and retrieves storage properties |

**These are optional.** If you don't configure the connection strings, they
are automatically skipped (shown as SKIP, not FAIL).

---

## Setup

### 1. Deploy to Factory PC

Copy the `publish` folder to the factory PC:

```
publish\
├── AliVpnTests.exe      (~80MB, self-contained)
└── appsettings.json      (edit this)
```

### 2. Configure appsettings.json

Open `appsettings.json` in a text editor and fill in your values:

#### Required: IoT Hub Device Connection String

```json
"IotHub": {
    "DeviceConnectionString": "HostName=synap-iot-production.azure-devices.net;DeviceId=YOUR_DEVICE_ID;SharedAccessKey=YOUR_KEY"
}
```

**Where to find it:**
Azure Portal → IoT Hub → `synap-iot-production` → Devices → select a test
device → **Primary Connection String**

Use a dedicated QA test device, not a production device. The test will write
to the device's reported properties and send telemetry events.

#### Required: Device Identity

```json
"Device": {
    "Serial": "CHINA-QA-001",
    "VehicleId": "QA_VEHICLE_001",
    "DriverId": "QA_DRIVER_001"
}
```

Set these to match your QA test identifiers. The serial is included in every
telemetry message and the API config endpoint call.

#### Optional: SQL Server

```json
"SqlServer": {
    "ConnectionString": "Server=YOUR_SERVER.database.windows.net;Database=YOUR_DB;User Id=YOUR_USER;Password=YOUR_PASSWORD;TrustServerCertificate=True;Encrypt=True;"
}
```

**Where to find it:** Azure Portal → SQL Database → Connection strings, or the
`SqlDBConnection` environment variable from the Synap.Api deployment.

Leave as `YOUR_*` to skip this test.

#### Optional: Blob Storage

```json
"BlobStorage": {
    "ConnectionString": "DefaultEndpointsProtocol=https;AccountName=YOUR_ACCOUNT;AccountKey=YOUR_KEY;EndpointSuffix=core.windows.net"
}
```

**Where to find it:** Azure Portal → Storage Account → Access keys, or the
`AzureBlobConnectionString` environment variable from the Synap.Api deployment.

Leave as `YOUR_*` to skip this test.

### 3. Configure Custom TCP/HTTP Endpoints (Optional)

The `TcpEndpoints` and `HttpEndpoints` arrays in appsettings.json can be
modified to add or remove endpoints:

```json
"TcpEndpoints": [
    { "Name": "My Service", "Host": "myservice.example.com", "Port": 443 }
]
```

---

## Running the Tests

### Prerequisites

Before running, ensure:

1. **VPN connected** — OpenVPN client showing connected
2. **Hosts file updated** — Azure hostnames pointing to China ECS private IP
   (or running via the factory PC gateway setup)
3. **DNS flushed** — `ipconfig /flushdns` after any hosts file changes

### Execute

Double-click `AliVpnTests.exe` or run from command prompt:

```cmd
cd publish
AliVpnTests.exe
```

The tool runs all tests sequentially and displays results in real-time. Each
test shows PASS/FAIL, latency in milliseconds, and a detail message.

### Expected Output (All Passing)

```
  ══ TCP PORT CONNECTIVITY ══════════════════════════════
  API (HTTPS)              api.oogiservices.net:443       PASS     45ms  connected
  IoT Hub (MQTT)           synap-iot-production...:8883   PASS     52ms  connected
  ...

  ══ IOT HUB DEVICE SIMULATION ══════════════════════════
  MQTT Connect (OpenAsync)                                PASS   1245ms  MQTT connected to IoT Hub
  Get Device Twin                                         PASS    320ms  desired v15, reported v42
  Report Properties (startup)                             PASS    185ms  11 properties reported
  Subscribe Desired Properties                            PASS     92ms  subscribed
  Subscribe Direct Methods                                PASS     88ms  subscribed
  Send Telemetry (OogiCam event)                          PASS    210ms  event sent (412 bytes)
  Send Telemetry (2nd message)                            PASS    145ms  event sent (425 bytes)
  Update Reported Props (runtime)                         PASS    175ms  3 properties updated
  Close Connection                                        PASS    120ms  cleanly disconnected

  ══════════════════════════════════════════════════════
  SUMMARY
  PASSED: 18
  FAILED: 0
  Total: 18 tests, 18 passed, 0 failed
```

---

## Interpreting Failures

### TCP FAIL → everything else will also fail

The network path is broken. Fix the TCP layer first:

1. Is the hostname in the hosts file? → `ping <hostname>` should return the
   China ECS private IP, not a public Azure IP
2. Is the VPN connected? → `ipconfig | findstr 172.16.100`
3. Is the security group open? → Alibaba console → ECS → Security Groups
4. Is nginx listening? → SSH to ECS: `ss -tlnp | grep <port>`
5. Is the CEN link up? → From China ECS: `nc -zv 10.1.1.96 <port>`

### HTTPS FAIL but TCP PASS → TLS or routing issue

The TCP connection works but TLS failed. Most likely:
- The US ECS nginx doesn't support SNI routing for that hostname
- The upstream Azure service is unreachable from the US ECS

Check the US ECS nginx config — it may need `ssl_preread` with SNI-based
routing for multiple port 443 backends.

### IoT Hub "MQTT Connect" FAIL → port 8883 issue

- Check TCP test for port 8883 first
- Verify the device connection string is correct (HostName, DeviceId, SharedAccessKey)
- Check the device exists in the IoT Hub: Azure Portal → IoT Hub → Devices

### IoT Hub "Send Telemetry" FAIL but "Connect" PASS → proxy timeout

The MQTT connection was established but dropped during use. The nginx proxy
may be closing idle connections too quickly. On the China ECS, check the
nginx stream timeout:

```nginx
stream {
    server {
        listen 8883;
        proxy_pass 10.1.1.96:8883;
        proxy_connect_timeout 10s;
        proxy_timeout 300s;        # ← add this (keep MQTT alive for 5 min)
    }
}
```

Reload nginx after changes: `nginx -s reload`

### API endpoints return HTTP 401 (Unauthorized)

This is **not a failure** — it means the API is reachable and responding. The
device normally authenticates via Azure AD B2C tokens. A 401 confirms network
connectivity is working; the API is just rejecting the unauthenticated request.

### "Timed out (25s)" on any test

The connection hung — traffic is being silently dropped rather than actively
rejected. Common causes:
- Security group rule missing (traffic dropped, no RST sent)
- GFW silently dropping packets (if hosts file has wrong IP)
- VPN disconnected mid-test

---

## Verifying Results in Azure

After a successful test run, you can verify the telemetry arrived:

### IoT Hub — Check Device Twin

Azure Portal → IoT Hub → Devices → select the test device → **Device Twin**

Look for the reported properties set by the test:

```json
"reported": {
    "applicationVersion": "china-qa-test-1.0",
    "vehicleBatteryLevel": "12.4",
    "hasWifiNetworkConnection": true,
    "os_build_id": "china-qa-sim",
    ...
}
```

### IoT Hub — Check Telemetry

Use Azure IoT Explorer or Azure CLI to monitor the telemetry stream:

```bash
az iot hub monitor-events --hub-name synap-iot-production --device-id YOUR_DEVICE_ID
```

You should see the test events with `"serial": "CHINA-QA-001"` and
`"source": "china-qa-simulation"` in the extraEventInfo.

### Send a Direct Method (Optional)

While the test is running (during the Subscribe Direct Methods → Close
Connection window), you can invoke a direct method from the Azure Portal:

Azure Portal → IoT Hub → Devices → test device → **Direct Method**

- Method name: `35` (CMD_REQUEST_NETWORK_CONNECTION_TYPE_UPDATE)
- Payload: `{"id":"35","value":""}`

The test tool will print the received method invocation in yellow.

---

## Rebuilding

If you modify the tests or appsettings structure:

```cmd
cd C:\Dev\Repos\AliVpnTests
publish.bat
```

Or manually:

```cmd
dotnet publish -c Release -r win-x64 --self-contained -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o publish
```

Copy the updated `publish\` folder to the factory PC.

---

## File Reference

```
C:\Dev\Repos\AliVpnTests\
├── AliVpnTests.csproj         Project file (NuGet packages, build config)
├── Program.cs                  All test logic
├── appsettings.json            Connection strings and endpoints
├── publish.bat                 One-click build script
├── TESTING-GUIDE.md            This file
├── README.md                   Architecture and setup overview
├── publish\                    Self-contained output (copy to factory PC)
│   ├── AliVpnTests.exe
│   └── appsettings.json
└── factory-pc-gateway\         Windows gateway scripts for Android devices
    ├── setup-gateway.bat
    ├── verify-gateway.bat
    ├── teardown-gateway.bat
    ├── README.md
    └── nginx\                  Extract nginx for Windows here
```
