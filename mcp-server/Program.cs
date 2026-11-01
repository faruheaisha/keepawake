using System.Collections.Concurrent;
using System.ComponentModel;
using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using ModelContextProtocol;
using ModelContextProtocol.Server;

// The MCP process is optional. The existing Windows PowerShell engine remains the
// only owner of power requests and all lease transitions are serialized there.
var configuredRoot = Environment.GetEnvironmentVariable("KEEP_AWAKE_ROOT");
var root = FindRoot(configuredRoot);
var session = new LeaseSession(root);
Tools.Session = session;
var builder = Host.CreateApplicationBuilder(args);
builder.Logging.ClearProviders();
builder.Logging.AddConsole(options => options.LogToStandardErrorThreshold = LogLevel.Trace);
builder.Services.AddMcpServer().WithStdioServerTransport().WithToolsFromAssembly();
try { await builder.Build().RunAsync(); }
finally { await session.DisposeAsync(); }

static string FindRoot(string? configured)
{
    if (!string.IsNullOrWhiteSpace(configured))
    {
        var explicitRoot = Path.GetFullPath(configured);
        if (File.Exists(Path.Combine(explicitRoot, "integrations", "mcp", "bridge.ps1"))) return explicitRoot;
        throw new InvalidOperationException("KEEP_AWAKE_ROOT does not contain the KeepAwake bridge.");
    }
    for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
        if (File.Exists(Path.Combine(dir.FullName, "integrations", "mcp", "bridge.ps1"))) return dir.FullName;
    throw new InvalidOperationException("KeepAwake was not found. Set KEEP_AWAKE_ROOT to its installation directory.");
}

public sealed class LeaseSession(string root) : IAsyncDisposable
{
    private readonly string _bridge = Path.Combine(root, "integrations", "mcp", "bridge.ps1");
    private readonly string _owner = "mcp_" + Guid.NewGuid().ToString("N");
    private readonly byte[] _key = RandomNumberGenerator.GetBytes(32);
    private readonly ConcurrentDictionary<string, string> _tokens = new(StringComparer.Ordinal);
    private readonly SemaphoreSlim _serial = new(1, 1);
    private bool _closing;

    private static readonly string[] EnvironmentAllowList =
    ["SystemRoot", "windir", "SystemDrive", "ComSpec", "TEMP", "TMP", "LOCALAPPDATA", "APPDATA", "PROGRAMDATA",
     "USERNAME", "USERPROFILE", "USERDOMAIN", "PSModulePath", "PATH", "PATHEXT", "PROCESSOR_ARCHITECTURE", "KA_DATA", "KA_LANG"];

    private string TokenFor(string requestId) => Convert.ToHexString(HMACSHA256.HashData(_key, Encoding.UTF8.GetBytes(requestId))).ToLowerInvariant();

