# SatelliteSimJulia 分层验证阶梯

日期：2026-07-05

本文定义项目后续高速推进时的验证阶梯。目标是在“无限算力/无限模型”条件下，也不让项目陷入不可验证的功能堆砌。

---

## 1. 验证层级总览

| 层级 | 名称 | 时间目标 | 用途 | 失败处理 |
|---|---|---:|---|---|
| L0 | syntax/load | 秒级 | 快速发现语法/依赖问题 | 立即修 |
| L1 | focused unit | 秒~分钟 | 单功能测试 | 不提交或单独修 |
| L2 | root/current | < 1 分钟 | 当前架构回归 | 必须绿 |
| L3 | parallel probes | 1~5 分钟 | 多脚本并行证据 | 标记失败脚本 |
| L4 | package matrix | 5~15 分钟 | 独立包健康度 | 分包定位 |
| L5 | external smoke | 5~30 分钟 | Docker/Godot/K8s | 环境与代码分离归因 |
| L6 | stress/nightly | 30 分钟以上 | 大规模/长时实验 | 只进 nightly/manual |

---

## 2. L0：语法/加载

### Julia load

```bash
julia --project=. -e 'using SatelliteSimJulia; println("root load ok")'
```

### Server load

```bash
julia --project=src/server -e 'using SatelliteSimServer; println("server load ok")'
```

### Platform load

```bash
julia --project=platform/api -e 'using PlatformAPI; println("api load ok")'
julia --project=platform/storage -e 'using Storage; println("storage load ok")'
julia --project=platform/scheduler -e 'using K8sScheduler; println("scheduler load ok")'
```

### Shell parse

```bash
bash -n platform/scripts/smoke_local.sh platform/scripts/smoke_k3s.sh platform/scripts/smoke_api.sh
```

### Godot parse

```bash
Godot --headless --path godot-sandbox --quit
```

---

## 3. L1：Focused tests

### AI worker

```bash
julia --project=. test/ai/test_agent_worker.jl
```

当前证据：

```text
AI agent worker protocol | 24 passed
```

### Revise hot reload

```bash
julia --project=. scripts/probe_revise_hot_reload.jl
```

当前证据：

```text
Revise hot reload probe PASS
```

### Server package

```bash
julia --project=src/server -e 'using Pkg; Pkg.test()'
```

当前证据：

```text
SatelliteSimServer | 83 passed
```

### Starlink reconstruction small

```bash
julia --project=. scripts/reconstruct_starlink_real_orbits.jl \
  --max-sats 4 \
  --duration-s 60 \
  --step-s 60 \
  --output-dir /tmp/satsim_starlink_probe
```

当前证据：

```text
positions shape: (4, 2, 3) ECEF km
```

---

## 4. L2：Root/current suite

命令：

```bash
julia --project=. test/runtests_current.jl
```

当前证据：

```text
SatelliteSimJulia current test suite | 286 passed
```

覆盖：

- Foundation smoke。
- Orbit walker。
- Link GSL。
- Net topology/routing/CGR。
- Metrics。
- Security。
- Integration。
- Viz non-rendering API/CZML。
- CLI commands。

限制：

- 不覆盖完整 AI suite。
- 不覆盖 Docker/K8s。
- Viz rendering 默认跳过。

---

## 5. L3：Parallel validation

命令：

```bash
SATSIM_PARALLEL_JOBS=4 SATSIM_CHILD_THREADS=2 julia --project=. scripts/run_parallel_validation.jl
```

当前证据：

```text
SUMMARY: 15 passed, 0 failed
```

默认任务：

1. root_precompile
2. quick_validate
3. smoke_core_net_lab
4. probe_e2e
5. probe_opt
6. probe_type_stability
7. probe_experiment_matrix
8. probe_orbit_propagator_matrix
9. probe_topology_strategy_matrix
10. probe_routing_algorithm_matrix
11. probe_traffic_aon_power
12. probe_lab_integration_boundaries
13. probe_ai_offline_react_planner
14. probe_viz_czml_artifact
15. probe_revise_hot_reload

适用：

- 每次较大改动后。
- 提交前。
- 长任务 checkpoint。

---

## 6. L4：Package matrix

命令：

