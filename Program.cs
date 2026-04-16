using Azure.Storage.Blobs;
using Microsoft.Azure.Devices.Client;
using Microsoft.Azure.Devices.Shared;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Configuration;
using System.Diagnostics;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;

// ─────────────────────────────────────────────────────────────
// Usage:
//   AliVpnTests.exe                              default mode, no file
//   AliVpnTests.exe results.txt                  default mode, save to file
//   AliVpnTests.exe -mode factory-gateway        gateway tests, no file
//   AliVpnTests.exe -mode factory-gateway out.txt
//   AliVpnTests.exe -mode no-gateway             same as default
// ─────────────────────────────────────────────────────────────
var (mode, outputFile) = ParseArgs(args);

if (outputFile != null)
{
    try
    {
        Out.File = new StreamWriter(outputFile, append: false,
            encoding: new UTF8Encoding(encoderShouldEmitUTF8Identifier: false))
        { AutoFlush = true };
    }
    catch (Exception ex)
    {
        Console.ForegroundColor = ConsoleColor.Red;
        Console.WriteLine($"  [ERROR] Cannot open output file '{outputFile}': {ex.Message}");
        Console.ResetColor();
        Environment.Exit(1);
    }
}

var config = new ConfigurationBuilder()
    .SetBasePath(AppContext.BaseDirectory)
    .AddJsonFile("appsettings.json")
    .Build();

Console.OutputEncoding = Encoding.UTF8;

var runTime    = DateTime.UtcNow;
var serial     = config["Device:Serial"] ?? "CHINA-QA-001";
var modeLabel  = mode == "factory-gateway" ? "Factory Gateway Verification" : "Device Connection Simulation";

// ── Header ────────────────────────────────────────────────────
Console.WriteLine();
Console.WriteLine("  ╔════════════════════════════════════════════════════════════╗");
Console.WriteLine($"  ║  OogiCam China Factory QA — {modeLabel,-32}║");
Console.WriteLine("  ╚════════════════════════════════════════════════════════════╝");
Console.WriteLine();

Out.F("OogiCam China Factory QA -- " + modeLabel);
Out.F($"Mode   : {mode}");
Out.F($"Run at : {runTime:yyyy-MM-dd HH:mm:ss} UTC");
Out.F($"Device : {serial}");

if (outputFile != null)
{
    Console.ForegroundColor = ConsoleColor.Cyan;
    Console.WriteLine($"  Output : {Path.GetFullPath(outputFile)}");
    Console.ResetColor();
    Console.WriteLine();
}

Out.F(new string('=', 72));
Out.F("");

var results = new List<(string Name, bool Pass, long Ms, string Detail)>();

// ── Route to correct test suite ───────────────────────────────
if (mode == "factory-gateway")
    await RunGatewayTests(config, results);
else
    await RunOriginalTests(config, results);

// ── Shared summary ────────────────────────────────────────────
var passed = results.Where(r => r.Pass).ToList();
var failed = results.Where(r => !r.Pass).ToList();

Console.WriteLine();
Console.WriteLine("  ══════════════════════════════════════════════════════════");
Console.WriteLine("  SUMMARY");
Console.WriteLine("  ──────────────────────────────────────────────────────────");
Console.ForegroundColor = ConsoleColor.Green;
Console.WriteLine($"  PASSED: {passed.Count}");
Console.ResetColor();
if (failed.Any())
{
    Console.ForegroundColor = ConsoleColor.Red;
    Console.WriteLine($"  FAILED: {failed.Count}");
    Console.ResetColor();
    foreach (var f in failed)
        Console.WriteLine($"    - {f.Name.Trim()}: {f.Detail}");
}
Console.WriteLine("  ──────────────────────────────────────────────────────────");
Console.WriteLine($"  Total: {results.Count} tests  |  {passed.Count} passed  |  {failed.Count} failed");
Console.WriteLine($"  Completed: {DateTime.UtcNow:yyyy-MM-dd HH:mm:ss} UTC");
Console.WriteLine("  ──────────────────────────────────────────────────────────");

