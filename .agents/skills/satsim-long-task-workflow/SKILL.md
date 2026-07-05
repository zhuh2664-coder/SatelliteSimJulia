---
name: satsim-long-task-workflow
description: >
  Use this skill for SatelliteSimJulia long-running engineering tasks, Julia package testing,
  dependency/regression work, ZCode token/context audits, MCP/tool landing, documentation reports,
  or any multi-step repository change that needs planning, checkpoints, validation, and a final
  status report. Trigger on requests such as “继续推进”, “跑测试”, “依赖治理”, “token审计”,
  “做长任务”, “落地MCP”, “把流程固化”, “新增脚本”, or “修复并验证”.
---

# SatelliteSimJulia Long Task Workflow

Project-scoped workflow for safe, verifiable long tasks in `/Users/zhuhai/Research/SatelliteSimJulia`.

## Repository Context

- Root: `/Users/zhuhai/Research/SatelliteSimJulia`
- Root project: `Project.toml`, `Manifest.toml`
- Source packages: `src/*/Project.toml`
- Main root test: `test/runtests_current.jl`
- Scripts: `scripts/`
- Docs: `docs/`
- Existing server package: `src/server`
- ZCode usage DB: `~/.zcode/cli/db/db.sqlite`

## Task Triage

Classify the user request before acting:

1. **Long task / refactor**: multi-step code or architecture work. Use plan mode first.
2. **Julia test/regression**: run the smallest relevant test first, then widen.
3. **Token/context audit**: query `model_usage` / `turn_usage`; never print message bodies or credentials.
4. **MCP/tool landing**: define tool contract first, then implement a minimal vertical slice.
5. **Docs/report**: write Markdown under `docs/` and include source links or file paths.

## Default Workflow

1. Capture objective and constraints.
2. Read the minimum necessary context.
3. Define success criteria and non-goals.
4. Create/update todo list.
5. For substantial changes, produce a plan before editing.
6. Implement in small batches.
7. Validate each batch.
8. Preserve rollback points using git when appropriate.
9. Report exactly what changed, what was tested, and what remains.

## Julia Test Workflow

Preferred validation ladder:

1. Focused test or script for the changed area.
2. Package-level test, e.g. `julia --project=. -e 'using Pkg; Pkg.test("SatelliteSimCore")'`.
3. Unified test runner: `julia --project=. scripts/test_all.jl`.
4. Root current test: `julia --project=. test/runtests_current.jl`.
5. Regression suite: `julia --project=. scripts/run_regression.jl`.
6. Slow tests only when needed: `SATSIM_RUN_SLOW=1 ...`.

Do not claim tests passed unless the command actually ran and exited successfully.

## Token / Context Audit Workflow

Use `scripts/zcode_token_usage_report.py` when present. Otherwise query read-only:

- DB: `~/.zcode/cli/db/db.sqlite`
- Tables: `model_usage`, `turn_usage`, `session`

Required output dimensions:

- Date summary
- Model/provider summary
- Top sessions
- Error types
- Cache accounting explanation

Never print raw message text, API keys, credentials, or full prompt payloads.

## MCP Landing Workflow

1. Decide whether the work is a real MCP server, a tool contract, or a CLI backend.
2. Define tool name, input JSON, output JSON, errors, side effects, timeout, and tests.
3. Prefer a minimal CLI tool runner first: `scripts/mcp_tool_runner.jl`.
4. Reuse `src/server` where possible:
   - `list_constellations`
   - `describe_constellation`
   - `start_simulation`
   - `stop_simulation`
   - `ai_trace`
   - `ai_checkpoint`
5. Document tools in `docs/SatelliteSimJulia_MCP_TOOLS.md`.

## Safety Rules

- Do not delete user files unless explicitly asked.
- Do not overwrite an existing file without reading/checking it first.
- Do not push or publish externally unless explicitly authorized.
- Prefer additive files for experimental workflows.
- Keep changes surgical and reversible.
- If pre-existing failures are found, report them separately from new failures.

## Final Report Format

End with:

- Files changed
- Commands run
- Test results
- Known risks
- Next recommended step
