# SatelliteSimJulia 实验工厂 Backlog

日期：2026-07-05

本文把“无限算力/无限模型”条件下最值得跑的实验整理成可执行 backlog。每个任务都包含目的、输入、产物、验证命令和完成判据。

---

## 1. Backlog 分级

| 等级 | 含义 | 运行策略 |
|---|---|---|
| P0 | 立即提升项目可信度 | 本地即可跑，必须进 fast/parallel validation |
| P1 | 大幅提升论文/演示价值 | 可较慢，进 nightly 或手动 smoke |
| P2 | 外部系统/大数据/大算力 | 分支实验，产出报告后再产品化 |

---

## 2. P0：立即执行

### P0-1 并行验证入口固化

- 文件：`scripts/run_parallel_validation.jl`
- 目的：把 scattered probes 变成单一并行验证入口。
- 当前验证：

```text
SUMMARY: 8 passed, 0 failed
```

- 推荐加入 README/DEV GUIDE。

命令：

```bash
SATSIM_PARALLEL_JOBS=4 SATSIM_CHILD_THREADS=2 julia --project=. scripts/run_parallel_validation.jl
```

完成判据：

- root precompile PASS。
- quick_validate PASS。
- smoke_core_net_lab PASS。
- probe_e2e PASS。
- probe_opt PASS。
- probe_type_stability PASS。
- probe_experiment_matrix PASS。
- probe_revise_hot_reload PASS。

---

### P0-2 Agent worker protocol 深化

当前基础：

- `src/lab/src/layers/12_interaction/agent_worker.jl`
- `test/ai/test_agent_worker.jl`

下一步：

1. 增加 mailbox queue。
2. 增加 worker health/status。
3. 增加 dispatch trace。
4. 增加 permission policy integration。
5. 增加 agent supervisor demo。

建议新增：

- `src/lab/src/layers/12_interaction/agent_supervisor.jl`
- `test/ai/test_agent_supervisor.jl`
- `scripts/agent_drive_experiment.jl`

完成判据：

```bash
julia --project=. test/ai/runtests.jl
```

---

### P0-3 Godot frame schema guard

当前问题：Godot 消费 server payload 时，对 malformed frame 的防御不足。

要做：

- positions length 必须等于 `n_sat * 3`。
- ISL pair index 必须在 `[1, n_sat]`。
- `gsl_shape` 与 `gsl_avail` 长度一致。
- ground station ecef 坐标必须存在或可降级。

建议新增：

- `godot-sandbox/tests/regression_payload_schema.gd`

完成判据：

```bash
Godot --headless --path godot-sandbox -s godot-sandbox/tests/regression_payload_schema.gd
```

---

### P0-4 Server metadata contract test

当前 server 已返回：

- `constellation`
- `shells`
- `ground_stations`
- `gsl_*`
- `coverage_summary`

要做：

- 把这些字段定义成 contract test。
- 测 `iridium` / `starlink_like` / `oneweb`。
- 确认 Godot 所需字段永远存在或有默认值。

完成判据：

```bash
julia --project=src/server -e 'using Pkg; Pkg.test()'
```

---

## 3. P1：实验价值最大化

### P1-1 Real Starlink vs Walker 对比

目标：证明项目不仅能跑合成 Walker，也能处理真实 TLE。

输入：

- real Starlink TLE records。
- Walker近似星座：相同卫星数量/高度/倾角粗匹配。

指标：

- coverage ratio。
- GSL visible count。
- ISL available ratio。
- average latency。
- connectivity ratio。

建议脚本：

- `scripts/compare_real_starlink_vs_walker.jl`

输出：

- `outputs/real_vs_walker/summary.json`
- `docs/REAL_VS_WALKER_REPORT.md`

完成判据：

```bash
julia --project=. scripts/compare_real_starlink_vs_walker.jl --max-sats 128 --duration-s 600 --step-s 60
```

---

### P1-2 14 星座 Godot perf dashboard

目标：把可视化性能从单点 smoke 变成表格报告。

输入：

- server catalog 14 constellations。
- Godot perf probe。

输出字段：

- name
- n_sat
- n_time
- frames
- avg_fps
- min_fps
- max_fps
- pass/fail

建议新增：

- `godot-sandbox/tests/perf_all_constellations_json.gd`
- `outputs/godot_perf/perf_summary.json`
- `docs/GODOT_PERF_REPORT.md`

完成判据：

```bash
Godot --headless --path godot-sandbox -s godot-sandbox/tests/perf_gui_probe.gd
```

---

### P1-3 Platform many-job smoke

目标：从单 Job 成功推进到并发稳定。

实验规模：

| 模式 | Job 数 | 用途 |
|---|---:|---|
| smoke | 3 | fast gate |
| medium | 10 | local nightly |
| stress | 50 | manual |

要验证：

- 全部 job 最终 succeeded/failed，有终态。
- DB status 与 K8s status 一致。
- result_key 可下载。
- runner_logs 写回。

建议新增：

- `platform/scripts/smoke_many_jobs.sh`
- `docs/PLATFORM_JOB_RELIABILITY_REPORT.md`

完成判据：

```bash
API_LOCAL_PORT=18081 platform/scripts/smoke_many_jobs.sh --jobs 10
```

---

### P1-4 Experiment matrix sampler

目标：从 34,992 组合中抽样生成指标地图。

采样模式：

- random 20。
- pairwise。
- per-axis extremes。
- full construct only。

输出：

- JSONL，每行一个 experiment result。
- markdown 排名报告。

建议新增：

- `scripts/run_experiment_matrix_sample.jl`
- `docs/EXPERIMENT_MATRIX_RESULTS.md`

完成判据：

```bash
julia --project=. scripts/run_experiment_matrix_sample.jl --mode random --n 20
```

---

## 4. P2：大算力实验

### P2-1 Starlink 全量 TLE 重建

命令：

```bash
JULIA_NUM_THREADS=12 julia --project=. scripts/reconstruct_starlink_real_orbits.jl \
  --max-sats 0 \
  --duration-s 3600 \
  --step-s 60 \
  --write-positions
```

风险：输出巨大，不要默认提交。

完成产物：

- summary JSON 提交。
- 大 tensor 放 `outputs/`，不进 git。

---

### P2-2 大星座 Godot stress

目标：测渲染上限。

规模：

- 512 satellites。
- 1024 satellites。
- 4096 satellites。

指标：

- FPS。
- mesh rebuild time。
- memory。
- UI 响应。

---

### P2-3 Failure injection lab

目标：让系统能解释失败，而不是只会失败。

注入：

- invalid TLE。
- impossible topology。
- DB down。
- MinIO down。
- K8s job timeout。
- malformed WebSocket frame。

产物：

- `docs/FAILURE_INJECTION_REPORT.md`
- failure category taxonomy。

---

## 5. 实验结果命名规范

建议所有新实验输出结构：

```text
outputs/<experiment_name>/
  metadata.json
  results.jsonl
  summary.json
  report.md
  logs/
```

`metadata.json` 必须包含：

```json
{
  "git_commit": "...",
  "command": "...",
  "started_at": "...",
  "finished_at": "...",
  "host": "...",
  "julia_version": "...",
  "thread_count": 0
}
```

---

## 6. 最小每日推进循环

如果每天暴力推进一次，固定节奏：

1. 跑 `scripts/run_parallel_validation.jl`。
2. 选一个 P0/P1 backlog。
3. 写 probe。
4. 跑小规模实验。
5. 写 report。
6. 把 probe/report/test 一起提交。
7. 如有外部系统，跑 Docker/Godot/K8s smoke。
8. 更新此 backlog。
