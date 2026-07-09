# SatelliteSimJulia 最大化推进作战总纲

日期：2026-07-05
分支：`codex/add-opt-lab-tests`

> 目标：在算力、模型、token 预算不受限的假设下，用最暴力但仍可验证、可回滚、可持续的方式推进 SatelliteSimJulia。本文不是普通 roadmap，而是把当前项目拆成若干可并行攻坚战线，每条战线都绑定产物、验证门、失败处理和下一批实验。

---

## 0. 当前已验证基线

当前仓库已经不再只是单机 Julia 原型，而是具备以下可验证资产：

### 0.1 科学/仿真内核

- Walker/设计星座生成。
- Real TLE / SGP4 传播入口。
- Keplerian TwoBody/J2/J4 传播器。
- ISL/GSL 物理可见性。
- topology strategies：GridPlus、Spiral、Honeycomb、Ring、Mesh 等。
- Dijkstra/ECMP/MinLoad/CGR 路由。
- coverage、latency、network metrics。
- traffic bridge 与 power/traffic primitives。
- differentiable opt/probe 路径。

### 0.2 AI / agent 层

- ReAct 风格 `SimAgent`。
- MockProvider 与 AI test suite。
- multi-agent team graph、artifacts、checkpoint。
- agent worker protocol：worker 注册 agent type，service 按 `(namespace, name)` 路由，lazy activation，event/RPC dispatch。
- Revise hot reload probe。
- MCP tools 与长任务 workflow skill 已落地。

### 0.3 可视化 / Godot 数字孪生

- Julia Viz/CZML 导出。
- Godot WebSocket streaming。
- satellite MultiMesh。
- ISL available/unavailable links。
- trails、earth grid、ground stations、GSL、coverage summary。
- shell / orbit-ring / deployment visualization。
- headless perf probe。

### 0.4 平台化部署

- PlatformAPI package。
- Storage/PostgreSQL。
- MinIO S3 config/result IO。
- runner container。
- K8s scheduler。
- Docker Compose smoke。
- kind/Kubernetes smoke，含 Job submit -> poll -> succeeded。

---

## 1. 已通过的关键验证门

这些验证门定义当前可信基线。后续每次暴力推进后，至少要回到这些门。

| 验证门 | 命令 | 当前证据 |
|---|---|---|
| Root current suite | `julia --project=. test/runtests_current.jl` | `286 passed` |
| AI suite | `julia --project=. test/ai/runtests.jl` | `185 passed` |
| Server package | `julia --project=src/server -e 'using Pkg; Pkg.test()'` | `83 passed` |
| Parallel validation | `SATSIM_PARALLEL_JOBS=4 SATSIM_CHILD_THREADS=2 julia --project=. scripts/run_parallel_validation.jl` | `15 passed, 0 failed` |
| Agent worker focused | `julia --project=. test/ai/test_agent_worker.jl` | `24 passed` |
| Revise probe | `julia --project=. scripts/probe_revise_hot_reload.jl` | PASS |
| Starlink reconstruction small | `julia --project=. scripts/reconstruct_starlink_real_orbits.jl --max-sats 4 --duration-s 60 --step-s 60 --output-dir /tmp/satsim_starlink_probe` | PASS |
| Godot perf smoke | `SATSIM_PERF_CONSTS=iridium Godot --headless --path godot-sandbox -s godot-sandbox/tests/perf_gui_probe.gd` | PASS, ~145 FPS |
| Docker Compose smoke | `bash platform/scripts/smoke_local.sh` | `SMOKE LOCAL: ALL PASS` |
| kind/K8s smoke | `API_LOCAL_PORT=18081 bash platform/scripts/smoke_k3s.sh` | `SMOKE K3S: ALL PASS` |

---

## 2. 暴力推进原则

### 2.1 无限 token / 无限模型时，不要只写代码

最高收益不是盲目堆功能，而是建立“实验工厂”：