    private async Task<JsonElement> CallBridgeAsync(Dictionary<string, object?> payload, TimeSpan? timeLimit = null)
    {
        payload["owner"] = _owner;
        var system = Environment.GetFolderPath(Environment.SpecialFolder.System);
        var exe = Path.Combine(system, "WindowsPowerShell", "v1.0", "powershell.exe");
        var psi = new ProcessStartInfo(exe)
        {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true,
            RedirectStandardOutput = true, RedirectStandardError = true,
            StandardInputEncoding = new UTF8Encoding(false), StandardOutputEncoding = new UTF8Encoding(false),
            StandardErrorEncoding = new UTF8Encoding(false), WorkingDirectory = Path.GetDirectoryName(_bridge)!
        };
        psi.ArgumentList.Add("-NoProfile"); psi.ArgumentList.Add("-ExecutionPolicy"); psi.ArgumentList.Add("Bypass");
        psi.ArgumentList.Add("-File"); psi.ArgumentList.Add(_bridge);
        var keep = EnvironmentAllowList.ToDictionary(x => x, Environment.GetEnvironmentVariable, StringComparer.OrdinalIgnoreCase);
        psi.Environment.Clear();
        foreach (var (key, value) in keep) if (value is not null) psi.Environment[key] = value;
        using var process = Process.Start(psi) ?? throw new McpException("Could not start the local KeepAwake bridge.");
        await process.StandardInput.WriteAsync(JsonSerializer.Serialize(payload));
        process.StandardInput.Close();
        var stdout = process.StandardOutput.ReadToEndAsync();
        var stderr = process.StandardError.ReadToEndAsync();
        using var timeout = new CancellationTokenSource(timeLimit ?? TimeSpan.FromSeconds(150));
        try { await process.WaitForExitAsync(timeout.Token); }
        catch (OperationCanceledException)
        {
            try { process.Kill(entireProcessTree: false); } catch { }
            throw new McpException("The local operation timed out; its result may be uncertain. Check status before retrying.");
        }
        var text = await stdout; _ = await stderr;
        if (text.Length > 65536) throw new McpException("The local bridge returned an oversized response.");
        var lines = text.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries);
        if (lines.Length == 0) throw new McpException("The local bridge returned no response.");
        JsonElement result;
        try { using var doc = JsonDocument.Parse(lines[^1]); result = doc.RootElement.Clone(); }
        catch (JsonException) { throw new McpException("The local bridge returned an invalid response."); }
        if (process.ExitCode != 0 || !result.TryGetProperty("ok", out var ok) || ok.ValueKind != JsonValueKind.True)
            throw new McpException("The local operation failed. Check the local dashboard and retry only if appropriate.");
        return result;
    }

    public async Task<string> StatusAsync()
    {
        await _serial.WaitAsync();
        try { return (await CallBridgeAsync(new() { ["op"] = "status" })).GetRawText(); }
        finally { _serial.Release(); }
    }

    public async Task<string> EvidenceAsync(int hours)
    {
        if (hours is < 1 or > 24) throw new McpException("Hours must be between 1 and 24.");
        await _serial.WaitAsync();
        try { return (await CallBridgeAsync(new() { ["op"] = "evidence", ["hours"] = hours })).GetRawText(); }
        finally { _serial.Release(); }
    }

    public async Task<string> AcquireAsync(string reason, string requestId, int minutes, bool keepDisplayOn, bool antiLock)
    {
        if (string.IsNullOrWhiteSpace(reason) || reason.Length > 120 || reason.Any(char.IsControl)) throw new McpException("Reason must contain 1–120 printable characters.");
        if (requestId is null || !Regex.IsMatch(requestId, "^[a-zA-Z0-9_.-]{1,100}$")) throw new McpException("Request ID must contain 1–100 letters, digits, dots, hyphens or underscores.");
        if (minutes is < 1 or > 1440) throw new McpException("Minutes must be between 1 and 1440.");
        var token = TokenFor(requestId);
        await _serial.WaitAsync();
        try
        {
            if (_closing) throw new McpException("This session is closing.");
            var result = await CallBridgeAsync(new() { ["op"] = "acquire", ["token"] = token, ["reason"] = reason,
                ["requestId"] = requestId, ["minutes"] = minutes, ["keepDisplayOn"] = keepDisplayOn, ["antiLock"] = antiLock });
            var id = result.GetProperty("id").GetString() ?? throw new McpException("The local bridge omitted the task ID.");
            _tokens[id] = token;
            return result.GetRawText();
        }
        finally { _serial.Release(); }
    }

    public async Task<string> ChangeAsync(string id, string operation, int minutes = 0)
    {
        if (id is null || !Regex.IsMatch(id, "^[0-9a-f]{32}$")) throw new McpException("Invalid task ID.");
        if (operation == "renew" && (minutes is < 1 or > 1440)) throw new McpException("Minutes must be between 1 and 1440.");
        await _serial.WaitAsync();
        try
        {
            if (!_tokens.TryGetValue(id, out var token)) throw new McpException("This task does not belong to the current MCP session.");
            var result = await CallBridgeAsync(new() { ["op"] = operation, ["id"] = id, ["token"] = token, ["minutes"] = minutes });
            // Retain the capability until session shutdown so a release retry remains idempotent.
            return result.GetRawText();
        }
        finally { _serial.Release(); }
    }

    public async ValueTask DisposeAsync()
    {
        await _serial.WaitAsync();
        try
        {
            _closing = true;
            var deadline = Stopwatch.StartNew();
            foreach (var (id, token) in _tokens)
            {
                var left = TimeSpan.FromSeconds(30) - deadline.Elapsed;
                if (left <= TimeSpan.Zero) break;
                try { await CallBridgeAsync(new() { ["op"] = "release", ["id"] = id, ["token"] = token },
                    left < TimeSpan.FromSeconds(10) ? left : TimeSpan.FromSeconds(10)); }
                catch { /* A finite TTL releases it if the local engine is unavailable. */ }
            }
            _tokens.Clear();
            CryptographicOperations.ZeroMemory(_key);
        }
        finally { _serial.Release(); _serial.Dispose(); }
    }
}

[McpServerToolType]
public static class Tools
{
    internal static LeaseSession Session { get; set; } = null!;

    [McpServerTool(Name = "keepawake_status", ReadOnly = true, Idempotent = true, OpenWorld = false),
     Description("Read a minimal, path-free snapshot of protection and this session's tasks.")]
    public static Task<string> Status() => Session.StatusAsync();

    [McpServerTool(Name = "keepawake_evidence", ReadOnly = true, Idempotent = true, OpenWorld = false),
     Description("Read aggregate sleep evidence for 1–24 hours. Unknown evidence is not proof of protection.")]
    public static Task<string> Evidence([Description("Hours to inspect, between 1 and 24.")] int hours = 24) => Session.EvidenceAsync(hours);

    [McpServerTool(Name = "keepawake_acquire", Idempotent = true, Destructive = false, OpenWorld = false),
     Description("Request local wake protection for a finite task. Reuse the same request ID when retrying the same request.")]
    public static Task<string> Acquire([Description("Brief task description; do not include secrets.")] string reason,
        [Description("Unique ID for this request within the session.")] string requestId,
        [Description("Duration in minutes, 1–1440.")] int minutes = 30,
        [Description("Also keep the display on.")] bool keepDisplayOn = false,
        [Description("Send synthetic input to reduce idle locking.")] bool antiLock = false) =>
        Session.AcquireAsync(reason, requestId, minutes, keepDisplayOn, antiLock);

    [McpServerTool(Name = "keepawake_renew", OpenWorld = false),
     Description("Extend a task owned by this MCP session from now for 1–1440 minutes.")]
    public static Task<string> Renew(string id, int minutes) => Session.ChangeAsync(id, "renew", minutes);

    [McpServerTool(Name = "keepawake_release", Idempotent = true, OpenWorld = false),
     Description("Release one task owned by this MCP session without stopping other tasks.")]
    public static Task<string> Release(string id) => Session.ChangeAsync(id, "release");
}