Out.F("");
Out.F(new string('=', 72));
Out.F("SUMMARY");
Out.F(new string('-', 72));
Out.F($"PASSED : {passed.Count}");
Out.F($"FAILED : {failed.Count}");
if (failed.Any())
{
    Out.F("");
    Out.F("Failed tests:");
    foreach (var f in failed)
        Out.F($"  - {f.Name.Trim()}: {f.Detail}");
}
Out.F(new string('-', 72));
Out.F($"Total  : {results.Count} tests  |  {passed.Count} passed  |  {failed.Count} failed");
Out.F($"Completed : {DateTime.UtcNow:yyyy-MM-dd HH:mm:ss} UTC");
Out.F(new string('=', 72));
Out.Close();

if (outputFile != null)
{
    Console.WriteLine();
    Console.ForegroundColor = ConsoleColor.Cyan;
    Console.WriteLine($"  Results saved to: {Path.GetFullPath(outputFile)}");
    Console.ResetColor();
}

Console.WriteLine();
Console.Write("  Press any key to exit...");
Console.ReadKey();

// ═════════════════════════════════════════════════════════════
// GATEWAY TEST SUITE
// ═════════════════════════════════════════════════════════════
static async Task RunGatewayTests(
    IConfiguration config,
    List<(string, bool, long, string)> results)
{
    var gatewayIp      = config["FactoryGateway:GatewayIp"]        ?? "192.168.137.1";
    var vpnPrefix      = config["FactoryGateway:VpnSubnetPrefix"]   ?? "172.16.100.";
    var apiBase        = config["Api:BaseUrl"]                       ?? "https://api.oogiservices.net";
    var iotConn        = config["IotHub:DeviceConnectionString"]     ?? "";
    var serial         = config["Device:Serial"]                     ?? "CHINA-QA-001";

    // ── Detect role ───────────────────────────────────────────
    bool isGatewayPc = GetLocalIps().Any(ip => ip == gatewayIp);
    var  myIp        = GetLocalIps().FirstOrDefault(ip => ip.StartsWith("192.168.137.")) ?? "unknown";

    Console.ForegroundColor = ConsoleColor.Cyan;
    if (isGatewayPc)
    {
        Console.WriteLine("  Role: GATEWAY PC  (running on the factory gateway machine)");
        Out.F("Role: GATEWAY PC (running on the factory gateway machine)");
    }
    else
    {
        Console.WriteLine($"  Role: CONNECTED DEVICE  (hotspot client, local IP: {myIp})");
        Console.WriteLine($"  Testing gateway at: {gatewayIp}");
        Out.F($"Role: CONNECTED DEVICE (hotspot client, local IP: {myIp})");
        Out.F($"Testing gateway at: {gatewayIp}");
    }
    Console.ResetColor();
    Out.F("");

    // ─────────────────────────────────────────────────────────
    // SECTION 1: Gateway PC Health  (gateway PC only)
    // ─────────────────────────────────────────────────────────
    if (isGatewayPc)
    {
        PrintSection("GATEWAY PC HEALTH",
            "Checks that nginx and the Alibaba VPN are running on this machine.");

        // nginx process
        results.Add(await Run("nginx process running", () =>
        {
            var procs = Process.GetProcessesByName("nginx");
            if (!procs.Any()) throw new Exception("nginx.exe not found — run setup-gateway.bat");
            return Task.FromResult($"{procs.Length} worker(s)");
        }));

        // VPN connected
        results.Add(await Run($"Alibaba VPN connected ({vpnPrefix}x)", () =>
        {
            var vpnIp = GetLocalIps().FirstOrDefault(ip => ip.StartsWith(vpnPrefix));
            if (vpnIp == null) throw new Exception($"No {vpnPrefix}x IP found — connect OpenVPN first");
            return Task.FromResult($"VPN IP: {vpnIp}");
        }));

        // Hosts file entries
        var hostsPath    = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
                               @"drivers\etc\hosts");
        var hostsContent = File.Exists(hostsPath) ? File.ReadAllText(hostsPath) : "";
        var hostsChecks  = new[]
        {
            "api.oogiservices.net",
            "synap-iot-production.azure-devices.net",
            "streaming.oogiservices.net"
        };
        foreach (var host in hostsChecks)
        {
            var h = host; // capture
            results.Add(await Run($"Hosts file: {h}", () =>
            {
                if (!hostsContent.Contains(h))
                    throw new Exception($"Missing — run setup-gateway.bat");
                // Confirm it maps to the gateway IP
                var line = hostsContent.Split('\n')
                    .FirstOrDefault(l => l.Contains(h) && !l.TrimStart().StartsWith("#"));
                var mapsTo = line?.Trim().Split(new[]{' ','\t'}, StringSplitOptions.RemoveEmptyEntries)
                    .FirstOrDefault() ?? "?";
                return Task.FromResult($"→ {mapsTo}");
            }));
        }

        // nginx ports listening
        PrintSection("NGINX PORT LISTENERS",
            $"Confirms nginx is listening on {gatewayIp} for each proxied port.");

        foreach (var (label, port) in new[] { ("HTTPS :443", 443), ("MQTT :8883", 8883), ("SQL :1433", 1433) })
        {
            var p = port;
            results.Add(await Run($"nginx listening {label}", () =>
            {
                using var tcp = new TcpClient();
                try
                {
                    tcp.Connect(gatewayIp, p);
                    return Task.FromResult("listening");
                }
                catch
                {
                    throw new Exception($"nginx not listening on {gatewayIp}:{p} — check nginx config");
                }
            }));
        }
    }

    // ─────────────────────────────────────────────────────────
    // SECTION 2: Gateway Reachability  (both roles)
    // ─────────────────────────────────────────────────────────
    PrintSection("GATEWAY REACHABILITY",
        $"Confirms this machine can reach the gateway at {gatewayIp}.");

    results.Add(await Run($"Ping gateway ({gatewayIp})", async () =>
    {
        using var ping = new Ping();
        var reply = await ping.SendPingAsync(gatewayIp, 3000);
        if (reply.Status != IPStatus.Success)
            throw new Exception($"Ping failed: {reply.Status}");
        return $"{reply.RoundtripTime}ms";
    }));

    foreach (var (label, port) in new[] { ("HTTPS :443", 443), ("MQTT :8883", 8883), ("SQL :1433", 1433) })
    {
        var p = port;
        results.Add(await Run($"TCP connect gateway {label}", async () =>
        {
            using var tcp = new TcpClient();
            await tcp.ConnectAsync(gatewayIp, p);
            return "reachable";
        }));
    }

    // ─────────────────────────────────────────────────────────
    // SECTION 3: DNS Override Verification  (both roles)
    // ─────────────────────────────────────────────────────────
    PrintSection("DNS OVERRIDE VERIFICATION",
        $"Azure hostnames must resolve to {gatewayIp}, not public Azure IPs.");

    var dnsHosts = new[]
    {
        "api.oogiservices.net",
        "synap-iot-production.azure-devices.net",
        "streaming.oogiservices.net",
        "storage.oogiservices.net"
    };

    foreach (var host in dnsHosts)
    {
        var h = host;
        results.Add(await Run($"DNS: {h}", async () =>
        {
            var addresses = await Dns.GetHostAddressesAsync(h);
            var resolved  = addresses.FirstOrDefault()?.ToString() ?? "no result";
            if (resolved != gatewayIp)
                throw new Exception($"Resolved to {resolved} (expected {gatewayIp}) — hosts file not active or DNS not flushed");
            return $"→ {resolved} ✓";
        }));
    }

    // ─────────────────────────────────────────────────────────
    // SECTION 4: End-to-End Proxy Chain  (both roles)
    // ─────────────────────────────────────────────────────────
    PrintSection("END-TO-END PROXY CHAIN",
        "Full round-trips: device → gateway nginx → VPN → China ECS → CEN → Azure.");

    // HTTPS API
    results.Add(await Run("HTTPS  api.oogiservices.net",
        () => HttpGetTest($"{apiBase}/swagger/index.html")));

    // HTTPS streaming
    results.Add(await Run("HTTPS  streaming.oogiservices.net",
        () => TcpTestLabeled("streaming.oogiservices.net", 443)));

    // MQTT IoT Hub TCP
    results.Add(await Run("MQTT   synap-iot-production.azure-devices.net:8883",
        () => TcpTestLabeled("synap-iot-production.azure-devices.net", 8883)));

    // ─────────────────────────────────────────────────────────
    // SECTION 5: IoT Hub Device Simulation  (optional, needs creds)
    // ─────────────────────────────────────────────────────────
    PrintSection("IOT HUB DEVICE SIMULATION",
        "Full MQTT device lifecycle through the gateway proxy chain.");

    if (iotConn.Contains("YOUR_"))
    {
        PrintSkip("IoT Hub simulation", "device connection string not configured in appsettings.json");
    }
    else
    {
        var vehicleId = config["Device:VehicleId"] ?? "QA_VEHICLE_001";
        var driverId  = config["Device:DriverId"]  ?? "QA_DRIVER_001";

        DeviceClient? deviceClient = null;
        try
        {
            results.Add(await Run("MQTT Connect", async () =>
            {
                deviceClient = DeviceClient.CreateFromConnectionString(iotConn, TransportType.Mqtt,
                    new ClientOptions { SdkAssignsMessageId = SdkAssignsMessageId.WhenUnset });
                await deviceClient.OpenAsync().WaitAsync(TimeSpan.FromSeconds(20));
                return "connected via gateway proxy";
            }));

            if (deviceClient == null) throw new Exception("Connect failed");

            results.Add(await Run("Get Device Twin", async () =>
            {
                var twin = await deviceClient.GetTwinAsync().WaitAsync(TimeSpan.FromSeconds(15));
                return $"desired v{twin.Properties.Desired.Version}, reported v{twin.Properties.Reported.Version}";
            }));

            results.Add(await Run("Report Properties", async () =>
            {
                var reported = new TwinCollection
                {
                    ["applicationVersion"]        = "gateway-qa-test-1.0",
                    ["vehicleBatteryLevel"]        = "12.6",
                    ["hasWifiNetworkConnection"]   = true,
                    ["hasMobileNetworkConnection"] = false,
                    ["networkConnectionTimestamp"] = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
                    ["os_build_id"]                = "gateway-qa-sim"
                };
                await deviceClient.UpdateReportedPropertiesAsync(reported).WaitAsync(TimeSpan.FromSeconds(15));
                return $"{reported.Count} properties reported";
            }));

            results.Add(await Run("Send Telemetry", async () =>
            {
                var telemetry = new
                {
                    serial = serial,
                    header = new
                    {
                        localDateTime  = DateTime.UtcNow.ToString("O"),
                        location       = new { type = "Point", coordinates = new[] { 113.264, 23.129 },
                                               locationPrecision = 10.5, bearing = 0.0,
                                               bearingPrecision = 5.0,
                                               locationTimestamp = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() },
                        signalStrength = -85, signalNetwork = 4
                    },
                    @event = new
                    {
                        eventSequence = 1, eventType = 5, reason = 2,
                        videoFileName = "",
                        extraEventInfo = "{\"source\":\"gateway-qa\"}",
                        gpsSpeed = 0.0, vehicleID = vehicleId, driverID = driverId,
                        tripID = $"GW_TRIP_{DateTime.UtcNow:yyyyMMdd_HHmmss}", canSpeed = 0
                    }
                };
                var json = JsonSerializer.Serialize(telemetry);
                await deviceClient.SendEventAsync(
                    new Message(Encoding.UTF8.GetBytes(json))
                    { ContentType = "application/json", ContentEncoding = "utf-8" })
                    .WaitAsync(TimeSpan.FromSeconds(15));
                return $"event sent ({json.Length} bytes)";
            }));

            results.Add(await Run("Close Connection", async () =>
            {
                await deviceClient.CloseAsync().WaitAsync(TimeSpan.FromSeconds(10));
                deviceClient.Dispose();
                return "cleanly disconnected";
            }));
        }
        catch (Exception ex)
        {
            var msg = $"  IoT Hub simulation aborted: {ex.Message}";
            Console.ForegroundColor = ConsoleColor.Red;
            Console.WriteLine($"\n{msg}");
            Console.ResetColor();
            Out.F(msg);
            if (deviceClient != null)
                try { await deviceClient.CloseAsync(); deviceClient.Dispose(); } catch { }
        }
    }
}

