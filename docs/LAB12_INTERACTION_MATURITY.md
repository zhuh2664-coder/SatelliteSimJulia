# lab/12_interaction 成熟度状态

> 日期：2026-07-09
> 范围：`src/lab/src/layers/12_interaction/`、`src/lab/test/runtests.jl`、`scripts/probe_ai_*.jl`

本文档记录 AI 交互层的工程成熟度快照。它不是 API 承诺，也不代表所有组件已进入稳定路径；判断标准以是否被正式测试覆盖、是否有 probe 验证、是否接真实 LLM/HTTP、是否存在调用方为主。

## 一句话结论

`lab/12_interaction` 已经不是“规则骨架/未接 LLM”：源码中已有 `llm_provider`、`agent`、`multiagent`、`team_graph`、`tool_registry`、`planner_tools` 等接线实现，并且多个 `scripts/probe_ai_*.jl` 已跑通 fake HTTP / mock provider / tool loop / team graph 路径。

但它也不能整体视为稳定：正式 `src/lab/test/runtests.jl` 现已覆盖 `tool_registry` + `run_simulation` 主路径，并新增了 `LLMProvider` fake HTTP 协议桥接与 `SimAgent` tool loop（fake HTTP）两条确定性测试；但 multiagent/team_graph/planner 仍主要依赖 probe 脚本，真实 LLM provider 调用也仍未纳入默认包测试；若干观测、回放、事件运行和权限校验组件仍缺少直接测试证据。

## 成熟度分层

| 成熟度 | 组件 | 当前判断 | 证据 |
|---|---|---|---|
| 已稳定 | `tool_registry.jl`、默认 AI tools、`execute_tool("run_simulation", ...)` | 已进入 `src/lab/test/runtests.jl`，能通过正式包测试路径验证 SGP4 `run_simulation` | `src/lab/test/runtests.jl` 的 `registered AI tools and SGP4 path` testset |
| 已稳定 | `run_simulation` tool 的 traffic / SGP4 基础路径 | 有正式测试覆盖 SGP4 路径与 traffic AON 桥接路径；另有多个 probe 覆盖 traffic / AON | `src/lab/test/runtests.jl` 的 `AI run_simulation traffic AON bridge` testset、`scripts/probe_ai_run_simulation_sgp4_traffic_aon.jl`、`scripts/probe_ai_run_simulation_traffic_aon.jl` |
| 已稳定 | `mock_provider.jl` | 作为 AI probe 的测试基础设施，逻辑简单，多个 mock-based probe 依赖它 | `scripts/probe_ai_offline_react_planner.jl`、`scripts/probe_ai_team_graph_run_simulation.jl`、`scripts/probe_ai_team_graph_traffic_aon.jl` |
| 正式测试覆盖（fake HTTP 协议路径） | `llm_provider.jl` | 请求/响应协议路径已进入 `src/lab/test/runtests.jl`（fake HTTP，确定性，无真实 API key）；真实第三方 provider 调用仍为 opt-in，不在默认测试内 | `src/lab/src/layers/12_interaction/llm_provider.jl`、`src/lab/test/runtests.jl` 的 `AI LLMProvider fake HTTP bridge` testset、`scripts/probe_ai_llm_provider_fake_http.jl` |
| 正式测试覆盖（fake HTTP 协议路径） | `agent.jl` (`SimAgent` / `run_agent`) | ReAct tool loop 的 fake HTTP 路径已进入 `src/lab/test/runtests.jl`（确定性：一次工具调用后给出最终答复）；真实 LLM 长循环仍需 opt-in 验证 | `src/lab/src/layers/12_interaction/agent.jl`、`src/lab/test/runtests.jl` 的 `AI SimAgent tool loop fake HTTP bridge` testset、`scripts/probe_ai_llm_provider_tool_loop.jl`、`scripts/probe_ai_offline_react_planner.jl` |
| 半成品 | `multiagent.jl`、`team_graph.jl` | `planner -> runner -> reviewer` 多智能体图已被 mock provider probe 验证；仍是 scripts/probe 层，不是正式包测试 | `scripts/probe_ai_team_graph_run_simulation.jl`、`scripts/probe_ai_team_graph_traffic_aon.jl` |
| 半成品 | `planner/planner.jl`、`planner_tools.jl`、`studies.jl`、`goals.jl`、`study_dsl.jl` | 有 plan/study/tool 接线和 probe，但既有审计指出 planner -> study handoff 仍有参数语义风险 | `scripts/probe_ai_run_study_plan_traffic_aon.jl`、`docs/audits/2026-07-07_50_agent_audit/dimensions/24_satellitesimjulia-lab-orchestration-layers-10-12-audit.md` |
| 半成品 | `memory.jl`、`hooks.jl`、`ledger.jl` | 有独立脚本或间接 probe 覆盖基础行为；仍未系统纳入 `src/lab/test/runtests.jl` | `scripts/test_memory.jl`、`scripts/test_hooks.jl`、AI tool loop / team graph probes |
| 原型 / 未充分验证 | `trace.jl`、`replay.jl`、`evals.jl`、`ai_runs.jl`、`event_runtime.jl`、`agent_worker.jl`、`team_artifacts.jl`、`team_graph_checkpoint.jl` | 已 include/export，部分被高层代码引用，但缺少明确的正式测试覆盖；动这些文件前应先补读调用方和行为假设 | `src/lab/src/SatelliteSimLab.jl` include 列表，未见 `src/lab/test/runtests.jl` 直接覆盖 |
| 原型 / 未充分验证 | `tool_guards.jl`、`tool_permissions.jl`、`tool_validation.jl`、`tool_inputs.jl`、`questionnaire/questionnaire.jl` | 有实现和集成点，但当前证据不足以证明稳定；适合先补最小 regression test 再扩展 | `src/lab/src/SatelliteSimLab.jl` include 列表，相关 probe/测试覆盖不完整 |