1. 自动生成实验。
2. 自动执行。
3. 自动保存证据。
4. 自动比较基线。
5. 自动把失败变成 issue/任务。
6. 自动把成功变成 docs + artifact + test。

### 2.2 每个推进批次必须有四件东西

| 项 | 说明 |
|---|---|
| Artifact | 代码、报告、数据、图、容器镜像、Godot 场景、API endpoint 等 |
| Evidence | 测试输出、benchmark、JSON summary、截图、CZML、K8s job logs |
| Gate | 可重复命令，退出码能表达成功/失败 |
| Commit | 小而清晰，避免把不同战线混在一起 |

### 2.3 暴力但不失控的提交策略

建议每批最多三类提交：

1. `probe/report`：先证明要做什么、现状是什么。
2. `implementation`：实现功能。
3. `validation/docs`：把验证和使用方式固定下来。

---

## 3. 五条主攻战线

## 战线 A：科学真实性 / StarPerf 化

### 当前基础

- `scripts/reconstruct_starlink_real_orbits.jl`
- `scripts/reconstruct_starlink_real_orbits_report.txt`
- TLE -> SGP4 -> ECEF km tensor 已通。

### 暴力推进目标

把项目从“能模拟星座”推进到“可复现实验论文/真实星座快照”。

### 下一批实验

1. **全量 Starlink TLE 重建**
   - `--max-sats 0`
   - 输出全量 ECEF tensor summary。
   - 记录内存、耗时、N/T/shape。

2. **Starlink launch group 分层分析**
   - 按 launch group / shell / inclination / mean motion 聚类。
   - 输出每组卫星数、轨道统计、覆盖/连通性差异。

3. **真实星座 vs Walker 近似误差**
   - 对比同数量 Walker 与真实 TLE 星座：
     - coverage ratio
     - ISL availability
     - route latency
     - connectivity

4. **时间窗口敏感性**
   - 10min、1h、6h、24h。
   - 观察 coverage/revisit/latency 波动。

5. **真实 TLE 数据版本化**
   - 将 TLE snapshot metadata 写入 report。
   - 不一定提交大数据，但要记录 source path、record count、epoch range。

### 推荐产物

- `docs/REAL_CONSTELLATION_RECONSTRUCTION.md`
- `outputs/starlink_real_orbits/starlink_real_orbits_summary.json`
- `scripts/compare_real_vs_walker.jl`
- `scripts/probe_starlink_shells.jl`

### 验证门

```bash
julia --project=. scripts/reconstruct_starlink_real_orbits.jl --max-sats 32 --duration-s 120 --step-s 60 --write-positions
```

---

## 战线 B：实验工厂 / 大规模矩阵

### 当前基础

- `scripts/probe_experiment_matrix.jl`
- `scripts/probe_experiment_matrix_report.txt`
- 目前有限内置 intent space：34,992 组合。

### 暴力推进目标

把 Lab 层变成可以批量生产实验结果、失败样本、图表和报告的机器。

### 下一批实验

1. **矩阵采样器**
   - smoke：随机 20 个组合。
   - medium：每维 pairwise 组合。
   - full construct：全 34,992 只构造不运行。

2. **实验结果数据库化**
   - 每个 run 输出 JSONL。
   - 字段：config hash、git commit、duration、metrics、errors。

3. **失败归因器**
   - 将失败分为：配置非法、传播失败、拓扑失败、路由失败、指标失败、性能超时。

4. **自动生成 markdown 报告**
   - top 10 latency configs。
   - top 10 coverage configs。
   - Pareto frontier。

5. **Lab -> Platform Job 对接**
   - 将本地矩阵的一个任务提交到 K8s runner。
   - 验证 result.json 回收。

### 推荐产物

- `scripts/run_experiment_matrix_sample.jl`
- `docs/EXPERIMENT_FACTORY.md`
- `outputs/experiment_matrix/*.jsonl`

### 验证门