// ═════════════════════════════════════════════════════════════
// ORIGINAL TEST SUITE  (default / no-gateway mode)
// ═════════════════════════════════════════════════════════════
static async Task RunOriginalTests(
    IConfiguration config,
    List<(string, bool, long, string)> results)
{
    var apiBase   = config["Api:BaseUrl"] ?? "https://api.oogiservices.net";
    var serial    = config["Device:Serial"] ?? "CHINA-QA-001";
    var iotConn   = config["IotHub:DeviceConnectionString"] ?? "";
    var sqlConn   = config["SqlServer:ConnectionString"] ?? "";
    var blobConn  = config["BlobStorage:ConnectionString"] ?? "";

    var tcpEndpoints  = config.GetSection("TcpEndpoints").GetChildren().ToList();
    var httpEndpoints = config.GetSection("HttpEndpoints").GetChildren().ToList();

    // Section 1: TCP
    PrintSection("TCP PORT CONNECTIVITY",
        "Raw TCP connections through VPN + nginx proxy chain. No credentials.");
    foreach (var ep in tcpEndpoints)
        results.Add(await Run(
            $"{ep["Name"]!,-28} {ep["Host"]}:{ep["Port"]}",
            () => TcpTest(ep["Host"]!, int.Parse(ep["Port"]!))));

    // Section 2: HTTPS
    PrintSection("HTTPS ENDPOINTS",
        "Full TLS handshake + HTTP response through the proxy chain.");
    foreach (var ep in httpEndpoints)
        results.Add(await Run(
            $"{ep["Name"]!,-28} {ep["Url"]![..Math.Min(ep["Url"]!.Length, 55)]}",
            () => HttpGetTest(ep["Url"]!)));

    // Section 3: Device API
    PrintSection("DEVICE API ENDPOINTS",
        "HTTP calls the OogiCam device makes to api.oogiservices.net.");
    results.Add(await Run("API Root (→ Swagger redirect)",   () => HttpGetTest($"{apiBase}/")));
    results.Add(await Run("Device Config Patch Endpoint",
        () => HttpGetTest($"{apiBase}/DeviceAppVersion/sca/patch/config/1.0.0/serial/{serial}")));
    results.Add(await Run("Speed Test Download (1KB)",
        () => HttpDownloadTest($"{apiBase}/SpeedTest/download?size=1024")));

    // Section 4: IoT Hub simulation
    PrintSection("IOT HUB DEVICE SIMULATION",
        "Simulates full OogiCam device lifecycle: connect, twin, telemetry, methods.");

    if (iotConn.Contains("YOUR_"))
    {
        PrintSkip("IoT Hub simulation", "device connection string not configured in appsettings.json");
    }
    else
    {
        var vehicleId = config["Device:VehicleId"] ?? "QA_VEHICLE_001";
        var driverId  = config["Device:DriverId"]  ?? "QA_DRIVER_001";
        var deviceSerial = config["Device:Serial"] ?? "CHINA-QA-001";

        Console.WriteLine();
        Console.ForegroundColor = ConsoleColor.Cyan;
        Console.WriteLine("  ── Device Connection Lifecycle ──");
        Console.ResetColor();
        Console.WriteLine();
        Out.F("  -- Device Connection Lifecycle --");
        Out.F("");

        DeviceClient? deviceClient = null;
        try
        {
            results.Add(await Run("MQTT Connect (OpenAsync)", async () =>
            {
                deviceClient = DeviceClient.CreateFromConnectionString(iotConn, TransportType.Mqtt,
                    new ClientOptions { SdkAssignsMessageId = SdkAssignsMessageId.WhenUnset });
                await deviceClient.OpenAsync().WaitAsync(TimeSpan.FromSeconds(20));
                return "MQTT connected to IoT Hub";
            }));
            if (deviceClient == null) throw new Exception("Connect failed");

            results.Add(await Run("Get Device Twin", async () =>
            {
                var twin = await deviceClient.GetTwinAsync().WaitAsync(TimeSpan.FromSeconds(15));
                return $"desired v{twin.Properties.Desired.Version}, reported v{twin.Properties.Reported.Version}";
            }));

            results.Add(await Run("Report Properties (startup)", async () =>
            {
                var reported = new TwinCollection
                {
                    ["applicationVersion"]          = "china-qa-test-1.0",
                    ["vehicleBatteryLevel"]          = "12.6",
                    ["hasWifiNetworkConnection"]     = true,
                    ["hasMobileNetworkConnection"]   = false,
                    ["networkConnectionTimestamp"]   = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
                    ["ignition"]                     = true,
                    ["ignitionTimestamp"]            = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
                    ["wifiIpAddress"]                = "192.168.137.100",
                    ["assignedCameraPositions"]      = "AIR,AIC",
                    ["activeCameraPositions"]        = "AIR,AIC",
                    ["os_build_id"]                  = "china-qa-sim"
                };
                await deviceClient.UpdateReportedPropertiesAsync(reported).WaitAsync(TimeSpan.FromSeconds(15));
                return $"{reported.Count} properties reported";
            }));

            results.Add(await Run("Subscribe Desired Properties", async () =>
            {
                await deviceClient.SetDesiredPropertyUpdateCallbackAsync((props, ctx) =>
                {
                    var line = $"  <- Desired property update: {props.ToJson()}";
                    Console.ForegroundColor = ConsoleColor.Yellow;
                    Console.WriteLine($"\n{line}");
                    Console.ResetColor();
                    Out.F(line);
                    return Task.CompletedTask;
                }, null);
                return "subscribed (listening for cloud config changes)";
            }));

            results.Add(await Run("Subscribe Direct Methods", async () =>
            {
                await deviceClient.SetMethodDefaultHandlerAsync((req, ctx) =>
                {
                    var line = $"  <- Direct method: {req.Name}, payload: {req.DataAsJson}";
                    Console.ForegroundColor = ConsoleColor.Yellow;
                    Console.WriteLine($"\n{line}");
                    Console.ResetColor();
                    Out.F(line);
                    return Task.FromResult(new MethodResponse(
                        Encoding.UTF8.GetBytes("{\"status\":\"ok\"}"), 200));
                }, null);
                return "subscribed (listening for remote commands)";
            }));

            results.Add(await Run("Send Telemetry (OogiCam event)", async () =>
            {
                var telemetry = new
                {
                    serial = deviceSerial,
                    header = new
                    {
                        localDateTime  = DateTime.UtcNow.ToString("O"),
                        location       = new { type = "Point", coordinates = new[] { 113.264, 23.129 },
                                               locationPrecision = 10.5, bearing = 180.0,
                                               bearingPrecision = 2.0,
                                               locationTimestamp = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() },
                        signalStrength = -85, signalNetwork = 4
                    },
                    @event = new
                    {
                        eventSequence = 1, eventType = 5, reason = 2,
                        videoFileName = "", extraEventInfo = "{}",
                        gpsSpeed = 0.0, vehicleID = vehicleId, driverID = driverId,
                        tripID = $"QA_TRIP_{DateTime.UtcNow:yyyyMMdd_HHmmss}", canSpeed = 0
                    }
                };
                var json = JsonSerializer.Serialize(telemetry);
                await deviceClient.SendEventAsync(
                    new Message(Encoding.UTF8.GetBytes(json))
                    { ContentType = "application/json", ContentEncoding = "utf-8" })
                    .WaitAsync(TimeSpan.FromSeconds(15));
                return $"event sent ({json.Length} bytes)";
            }));

            results.Add(await Run("Send Telemetry (2nd message)", async () =>
            {
                var telemetry2 = new
                {
                    serial = deviceSerial,
                    header = new
                    {
                        localDateTime  = DateTime.UtcNow.ToString("O"),
                        location       = new { type = "Point", coordinates = new[] { 113.264, 23.129 },
                                               locationPrecision = 10.5, bearing = 0.0,
                                               bearingPrecision = 5.0,
                                               locationTimestamp = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() },
                        signalStrength = -90, signalNetwork = 4
                    },
                    @event = new
                    {
                        eventSequence = 2, eventType = 1, reason = 1,
                        videoFileName = "", extraEventInfo = "{\"source\":\"china-qa-simulation\"}",
                        gpsSpeed = 0.0, vehicleID = vehicleId, driverID = driverId,
                        tripID = $"QA_TRIP_{DateTime.UtcNow:yyyyMMdd_HHmmss}", canSpeed = 0
                    }
                };
                var json = JsonSerializer.Serialize(telemetry2);
                await deviceClient.SendEventAsync(
                    new Message(Encoding.UTF8.GetBytes(json))
                    { ContentType = "application/json", ContentEncoding = "utf-8" })
                    .WaitAsync(TimeSpan.FromSeconds(15));
                return $"event sent ({json.Length} bytes)";
            }));

            results.Add(await Run("Update Reported Props (runtime)", async () =>
            {
                var updated = new TwinCollection
                {
                    ["vehicleBatteryLevel"]        = "12.4",
                    ["networkConnectionTimestamp"] = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
                    ["desiredPropertiesVersion"]   = 0
                };
                await deviceClient.UpdateReportedPropertiesAsync(updated).WaitAsync(TimeSpan.FromSeconds(15));
                return $"{updated.Count} properties updated";
            }));

            results.Add(await Run("Close Connection", async () =>
            {
                await deviceClient.CloseAsync().WaitAsync(TimeSpan.FromSeconds(10));
                deviceClient.Dispose();
                return "cleanly disconnected";
            }));
        }
        catch (Exception ex)
        {
            var msg = $"  IoT Hub simulation aborted: {ex.Message}";
            Console.ForegroundColor = ConsoleColor.Red;
            Console.WriteLine($"\n{msg}");
            Console.ResetColor();
            Out.F(msg);
            if (deviceClient != null)
                try { await deviceClient.CloseAsync(); deviceClient.Dispose(); } catch { }
        }
    }

    // Section 5: Backend services
    PrintSection("BACKEND SERVICES (API-side, not device)",
        "SQL and Blob are used by the API, not the device. Tests proxy chain.");
    if (sqlConn.Contains("YOUR_"))
        PrintSkip("SQL Server", "not configured — device does not use SQL directly");
    else
        results.Add(await Run("SQL Server (backend)", () => SqlTest(sqlConn)));

    if (blobConn.Contains("YOUR_"))
        PrintSkip("Blob Storage", "not configured");
    else
        results.Add(await Run("Blob Storage (backend)", () => BlobTest(blobConn)));
}

