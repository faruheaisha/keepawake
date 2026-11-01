# KeepAwake MCP

This optional Windows companion exposes local, time-limited KeepAwake tasks over MCP standard input and output. The desktop app and the companion use the same local data directory. An AI client can request, renew and release its own task; the desktop app can inspect and stop tasks. The companion cannot run arbitrary shell commands or change system settings.

Extract the whole package into a stable directory. Configure your MCP client to launch `KeepAwake.Mcp.exe` from that directory. For clients that accept the common JSON configuration shape:

```json
{
  "mcpServers": {
    "keepawake": {
      "command": "C:\\path\\to\\KeepAwake-MCP\\KeepAwake.Mcp.exe"
    }
  }
}
```

The exact configuration location and supported client versions depend on the client. Grant access only to clients you trust. Task names and status are sent to that client, which may send them to an AI provider; do not put secrets in task names. Task leases expire, do not survive a system reboot, and can be revoked in the desktop app. Closing an MCP session attempts to release its tasks; a crash is bounded by the expiry. A registered power request does not override all Windows policies or guarantee the machine will never sleep.

The package includes the .NET runtime and the engine scripts it needs; no separate .NET installation is required. It requires Windows 10 or later and Windows PowerShell 5.1. Package-specific third-party licenses and notices are in `third-party/`.
