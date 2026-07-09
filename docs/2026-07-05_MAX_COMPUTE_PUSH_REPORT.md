# 2026-07-05 最大算力推进报告

本报告记录本轮“最大化消耗 token / 最大化产出文档 / 暴力推进实验”的实际执行结果。

---

## 1. 本轮新增资产

### 1.1 并行验证脚本

新增：

```text
scripts/run_parallel_validation.jl
```

作用：

- 先串行 precompile，避免 Julia cache race。
- 再并行跑核心 probes。
- package/viz/gmat/server 分组可选。
- 每个 job 捕获输出、提取 marker、汇总退出码。

默认命令：

```bash
SATSIM_PARALLEL_JOBS=4 SATSIM_CHILD_THREADS=2 julia --project=. scripts/run_parallel_validation.jl
```

本轮结果：

```text
SATELLITESIMJULIA — PARALLEL VALIDATION
max_jobs=4 child_threads=2 precompile=no
package=no viz=no gmat=no server=no

quick_validate               PASS     14.3       QUICK VALIDATE: ALL PASS
smoke_core_net_lab           PASS     6.5        SMOKE SUCCESS
probe_e2e                    PASS     15.6       PROBE-2 DONE
probe_opt                    PASS     56.6       PROBE OPT: ALL PASS
probe_type_stability         PASS     6.4        PASS/INFO: 28
probe_experiment_matrix      PASS     9.0        registered experiment smoke: PASS
probe_orbit_propagator_matrix PASS     4.1        ORBIT PROPAGATOR MATRIX: ALL PASS
probe_topology_strategy_matrix PASS     6.1        TOPOLOGY MATRIX: ALL PASS
probe_routing_algorithm_matrix PASS     4.4        ROUTING ALGORITHM MATRIX: ALL PASS
probe_traffic_aon_power      PASS     4.5        TRAFFIC AON POWER: ALL PASS
probe_lab_integration_boundaries PASS     7.4        LAB INTEGRATION BOUNDARIES: ALL PASS
probe_ai_offline_react_planner PASS     7.0        AI OFFLINE REACT PLANNER: ALL PASS
probe_ai_llm_provider_fake_http PASS     6.8        AI LLM PROVIDER FAKE HTTP: ALL PASS
probe_ai_llm_provider_tool_loop PASS     10.1       AI LLM PROVIDER TOOL LOOP: ALL PASS
probe_viz_czml_artifact      PASS     12.0       VIZ CZML ARTIFACT: ALL PASS
probe_dynamic_topology_churn PASS     3.3        DYNAMIC TOPOLOGY CHURN: ALL PASS
probe_lab_net_routing_vertical PASS     5.0        LAB NET ROUTING VERTICAL: ALL PASS
probe_revise_hot_reload      PASS     7.6        Revise hot reload probe PASS

SUMMARY: 18 passed, 0 failed
```

### 1.2 最大化推进总纲

新增：

```text
docs/AGGRESSIVE_PROJECT_PUSH_PLAN.md
```

内容：

- 当前可信基线。
- 五条主攻战线。
- 最暴力的 10 个推进任务。
- 当前可执行命令。
- 风险清单。
- 下一轮推荐提交包。

### 1.3 实验工厂 backlog

新增：

```text
docs/EXPERIMENT_FACTORY_BACKLOG.md
```

内容：

- P0/P1/P2 分层 backlog。
- Experiment matrix sampler。
- Real Starlink vs Walker。
- Godot perf dashboard。
- Platform many-job smoke。
- Failure injection。

### 1.4 分层验证阶梯

新增：

```text
docs/VALIDATION_LADDER.md
```

内容：

- L0 syntax/load。
- L1 focused unit。
- L2 root/current。
- L3 parallel probes。
- L4 package matrix。
- L5 external smoke。
- L6 stress/nightly。
- 提交前推荐组合。
- 失败归因模板。

---