// ═════════════════════════════════════════════════════════════
// Argument parsing
// ═════════════════════════════════════════════════════════════
static (string mode, string? outputFile) ParseArgs(string[] args)
{
    string  mode       = "default";
    string? outputFile = null;

    for (int i = 0; i < args.Length; i++)
    {
        if (args[i] == "-mode" && i + 1 < args.Length)
            mode = args[++i].ToLower().Trim();
        else if (!args[i].StartsWith("-"))
            outputFile = args[i];
    }

    if (mode == "no-gateway") mode = "default";
    return (mode, outputFile);
}

// ═════════════════════════════════════════════════════════════
// Network helpers
// ═════════════════════════════════════════════════════════════
static IEnumerable<string> GetLocalIps() =>
    NetworkInterface.GetAllNetworkInterfaces()
        .Where(ni => ni.OperationalStatus == OperationalStatus.Up)
        .SelectMany(ni => ni.GetIPProperties().UnicastAddresses)
        .Where(a => a.Address.AddressFamily == AddressFamily.InterNetwork)
        .Select(a => a.Address.ToString());

// ═════════════════════════════════════════════════════════════
// Test implementations
// ═════════════════════════════════════════════════════════════
static async Task<string> TcpTest(string host, int port)
{
    using var tcp = new TcpClient();
    await tcp.ConnectAsync(host, port);
    return "connected";
}

