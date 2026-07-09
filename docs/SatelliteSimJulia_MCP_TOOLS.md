# SatelliteSimJulia MCP Tools Contract

> **默认安全边界**：`agentos_app.py`、`scripts/mcp_tool_runner.jl` 和 `scripts/mcp_stdio_server.jl` 默认只暴露只读 safe tools：`list_constellations` 与 `describe_constellation`。仿真/传播、测试、`frame_payload_once`、PNG/CZML/JLD2/export、写文件、token 审计脚本、长任务和公网服务均不在默认 dispatch 中。

This document defines the minimal MCP-ready safe tool surface for SatelliteSimJulia.

The current implementation is intentionally a JSON CLI runner (`scripts/mcp_tool_runner.jl`) plus a small stdio JSON-RPC server (`scripts/mcp_stdio_server.jl`). Both share the same safe allowlist. A future production MCP server must keep the same default boundary unless a separate privileged mode is explicitly designed and reviewed.

---

## Hard Boundaries

1. **Read-only by default**: only catalog inspection is exposed.
2. **Runner-level allowlist**: `TOOLS` in `scripts/mcp_tool_runner.jl` contains only the two safe tools.
3. **MCP list/call allowlist**: `scripts/mcp_stdio_server.jl` advertises and dispatches only the same two safe tools.
4. **No simulation or propagation**: tools that call `propagate_to_ecef` are not exported through the safe surface.
5. **No tests**: package test helpers are intentionally disabled in this surface.
6. **No frame payloads**: frame payload generation is intentionally disabled.
7. **No exports or file writes**: PNG/CZML/JLD2/export/file-writing tools are not present.
8. **No public AgentOS bind**: AgentOS is loopback-only (`127.0.0.1`) and ignores host/API-key environment overrides for this local safe demo.

---

## CLI Runner

```bash
julia --project=. scripts/mcp_tool_runner.jl <tool-name> '<json-args>'
```

Successful output:

```json
{"ok":true,"tool":"list_constellations","result":{"names":["iridium"]}}
```

Error output:

```json
{"ok":false,"tool":"...","error_type":"ArgumentError","message":"unknown or disabled safe tool: ..."}
```

---

## Safe Tools

### 1. `list_constellations`

Return catalog constellation names.

Input:

```json
{}
```

Output:

```json
{
  "names": ["walker24", "walker48", "iridium"]
}
```

Implementation source:

- `SatelliteSimCore.list_constellations`

---

### 2. `describe_constellation`

Describe a Walker constellation.

Input:

```json
{"name":"iridium"}
```

Output:

```json
{
  "name":"iridium",
  "T":66,
  "P":6,
  "F":2,
  "alt_km":780.0,
  "inc_deg":86.4
}
```

Implementation source:

- `SatelliteSimCore.resolve_constellation`

---

## Disabled / Not Dispatched by Default

These names are intentionally not present in `TOOLS` and must not appear in `tools/list`:

- `start_simulation_summary` — would trigger propagation (`propagate_to_ecef`).
- `frame_payload_once` — would generate frame payload data and topology/link details.
- `run_pkg_test` — would execute Julia test commands.
- `zcode_token_usage_summary` — would execute a local Python audit script.
- Any PNG/CZML/JLD2/export/file-writing helper.
- Any long-running, streaming, external-publishing, or public-network service helper.

If a caller requests one of these through the safe runner or MCP server, the expected behavior is a structured error, not execution.

---

## Minimal stdio MCP Server

A first stdio JSON-RPC server is available:

```bash
julia --project=. scripts/mcp_stdio_server.jl
```

Supported JSON-RPC methods:

- `initialize`
- `notifications/initialized`
- `tools/list`
- `tools/call`
- `shutdown`

The server accepts standard `Content-Length` framed messages and newline-delimited JSON for local smoke tests. It reuses `scripts/mcp_tool_runner.jl` as its tool backend and exposes only the same two safe tools.

Smoke-tested behavior:

- `initialize` returns serverInfo `{name: "satellitesimjulia", version: "0.1.0"}`
- `tools/list` returns exactly 2 tools
- `tools/call` with `describe_constellation {"name":"iridium"}` returns `T=66`
- `tools/call` with disabled names such as `run_pkg_test` or `frame_payload_once` returns an error

---

## Future Privileged Surfaces

A future privileged MCP server may expose simulation, tests, frame payloads, exports, or file-writing tools only as a separate mode with explicit review. It should not reuse the safe default dispatch table.

Recommended future files, if that mode is ever designed:

```text
src/mcp/Project.toml
src/mcp/src/SatelliteSimMCP.jl
src/mcp/bin/serve_stdio.jl
src/mcp/test/runtests.jl
```

For now, `scripts/mcp_tool_runner.jl` is the stable safe backend contract.

---

## Error Semantics

All tools should return:

```json
{
  "ok": false,
  "tool": "tool_name",
  "error_type": "ArgumentError",
  "message": "human readable message"
}
```

Do not return raw stack traces by default.

---

## Safety Rules

- No external publishing.
- No destructive file operations.
- No package tests through this surface.
- No propagation or frame payload through this surface.
- No exports or file writes through this surface.
- Long-running/streaming tasks are deferred to a future reviewed privileged API, not this default safe API.