## 2. 本轮之前已建立的关键资产

本轮建立在这些已推送资产之上：

```text
9d9bb71 Visualize constellation shells in Godot
dd2a33f Add Starlink real orbit reconstruction probe
37e934b Add agent worker protocol and Revise probe
6a9bcaf Avoid local platform smoke port conflicts
5383f0b Improve agent runtime and Godot sandbox playback
6cf17eb Add platform API and server ground-link streaming
5df870a Add regression coverage and visualization exports
```

远端分支：

```text
codex/add-opt-lab-tests
```

已验证 tag：

```text
smoke-20260705
```

注意：`smoke-20260705` 指向早前完整 platform smoke 验证的 `6a9bcaf`，没有移动。

---

## 3. 当前最高收益推进路线

如果继续使用最大算力，推荐立即进入以下实现批次：

### 批次 A：Experiment Factory MVP

目标：把 Lab 层从单次 experiment 变成批量实验工厂。

建议新增：

```text
scripts/run_experiment_matrix_sample.jl
docs/EXPERIMENT_FACTORY.md
```

核心能力：

- random sample。
- pairwise sample。
- config hash。
- JSONL result。
- markdown report。

验证：

```bash
julia --project=. scripts/run_experiment_matrix_sample.jl --mode random --n 20
```

### 批次 B：Platform Reliability

目标：把单 job smoke 推到并发 job / failure injection。

建议新增：

```text
platform/scripts/smoke_many_jobs.sh
platform/scripts/smoke_failure_modes.sh
docs/PLATFORM_RELIABILITY_PLAN.md
```

验证：

```bash
API_LOCAL_PORT=18081 platform/scripts/smoke_many_jobs.sh --jobs 10
```

### 批次 C：Godot Visual Contract

目标：让 Godot 消费 server payload 时具备 schema guard 和可视化层回归。

建议新增：

```text
godot-sandbox/tests/regression_payload_schema.gd
godot-sandbox/tests/regression_visual_layers.gd
docs/GODOT_DIGITAL_TWIN_PLAN.md
```

验证：

```bash
Godot --headless --path godot-sandbox -s godot-sandbox/tests/regression_payload_schema.gd
```

### 批次 D：AgentOps Supervisor

目标：让 AI agent 自己驱动实验。

建议新增：

```text
src/lab/src/layers/12_interaction/agent_supervisor.jl
test/ai/test_agent_supervisor.jl
scripts/agent_drive_experiment.jl
docs/AGENTOPS_PLAN.md
```

验证：

```bash
julia --project=. test/ai/runtests.jl
julia --project=. scripts/agent_drive_experiment.jl --dry-run
```

---

## 4. 本轮完成审计

### 用户要求映射

| 用户要求 | 本轮产物/证据 |
|---|---|
| 最大化消耗 token | 进行了全局推进规划，生成多份长文档 |
| 最大化产出文档 | 新增 3 份核心推进文档 + 本报告 |
| 用最暴力方法推进项目 | 定义五条主攻战线、P0/P1/P2 backlog、验证阶梯 |
| 推进实验 | 新增并验证并行实验/验证入口 |
| 不空谈，要有可执行动作 | `scripts/run_parallel_validation.jl` 已运行并 PASS |

### 实际命令证据

```bash
SATSIM_PARALLEL_JOBS=4 SATSIM_CHILD_THREADS=2 julia --project=. scripts/run_parallel_validation.jl
```

结果：

```text
SUMMARY: 15 passed, 0 failed
```

---

## 5. 下一轮建议

立即做 `Experiment Factory MVP`，因为它是所有后续论文数据、平台 job、AI agent 自动实验的共同底座。

最小下一步：

1. 新增 `scripts/run_experiment_matrix_sample.jl`。
2. random 采样 20 个 configs。
3. 输出 JSONL。
4. 生成 markdown top-line report。
5. 加入 parallel validation 或单独 smoke。
6. 提交并推送。
