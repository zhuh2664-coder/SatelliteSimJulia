# AI Orchestration Layer — Product-Grade Architecture

This document is the acceptance reference for the SatelliteSimJulia AI orchestration layer. It compares the current design with product-grade open-source agent platforms such as LangGraph, AutoGen, CrewAI, OpenHands, Dify, Flowise, Haystack/LlamaIndex workflows, and Temporal-style durable execution.

## Product-grade bar

A real product is not just an LLM loop that calls a simulator. For satellite simulation, the product-grade target is:

> a durable, auditable, reproducible experiment/simulation control plane where AI assists planning, execution, analysis, and reporting under strict human, security, and physics-validation constraints.

## Capability matrix

| Product capability | Current SatelliteSimJulia artifact | Status |
|---|---|---|
| Explicit orchestration graph | `TeamGraph`, `TeamNode`, `TeamState`, `run_team_graph` | Implemented |
| Multi-agent roles | `AgentSpec`, `AgentTeam`, planner/runner/reviewer defaults | Implemented |
| Tool registry / SDK boundary | `AIToolSpec`, `register_ai_tool!`, `execute_registered_tool` | Implemented |
| Runtime schema validation | `validate_tool_args`, `schema_validation_hook` | Implemented |
| Security/resource guards | `ToolBudget`, `guard_tool_call`, pre-tool hooks | Implemented |
| HITL permissions | `ToolPermissionPolicy`, `approve_tool_call!` | Implemented |
| Audit ledger | `record_ledger_event!`, `record_tool_ledger!` | Implemented |
| Trace inspection | `AgentTrace`, `TraceEvent`, `trace_timeline` | Implemented |
| Deterministic replay | `ReplayStep`, `ReplayResult`, `replay_tools` | Implemented |
| Durable checkpoint | `save_team_graph_checkpoint!`, `load_team_graph_checkpoint` | Implemented |
| Resume from checkpoint | `resume_team_graph` | Implemented |
| Structured artifacts | `ARTIFACT <key> <json>`, `extract_team_artifacts!` | Implemented |
| Eval / benchmark harness | `AgentEvalCase`, `run_agent_eval_suite`, `run_ai_regression_benchmark` | Implemented |
| CLI exposure | `teamgraph`, `ai-trace`, `ai-checkpoint`, `ai-replay`, `ai-eval` | Implemented |
| Server API exposure | WebSocket `ai_trace`, `ai_checkpoint` | Implemented |
| Product docs/demo/benchmark | this doc, `benchmark/ai/run_ai_benchmark.jl`, `scripts/demo_ai_orchestration.jl` | Implemented in this milestone |
| Production deployment UI / multi-tenant RBAC | platform layer exists separately, not fully integrated with AI orchestration | Gap |
| Real LLM provider regression | supported by provider abstraction, not used in CI because deterministic tests use `MockProvider` | Intentional |

## Architecture

```text
user / API / CLI
      |
      v
SimAgent ReAct loop
      |
      +-- tool registry + schema validation
      +-- permission/HITL + resource guard hooks
      +-- ledger + trace + replay
      |
      v
AgentTeam / TeamGraph
      |
      +-- planner -> runner -> reviewer
      +-- reviewer can route back to runner
      +-- structured ARTIFACT handoff
      +-- checkpoint/resume
      |
      v
SatelliteSimLab deterministic experiment tools
      |
      v
Core / Net / Traffic / Viz outputs
```

## Structured artifact contract

Agents can pass typed state to later nodes by outputting one line:

```text
ARTIFACT <key> <json>
```

Example:

```text
ARTIFACT plan {"goal":"coverage","constellation":"walker24","steps":["run","review"]}
```

TeamGraph stores this as:

```julia
state.artifacts["plan"]
```

Artifacts are included in checkpoints and injected into later node prompts. This keeps planner-executor handoff explicit instead of relying only on natural language transcript text.

## Durable execution

Checkpoint file:

```text
data/sessions/<session_id>/team_graph_checkpoint.json
```

Typical flow:

```julia
team = AgentTeam(provider; session_id = "mission_eval")
result1 = run_team_graph(team, default_team_graph(; max_steps = 1), "任务"; checkpoint = true)
result2 = resume_team_graph(team, default_team_graph(), team_graph_checkpoint_path(team); checkpoint = true)
```

Trace file:

```text
data/sessions/<session_id>/ledger.jsonl
```

Replay flow:

```julia
trace = load_agent_trace("mission_eval")
plan = tool_replay_plan(trace)
dry = replay_tools(trace; dry_run = true)
actual = replay_tools(trace; dry_run = false, verify_hash = true)
```

## CLI examples

```bash
# Run graph-based multi-agent orchestration with checkpointing
julia --project=. bin/satnet.jl teamgraph "规划并执行 walker24 覆盖分析" --checkpoint

# Inspect trace timeline
julia --project=. bin/satnet.jl ai-trace team_graph_default

# Extract deterministic replay plan
julia --project=. bin/satnet.jl ai-trace team_graph_default --mode replay_plan

# Dry-run replay
julia --project=. bin/satnet.jl ai-replay team_graph_default

# Execute replay and verify hashes when available
julia --project=. bin/satnet.jl ai-replay team_graph_default --execute --verify-hash

# Inspect checkpoint summary
julia --project=. bin/satnet.jl ai-checkpoint team_graph_default

# Run built-in deterministic AI regression
julia --project=. bin/satnet.jl ai-eval
```

## WebSocket API examples

```json
{"type":"ai_trace","session_id":"team_graph_default","mode":"timeline"}
```

```json
{"type":"ai_checkpoint","session_id":"team_graph_default"}
```

These endpoints intentionally expose inspection only. They do not run external LLM calls or execute tools.

## Product-grade acceptance gates

Use these commands before claiming the AI layer is product-ready:

```bash
julia --project=. test/ai/runtests.jl
julia --project=. benchmark/ai/run_ai_benchmark.jl
julia --project=. scripts/demo_ai_orchestration.jl
julia --project=src/server -e 'using Pkg; Pkg.test()'
julia --project=. scripts/smoke_core_net_lab_experiment.jl
```

Optional full client regression:

```bash
~/Applications/Godot.app/Contents/MacOS/Godot --headless --path godot-sandbox -s tests/regression_constellations.gd
```

## Remaining product gaps

The current AI orchestration layer is no longer an MVP in the narrow agent-control-plane sense. The remaining gaps are broader product/platform work:

1. **Multi-tenant RBAC for AI sessions** — current AI session data is file-based under `data/sessions`; platform tenant model is not fully wired to AI orchestration.
2. **Worker-backed long-running campaigns** — deterministic simulation tools exist, but AI graph execution is still in-process, not a distributed durable worker queue.
3. **UI for trace/checkpoint/HITL** — CLI/API exist; a product UI would make this usable by non-developers.
4. **Real LLM evaluation lane** — CI stays deterministic with MockProvider. A separate, opt-in, budgeted real-LLM eval lane should be added later.
5. **Artifact store integration** — artifacts are in TeamState/checkpoints; large ephemerides/plots/reports should be promoted to object storage with lineage.

These are explicit product roadmap items rather than hidden MVP limitations.
