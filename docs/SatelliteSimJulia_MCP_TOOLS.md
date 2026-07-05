# SatelliteSimJulia MCP Tools Contract

This document defines a minimal, MCP-ready tool surface for SatelliteSimJulia.

The first implementation is intentionally a JSON CLI runner (`scripts/mcp_tool_runner.jl`) rather than a full MCP stdio server. A future MCP server can map MCP `tools/call` requests to this runner or to the same Julia functions.

---

## Design Goals

1. Reuse existing simulation/server code.
2. Keep tool inputs and outputs JSON-serializable.
3. Prefer read-only or bounded side effects in the first version.
4. Return structured errors instead of stack traces.
5. Keep long-running streaming out of the first version.

---

## CLI Runner

```bash
julia --project=. scripts/mcp_tool_runner.jl <tool-name> '<json-args>'
```

Successful output:

```json
{"ok":true,"tool":"list_constellations","result":{}}
```

Error output:

```json
{"ok":false,"tool":"...","error_type":"ArgumentError","message":"..."}
```

---

## Tools

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
- `SatelliteSimServer.handle_list_constellations`

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
- `SatelliteSimServer.handle_describe_constellation`

---

### 3. `start_simulation_summary`

Start a bounded simulation session and return only summary metadata, not streaming frames.

Input:

```json
{
  "name":"iridium",
  "tspan":[0.0, 30.0],
  "step_s":10.0,
  "propagator":"j2",
  "fps":10.0
}
```

Output:

```json
{
  "session_id":"abc12345",
  "n_sat":66,
  "n_time":4,
  "fps":10.0,
  "step_s":10.0,
  "tspan":[0.0,30.0]
}
```

Implementation source:

- `SatelliteSimServer.start_session`
- `SatelliteSimServer.handle_start_simulation`

Side effect:

- Creates an in-memory server session. CLI runner should stop/cleanup the session unless the caller explicitly requests `keep_session=true`.

---

### 4. `frame_payload_once`

Generate a single frame payload for a bounded session config.

Input:

```json
{
  "name":"iridium",
  "tspan":[0.0, 30.0],
  "step_s":10.0,
  "propagator":"j2",
  "frame_index":1
}
```

Output:

```json
{
  "type":"frame",
  "session_id":"...",
  "t":0.0,
  "frame_index":1,
  "n_total":4,
  "positions":[...],
  "isl_pairs":[[1,2]],
  "isl_avail":[true]
}
```

Implementation source:

- `SatelliteSimServer.start_session`
- `SatelliteSimServer.frame_payload`

Side effect:

- Temporary in-memory session; runner should always cleanup.

---

### 5. `run_pkg_test`

Run one Julia package test with a bounded command wrapper.

Input:

```json
{"package":"SatelliteSimCore"}
```

Output:

```json
{
  "package":"SatelliteSimCore",
  "success":true,
  "duration_s":4.2,
  "marker":"Testing SatelliteSimCore tests passed"
}
```

Allowed packages should be allowlisted.

Initial allowlist:

- `SatelliteSimFoundation`
- `SatelliteSimOrbit`
- `SatelliteSimMetrics`
- `SatelliteSimLink`
- `GMAT`
- `SatelliteSimCore`
- `SatelliteSimNet`
- `SatelliteSimTraffic`
- `SatelliteSimLab`
- `SatelliteSimOpt`
- `SatelliteSimViz`
- `SatelliteSimServer`

---

### 6. `zcode_token_usage_summary`

Run the token usage audit script in summary mode.

Input:

```json
{"date":"today","top":10}
```

Output:

```json
{
  "command":"python3 scripts/zcode_token_usage_report.py --date today --top 10",
  "success":true,
  "text":"..."
}
```

Security:

- The script must not print message contents or credentials.

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

The server accepts standard `Content-Length` framed messages and also newline-delimited JSON for local smoke tests. It reuses `scripts/mcp_tool_runner.jl` as its tool backend.

Smoke-tested behavior:

- `initialize` returns serverInfo `{name: "satellitesimjulia", version: "0.1.0"}`
- `tools/list` returns 6 tools
- `tools/call` with `describe_constellation {"name":"iridium"}` returns `T=66`

---

## Future Full MCP Server

A full production MCP server can later expose these as `tools/list` and `tools/call` over stdio or HTTP.

Recommended future files:

```text
src/mcp/Project.toml
src/mcp/src/SatelliteSimMCP.jl
src/mcp/bin/serve_stdio.jl
src/mcp/test/runtests.jl
```

For now, `scripts/mcp_tool_runner.jl` is the stable backend contract.

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
- Package test tool uses an allowlist.
- Simulation tools use bounded `tspan` and `step_s`.
- Token audit is read-only.
- Long-running/streaming tasks are deferred to a future durable task API.