```bash
SATSIM_EXPERIMENT_MATRIX_MODE=smoke julia --project=. scripts/probe_experiment_matrix.jl
```

---

## 战线 C：平台可靠性 / 部署工程

### 当前基础

- `platform/scripts/smoke_local.sh` 已通过。
- `platform/scripts/smoke_k3s.sh` 已通过。
- API -> Storage -> MinIO -> Scheduler -> K8s Job -> Runner -> status succeeded 已通。

### 暴力推进目标

把平台从 demo smoke 推到可持续 CI/CD 和多任务可靠运行。

### 下一批实验

1. **并发 job smoke**
   - 同时提交 5/10/20 个 job。
   - 观察 K8s Job 成功率、DB 状态一致性、MinIO result key。

2. **失败 job 注入**
   - 非法 config。
   - runner crash。
   - MinIO 不可达。
   - DB 短暂断开。

3. **API auth/tenant fuzz**
   - 缺 token、错 token、跨 owner ID 访问、下载别人的结果。

4. **日志与 artifact 完整性**
   - Job logs 是否回写。
   - result.json 是否存在。
   - runner_logs 是否能帮助定位失败。

5. **CI 中 kind smoke**
   - 如果 CI 太慢，分 nightly。

### 推荐产物

- `scripts/platform_submit_many_jobs.jl` 或 `platform/scripts/smoke_many_jobs.sh`
- `docs/PLATFORM_RELIABILITY_PLAN.md`
- `platform/scripts/smoke_failure_modes.sh`

### 验证门

```bash
bash platform/scripts/smoke_local.sh
API_LOCAL_PORT=18081 bash platform/scripts/smoke_k3s.sh
```

---

## 战线 D：Godot 数字孪生 / 可视化产品化

### 当前基础

- 66-sat Iridium headless perf：~145 FPS。
- Shells / Rings / Deploy toggles。
- Ground stations / GSL / coverage。

### 暴力推进目标

把 Godot sandbox 从“可看”推进到“可解释、可演示、可录屏、可定位问题”的数字孪生。

### 下一批实验

1. **14 星座全量 perf dashboard**
   - 当前已有 regression/perf 测试基础。
   - 输出每星座 n_sat、frames、avg/min FPS。

2. **payload schema contract**
   - Godot 侧验证 positions length、isl index bounds、gsl shape。
   - 对 malformed frame 不崩溃，只报警。

3. **录屏/截图自动产物**
   - 每个星座输出 PNG 或短视频。
   - 存在 `outputs/godot_smoke/`。

4. **交互行为自动化**
   - start/pause/resume/stop。
   - toggle shells/rings/deploy/GSL/coverage。
   - select satellite。

5. **大星座 stress**
   - Starlink subset 512/1024/4096。
   - 记录 MultiMesh、ISL mesh、trail memory。

### 推荐产物

- `godot-sandbox/tests/regression_visual_layers.gd`
- `docs/GODOT_DIGITAL_TWIN_PLAN.md`
- `outputs/godot_perf/*.json`

### 验证门

```bash
SATSIM_PERF_CONSTS=iridium Godot --headless --path godot-sandbox -s godot-sandbox/tests/perf_gui_probe.gd
```

---

## 战线 E：AI 自主推进 / AgentOps

### 当前基础

- `agent_worker.jl`
- `test_agent_worker.jl`
- multiagent/team graph/checkpoint/artifacts。
- MCP 工具。
- Revise probe。

### 暴力推进目标

让 AI agents 不只是回答问题，而是能稳定驱动项目：分解任务、执行工具、记录证据、生成 PR 草案。

### 下一批实验

1. **Agent worker queue**
   - 当前是进程内 dispatch。
   - 下一步加入 job queue / mailbox。

2. **long task supervisor**
   - 分配任务给 planner/runner/reviewer。
   - 自动产出 todo、commands、evidence。

3. **Tool permission dry-run**
   - 每个 agent 的工具白名单。
   - dangerous actions 需要 HITL。