## 关键证据

### 正式测试覆盖

`src/lab/test/runtests.jl` 当前对 AI 层的直接覆盖集中在：

- `ensure_default_ai_tools!()`
- `registered_ai_tools()`
- `execute_tool("run_simulation", ...)`
- SGP4 / TLE-based `run_simulation` 结果字段断言
- `run_simulation` traffic AON 桥接路径（`AI run_simulation traffic AON bridge` testset）
- `LLMProvider` 请求/响应协议（`AI LLMProvider fake HTTP bridge` testset，fake HTTP，无真实 API key）
- `SimAgent` / `run_agent` 的 ReAct tool loop（`AI SimAgent tool loop fake HTTP bridge` testset，fake HTTP，一次工具调用后收敛到最终答复）

它没有直接覆盖：

- `LLMProvider` 对真实第三方 provider 的调用（默认测试只覆盖 fake HTTP）
- `SimAgent` / `run_agent` 的真实 LLM 长循环（默认测试只覆盖 fake HTTP 单次工具调用路径）
- `multiagent` / `team_graph`
- `planner` / `run_study_plan` 全链路
- `trace` / `replay` / `evals` / `ai_runs` / `agent_worker`

### Probe 覆盖

AI 层已有较多 probe，说明接线不是空壳：

- `scripts/probe_ai_llm_provider_fake_http.jl`：用本地 fake HTTP server 验证 `LLMProvider` 请求/响应协议。
- `scripts/probe_ai_llm_provider_tool_loop.jl`：用 fake HTTP 验证 `SimAgent` tool loop。
- `scripts/probe_ai_offline_react_planner.jl`：用 `MockProvider` 验证离线 ReAct / planner 相关路径。
- `scripts/probe_ai_run_simulation_traffic_aon.jl`：验证 `run_simulation` traffic AON 路径。
- `scripts/probe_ai_run_simulation_sgp4_traffic_aon.jl`：验证 SGP4 + traffic AON 路径。
- `scripts/probe_ai_run_study_plan_traffic_aon.jl`：验证 `run_study_plan` 对 traffic AON 的支持。
- `scripts/probe_ai_team_graph_run_simulation.jl`：验证 team graph 驱动 `run_simulation`。
- `scripts/probe_ai_team_graph_traffic_aon.jl`：验证 team graph 驱动带 traffic 的 AON 仿真。

其中 `run_simulation` traffic AON、`LLMProvider` fake HTTP、`SimAgent` tool loop 三条已镜像进 `src/lab/test/runtests.jl`（对应 probe 脚本保留为诊断入口）；其余 probe 价值仍很高，但成熟度解释要谨慎：它们主要证明“能跑通/接线存在”，还不等同于“已进入稳定包测试或 CI 门禁”。

### 相关报告

- `docs/PLATFORM_STATUS_REPORT.md` 是 2026-07-03 快照，其中 AI 适配层“规则骨架/未接 LLM/src 内零 LLM 调用”的描述已经过时。
- `docs/2026-07-06_LAYERED_ADVANCEMENT_STATUS.md` 已记录 AI probe 全绿和 team graph traffic AON 路径，但它描述的是分层推进结果，不等于正式测试覆盖矩阵。
- `docs/audits/2026-07-07_50_agent_audit/dimensions/24_satellitesimjulia-lab-orchestration-layers-10-12-audit.md` 指出 planner/study/routing/ground endpoint 等编排边界仍有高风险问题。
- `docs/audits/2026-07-07_50_agent_audit/dimensions/12_47-testing-realism-probes.md` 指出 probe suite 覆盖广，但需要把诊断脚本和真正 regression tests 分开。

## 使用建议

### 可以相对放心使用

- `ensure_default_ai_tools!`
- `registered_ai_tools`
- `execute_tool`
- `run_simulation` 小规模仿真工具
- `MockProvider` 驱动的离线验证

### 使用前应先验证

- `LLMProvider` 对真实第三方模型的调用
- `SimAgent` / `run_agent` 的长循环和工具调用
- `run_team_graph` / `AgentTeam`
- `run_study_plan`
- traffic AON 相关 AI tool 路径

建议先跑对应 `scripts/probe_ai_*.jl`，再做功能改动。

### 改动前必须补读和补测

- `planner` 到 `studies` 的参数转换
- `trace` / `replay` / `evals` / `ai_runs`
- `agent_worker` / `event_runtime`
- `tool_permissions` / `tool_validation` / `tool_inputs`
- `questionnaire`

这些组件已经被 include，但稳定性证据不足。不要仅凭文件名或 export 状态假设可用。

## 推荐下一步

1. 把 deterministic 的 AI probe 迁入或镜像到 `src/lab/test/runtests.jl`，优先顺序：
   `run_simulation traffic AON`（已完成）-> `LLMProvider fake HTTP`（已完成）-> `SimAgent tool loop`（已完成）-> `team_graph run_simulation`（待办）。
2. 给 planner/study handoff 增加最小 regression：覆盖 `create_plan -> build_study -> run_study_plan`，并确认参数语义没有被丢弃。
3. 给 `trace` / `replay` / `evals` / `ai_runs` 各加一个不依赖真实 LLM 的最小测试。
4. 将 `scripts/probe_ai_*.jl` 标注为 regression / diagnostic / external 三类，避免把“能运行的诊断脚本”误当成稳定门禁。
5. 真实 LLM provider 验证保持 opt-in，必须使用环境变量凭证，默认测试只跑 fake HTTP / MockProvider。