static async Task<string> TcpTestLabeled(string host, int port)
{
    using var tcp = new TcpClient();
    await tcp.ConnectAsync(host, port);
    return $"TCP connected to {host}:{port}";
}

static async Task<string> HttpGetTest(string url)
{
    using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };
    var response = await http.GetAsync(url);
    return $"HTTP {(int)response.StatusCode} ({response.StatusCode})";
}

static async Task<string> HttpDownloadTest(string url)
{
    using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };
    var sw       = Stopwatch.StartNew();
    var response = await http.GetAsync(url);
    var bytes    = await response.Content.ReadAsByteArrayAsync();
    sw.Stop();
    return $"HTTP {(int)response.StatusCode}, {bytes.Length} bytes in {sw.ElapsedMilliseconds}ms";
}

static async Task<string> SqlTest(string connectionString)
{
    using var conn = new SqlConnection(connectionString);
    await conn.OpenAsync();
    using var cmd = conn.CreateCommand();
    cmd.CommandText = "SELECT @@VERSION";
    var version   = (await cmd.ExecuteScalarAsync())?.ToString() ?? "connected";
    var firstLine = version.Split('\n')[0].Trim();
    return firstLine[..Math.Min(firstLine.Length, 60)];
}

static async Task<string> BlobTest(string connectionString)
{
    var serviceClient = new BlobServiceClient(connectionString);
    await serviceClient.GetPropertiesAsync();
    return "storage account reachable";
}