4. **Agent trace -> docs**
   - 每次 agent run 自动写 markdown summary。

5. **Agent-driven experiment factory**
   - planner 选实验。
   - runner 调脚本。
   - reviewer 看 JSON/test output。
   - writer 生成 docs。

### 推荐产物

- `scripts/agent_drive_experiment.jl`
- `docs/AGENTOPS_PLAN.md`
- `test/ai/test_agent_supervisor.jl`

### 验证门

```bash
julia --project=. test/ai/runtests.jl
julia --project=. scripts/probe_revise_hot_reload.jl
```

---

## 4. 暴力推进排序

如果只选最暴力的 10 件事，按收益排序：

1. 实验矩阵采样器 + JSONL 结果库。
2. Starlink real-vs-Walker 对比。
3. Platform 并发 job smoke。
4. Godot 14 星座 perf JSON dashboard。
5. Agent supervisor：planner/runner/reviewer 自动跑一个实验并写报告。
6. 大星座 stress：512/1024/4096 satellites。
7. Failure injection：平台/runner/API/MinIO/DB。
8. 真实 TLE shell clustering。
9. CI 分层验证：fast / nightly / external。
10. 自动 PR report generator。

---

## 5. 当前立即可执行命令

### 5.1 并行核心验证

```bash
SATSIM_PARALLEL_JOBS=4 SATSIM_CHILD_THREADS=2 julia --project=. scripts/run_parallel_validation.jl
```

当前结果：

```text
SUMMARY: 15 passed, 0 failed
```

### 5.2 带 server 的扩展验证

```bash
SATSIM_RUN_SERVER_GROUP=1 SATSIM_PARALLEL_JOBS=4 SATSIM_CHILD_THREADS=2 julia --project=. scripts/run_parallel_validation.jl
```

### 5.3 package 扩展验证

```bash
SATSIM_RUN_PACKAGE_TESTS=1 SATSIM_PACKAGE_TEST_JOBS=3 julia --project=. scripts/run_parallel_validation.jl
```

### 5.4 外部平台验证

```bash
bash platform/scripts/smoke_local.sh
API_LOCAL_PORT=18081 bash platform/scripts/smoke_k3s.sh
```

---

## 6. 风险清单

| 风险 | 影响 | 处理 |
|---|---|---|
| 大量 TLE 数据不适合直接提交 | repo 膨胀 | 提交 metadata/report，不提交大输出 |
| Godot dummy renderer 报 `Parameter m is null` | 噪音，可能隐藏真实渲染问题 | 增加专门 visual layer regression |
| K8s smoke 依赖 kind/local images | CI 不稳定 | 分 local/nightly gate |
| Revise 是 dev dependency | root deps 增加 | 已在 Project.toml 声明，保持 probe 可复现 |
| Agent 自动执行工具可能越权 | 安全/误操作 | permission policy + HITL |
| 实验矩阵过大 | 时间爆炸 | smoke/pairwise/full-construct 分层 |

---

## 7. 下一轮推荐提交包

### 包 1：Experiment Factory MVP

- `scripts/run_experiment_matrix_sample.jl`
- `docs/EXPERIMENT_FACTORY.md`
- JSONL 输出。
- 测试：smoke 5/20 configs。

### 包 2：Godot visual regression

- `godot-sandbox/tests/regression_visual_layers.gd`
- schema guard。
- perf JSON 输出。

### 包 3：Platform reliability smoke

- 多 job 提交。
- failure injection。
- job logs/result artifacts 验证。

### 包 4：AgentOps supervisor

- agent worker queue。
- experiment-driving demo。
- trace report。

---

## 8. 完成定义

本“最大化推进”不是一次性结束，而是建立项目加速闭环。每轮必须满足：

1. 有新增可运行 artifact。
2. 有可重复验证命令。
3. 有文档解释结果。
4. 有测试或 smoke 证据。
5. 有小粒度 commit。
6. 有明确下一轮 backlog。