```bash
SATSIM_RUN_PACKAGE_TESTS=1 SATSIM_PACKAGE_TEST_JOBS=3 julia --project=. scripts/run_parallel_validation.jl
```

或：

```bash
SATSIM_PACKAGE_TEST_JOBS=3 julia --project=. scripts/package_tests.jl
```

当前已知证据：

```text
PACKAGE RESULT: 9/9 passed
```

包：

- Foundation
- Orbit
- Link
- Metrics
- Core
- Net
- Traffic
- Lab
- Opt

---

## 7. L5：External smoke

### Docker Compose

```bash
bash platform/scripts/smoke_local.sh
```

当前证据：

```text
SMOKE API: ALL PASS
SMOKE LOCAL: ALL PASS
```

验证链路：

```text
Docker build -> PostgreSQL -> MinIO -> PlatformAPI -> migration -> register/auth -> create experiment -> upload config
```

### Godot + Server

前提：server 运行在 `127.0.0.1:8080`。

```bash
SATSIM_PERF_CONSTS=iridium Godot --headless --path godot-sandbox -s godot-sandbox/tests/perf_gui_probe.gd
```

当前证据：

```text
PASS
avg_fps ~= 145
```

### kind/K8s

前提：kind context `kind-satnet`，镜像已 load。

```bash
API_LOCAL_PORT=18081 bash platform/scripts/smoke_k3s.sh
```

当前证据：

```text
SMOKE API: JOB SUCCEEDED
SMOKE K3S: ALL PASS
```

验证链路：

```text
K8s manifests -> pods ready -> DB migration -> MinIO bucket -> API -> submit job -> runner -> status succeeded
```

---

## 8. L6：Stress/nightly

这些不应阻塞普通提交，但应定期跑。

### Full Starlink reconstruction

```bash
JULIA_NUM_THREADS=12 julia --project=. scripts/reconstruct_starlink_real_orbits.jl \
  --max-sats 0 \
  --duration-s 3600 \
  --step-s 60 \
  --write-positions
```

### 14 constellation Godot perf

```bash
Godot --headless --path godot-sandbox -s godot-sandbox/tests/perf_gui_probe.gd
```

### Platform many-job

待实现：

```bash
platform/scripts/smoke_many_jobs.sh --jobs 10
```

### Full package + server + viz

```bash
SATSIM_RUN_PACKAGE_TESTS=1 \
SATSIM_RUN_SERVER_GROUP=1 \
SATSIM_RUN_VIZ_GROUP=1 \
SATSIM_PARALLEL_JOBS=4 \
julia --project=. scripts/run_parallel_validation.jl
```

---

## 9. 提交前推荐组合

### 快速代码改动

```bash
julia --project=. test/runtests_current.jl
```

### 中等功能改动

```bash
SATSIM_PARALLEL_JOBS=4 SATSIM_CHILD_THREADS=2 julia --project=. scripts/run_parallel_validation.jl
julia --project=. test/ai/runtests.jl
```

### Server/Godot 改动

```bash
julia --project=src/server -e 'using Pkg; Pkg.test()'
SATSIM_PERF_CONSTS=iridium Godot --headless --path godot-sandbox -s godot-sandbox/tests/perf_gui_probe.gd
```

### Platform 改动

```bash
bash platform/scripts/smoke_local.sh
API_LOCAL_PORT=18081 bash platform/scripts/smoke_k3s.sh
```

---

## 10. 失败归因模板

每个失败必须记录：

```text
Command:
Exit code:
Failing file/test:
Last good commit/tag:
Failure class:
  - dependency
  - syntax/load
  - unit logic
  - integration contract
  - external service
  - performance timeout
  - flaky/environment
Minimal reproduction:
Next action:
```

---

## 11. 推进规则

1. 不因为 stress 失败阻塞 P0/P1 小提交。
2. 不把大输出文件直接提交到 git。
3. 每个新脚本必须有 small-mode。
4. 每个外部 smoke 必须允许端口覆盖。
5. 每个 AI agent 新能力必须有 MockProvider 测试。
6. 每个 Godot 新 payload 字段必须有 server contract test。
7. 每个 platform 新链路必须能在 Docker Compose 或 kind 中验证。