// ═════════════════════════════════════════════════════════════
// Output helpers
// ═════════════════════════════════════════════════════════════
static async Task<(string, bool, long, string)> Run(string name, Func<Task<string>> action)
{
    Console.Write($"  {name,-60}");
    var sw = Stopwatch.StartNew();
    string detail; bool pass; string result;

    try
    {
        detail = await action().WaitAsync(TimeSpan.FromSeconds(25));
        sw.Stop();
        Console.ForegroundColor = ConsoleColor.Green;
        Console.Write(" PASS");
        Console.ResetColor();
        Console.WriteLine($"  {sw.ElapsedMilliseconds,5}ms  {detail}");
        result = "PASS"; pass = true;
    }
    catch (TimeoutException)
    {
        sw.Stop();
        detail = "timed out (25s) — connection hung";
        Console.ForegroundColor = ConsoleColor.Red;
        Console.Write(" FAIL");
        Console.ResetColor();
        Console.WriteLine($"  {sw.ElapsedMilliseconds,5}ms  {detail}");
        result = "FAIL"; pass = false;
    }
    catch (Exception ex)
    {
        sw.Stop();
        detail = ex.InnerException?.Message ?? ex.Message;
        if (detail.Length > 120) detail = detail[..120] + "...";
        Console.ForegroundColor = ConsoleColor.Red;
        Console.Write(" FAIL");
        Console.ResetColor();
        Console.WriteLine($"  {sw.ElapsedMilliseconds,5}ms  {detail}");
        result = "FAIL"; pass = false;
    }

    Out.F($"  {name,-60} {result,-4}  {sw.ElapsedMilliseconds,5}ms  {detail}");
    return (name, pass, sw.ElapsedMilliseconds, detail);
}

static void PrintSection(string title, string info)
{
    Console.WriteLine();
    Console.WriteLine($"  ══ {title} ═══════════════════════════════════════════");
    Console.ForegroundColor = ConsoleColor.DarkGray;
    Console.WriteLine($"  {info}");
    Console.ResetColor();
    Console.WriteLine();
    Out.F("");
    Out.F($"== {title}");
    Out.F($"   {info}");
    Out.F("");
}

static void PrintSkip(string name, string reason)
{
    Console.ForegroundColor = ConsoleColor.Yellow;
    Console.Write($"  {name,-60} SKIP");
    Console.ResetColor();
    Console.WriteLine($"  {reason}");
    Out.F($"  {name,-60} SKIP  {reason}");
}

// ═════════════════════════════════════════════════════════════
// Static file writer
// ═════════════════════════════════════════════════════════════
static class Out
{
    public static StreamWriter? File { get; set; }
    public static void F(string line) => File?.WriteLine(line);
    public static void Close() { File?.Flush(); File?.Close(); File = null; }
}
