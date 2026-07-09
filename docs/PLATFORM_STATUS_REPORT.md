# SatelliteSimJulia 仿真测试平台全面报告

> 日期：2026-07-03
> 基于全仓库源码审计 + 32 个分层实验 + 4 条验证路线

> ⚠️ **时效声明**：本报告是 **2026-07-03 的快照**，不代表当前最新状态。其中 **AI 适配层** 章节已明显滞后于后续 `src/lab/src/layers/12_interaction/` 的实现——报告称该层"规则骨架/未接 LLM/src 内零 LLM 调用"，但实际代码已有 `llm_provider`（真实 HTTP.post 调 OpenAI 格式端点）、`agent`（ReAct 循环）、`multiagent`/`team_graph`、`tool_registry` 等接线实现。判断该层实际成熟度请以 `src/lab/src/layers/12_interaction/` 源码、`src/lab/test/` 及 `scripts/probe_ai_*.jl` 为准，不要直接引用本报告结论。其余章节的包规模/文件数也为 07-03 快照，可能已变。

---

## 第一部分：仿真引擎

### 架构总览

```
SatelliteSimJulia（顶层伞包）
├── SatelliteSimFoundation   — 物理基础（时间/坐标/常量/实体）
├── SatelliteSimOrbit        — 轨道（walker/传播器/星历）
├── SatelliteSimLink         — 链路（ISL/GSL评估/约束/几何）
├── SatelliteSimNet          — 网络（7种拓扑/4种路由/切换策略）
├── SatelliteSimMetrics      — 指标（覆盖/时延/容量/中心性）
├── SatelliteSimOpt          — 可微优化（J2/SGP4可微+PINN+Adam）
├── SatelliteSimTraffic      — 流量分配（AoN）
├── SatelliteSimCore         — 聚合包（@reexport 上述 + catalog）
├── SatelliteSimLab          — 实验编排 + AI 交互
├── SatelliteSimViz          — 可视化（弱依赖）
└── SatelliteSimSysimage     — 预编译镜像
```

### 包规模

| 包 | 文件 | 行数 | 角色 |
|---|---|---|---|
| foundation | 7 | 1044 | 最底层物理基础 |
| orbit | 10 | 2325 | 轨道生成+传播 |
| link | 6 | 1814 | 链路物理评估 |
| net | 16 | 1680 | 拓扑+路由 |
| metrics | 6 | 1129 | 指标计算 |
| opt | 21 | 2820 | 可微优化 |
| traffic | 2 | 532 | 流量分配 |
| lab | 19 | 2193 | 编排+AI |
| viz | 1 | 375 | 可视化 |
| **合计** | **88** | **~14000** | |

### 裸数组主路径（已验证完整）

```
generate_walker_delta(T,P,F; alt_km, inc_deg)     → Vector{KeplerianElements}
    ↓
propagate_to_ecef(elems, tspan; propagator)        → Array{Float64,3} (N×T×3 km)
    ↓
evaluate_isl_batch(pos, links; constraints)        → Vector{NamedTuple}(.available,.distance_km,.latency_ms)
evaluate_gsl_batch(pos, gs_tuples; constraints)    → (avail, dist, elev, delay)
    ↓
generate_topology(strategy, T, P)                   → TopologyOutput(.static_links,.dynamic_candidates)
    ↓
build_adjacency(N, edges, weights)                  → Matrix{Float64}
all_pairs_shortest_paths(adj)                       → D matrix (Floyd-Warshall)
    ↓
compute_coverage/latency/network_metrics/...        → 指标结果
```

**多重分派入口**：propagate_to_ecef 有 2 个方法（KeplerianElements → TwoBody/J2/J4，TLEOrbitElementSet → SGP4），自动选择。

### 传播器清单

| 传播器 | 精度（1天） | 可微 | 用途 |
|---|---|---|---|
| TwoBody | ~400km | ✅（opt包） | 快速仿真/可微优化 |
| J2 | ~1km | ✅（opt包） | 中等精度/可微首选 |
| J4 | ~0.9km | ❌ | 解析 truth（主链最高精度） |
| SGP4 | ~1-3km | ✅（opt包） | 真实TLE仿真 |
| HPOP | 亚米级 | ❌ | 数值积分 truth（DP8+J2加速度） |

### 拓扑策略（7种，多重分派）

GridPlus / TShape / Honeycomb / Ring / Spiral / NearestNeighbor / Mesh

### 路由算法（4种 + 切换策略3种）

Dijkstra / ECMP / MinLoad / PINN + ElevationThreshold / LongestVisible / NearestDistance

### 已验证的回归线（5条）

| 脚本 | 验证内容 |
|---|---|
| quick_validate.jl | 4包加载 + 集成测试 |
| smoke_core_net_lab.jl | 完整Lab实验（Walker→传播→ISL/GSL→路由） |
| probe_e2e.jl | 裸数组主路径数值（66/6 ISL 91/132、路由4356/4356全连通） |
| probe_opt.jl | 可微路径三路梯度（ForwardDiff/Reverse/FD 机器精度一致） |
| run_regression.jl | 一键全跑（5/5 退出码0） |

### 关键验证结论

- **网络指标对轨道精度敏感度 = 0%**（TwoBody/J2/J4 产出完全一致）——网络仿真用 TwoBody 够用
- **SGP4→裸数组桥接可用**（真实Starlink TLE 验证通过）
- **可微J2传播器 ForwardDiff 穿透成功**（梯度有限非零）
- **66/6 Iridium avg时延 58ms**（对标 Hypatia 50-150ms 范围）

### 待完善

1. **双路径不互通**：裸数组 vs 嵌套类型（ConstellationEphemeris）两套独立系统
2. **ECMP/MinLoad 路由**：实现了但主链 run_experiment 仍走 Floyd-Warshall
3. **test/ 目录全失效**：用旧类型，实际覆盖靠 5 个 scripts
4. **link_models.jl 1199行**：唯一超1000行的文件，待拆

---

## 第二部分：实验编排

### 编排层架构

```
用户/AI
    ↓ 意图（Symbol）
ExperimentConfig（防泄漏入口）
    ↓
run_experiment → full_constellation_assessment
    ├── propagate_constellation_positions
    ├── assess_coverage（GSL→覆盖率）
    ├── assess_routing（拓扑→ISL→Dijkstra→时延矩阵）
    ├── assess_routing_temporal（多时间步路由演化）
    ├── _assign_demands_to_isls（AoN流量分配）
    └── compute_*（6种指标）
    ↓
ExperimentResult → save/export（JSON/CSV/Markdown）
```

### ExperimentConfig（13字段）

name, constellation, propagator, tspan, constraints, topology_strategy, routing_algorithm, traffic_demands, ground_stations, users, random_seed, alpha, ground_pairs

**防泄漏设计**：用户接口只见意图（`:gridplus`/`:dijkstra`/`:two_body`），实现名词只在 intent_resolution.jl 内出现。

### 预编排工具（开发者经验封装）

| 工具 | 组合 | 用途 |
|---|---|---|
| propagate_constellation_positions | walker+propagate | 公共前置 |
| assess_coverage | gsl→coverage | 覆盖评估 |
| assess_routing | topology→isl→dijkstra | 路由评估 |
| assess_routing_temporal | 多时间步路由 | 时序演化 |
| full_constellation_assessment | 全套 | 完整评估 |

### 参数扫描

- `sweep(f, :param, values)` — 单参数扫描
- `sweep_dict(f, params)` — 多参数笛卡尔积

### 实验注册表

`AbstractExperiment` + `register!` + `cli_schema`（自动生成 LLM tool schema）。当前注册：DeadZoneScan。

### 数据持久化

- `save_experiment` → JSON（NaN/Inf→null）
- `to_csv` / `to_markdown` — 结果导出

### 已完成的分层实验（32个，159+34=193个检查全过）

| 层 | 实验 | 检查数 | 关键结果 |
|---|---|---|---|
| Foundation | F1-F3 | 18 | 常量/坐标/时间全对 |
| Orbit | O1-O7 + M1 | 37 | TwoBody 410km vs J2 0.9km/真实TLE |
| Link | L1-L7 | 24 | ISL距离/死区/时序链路 |
| Topology | T1-T4 | 23 | GridPlus 4度/边数=2T/全连通 |
| Routing | R1-R6 + R2进阶 | 46 | avg 58ms/churn 4次/快照损失0.5% |
| Metrics | M1-M5 | 20 | 覆盖率/重访/容量/切换/p50p95p99 |
| Optimization | X1-X4 | 13 | 三路梯度机器精度一致 |
| 星座对比 | O3-O4 | 44 | 5星座覆盖+时延+OneWeb部分连通 |
| 验证路线 | V1-V4 | 34 | 自洽+Hypatia对标+已知最优+HPOP truth |

### 待完善

1. **routing_algorithm 字段名存实亡**：记录意图但实际全走 Floyd-Warshall
2. **多壳层星座**：Starlink 有多个壳，当前只支持单壳 WalkerConstellationConfig
3. **端到端 RTT CDF**：compute_latency 从距离矩阵算，不是真实 OD 对路径延迟
4. **实验复现性**：没有 DrWatson.jl 式的 produce_or_load 缓存

---

## 第三部分：AI 适配

### 当前状态：骨架完整，接线缺失

```
┌─ AI 适配层（lab/12_interaction）─────────────────┐
│  ✅ goals.jl     — 6个目标 + 推荐指标/策略         │
│  ✅ studies.jl   — 6种研究类型 + run_study 闭环    │
│  ✅ planner.jl   — StudyPlan + 问卷→参数           │
│  ✅ questionnaire— REPL 交互式问卷                 │
│  ✅ study_dsl    — @study 宏 + walker 快捷构造     │
│  ✅ cli_schema   — LLM tool schema 自动生成        │
│  ✅ intent       — 防泄漏意图层（Symbol→实现翻译）   │
│                                                   │
│  ❌ LLM Provider 接线 — src/ 内无任何 LLM 调用      │
│  ❌ ReAct 循环 — 在 project_docs/ 原型里，未接入    │
│  ❌ 自然语言→意图 — 规则匹配，非 LLM 理解           │
└───────────────────────────────────────────────────┘
```

### 已有的 AI 资产

| 资产 | 位置 | 状态 |
|---|---|---|
| 意图层（Port） | intent.jl | ✅ 完整（8类意图符号表） |
| 意图翻译（Adapter） | intent_resolution.jl | ✅ 完整（防泄漏设计） |
| 目标目录 | goals.jl | ✅ 6个目标 |
| 研究类型 | studies.jl | ✅ 6种 + run_study 闭环 |
| 问卷 | questionnaire.jl | ✅ REPL 交互 |
| DSL | study_dsl.jl | ✅ @study 宏 |
| LLM tool schema | experiment.jl:37 | ✅ cli_schema 自动生成 |
| LLM Provider | project_docs/simagentcli/ | ⚠️ 独立原型，DeepSeek API |
| ReAct 循环 | project_docs/cli/ | ⚠️ 独立原型，~1100行 |

### project_docs/ 的两个原型

**simagentcli/**（轻量原型）：
- `providers/llm.jl` — DeepSeek API（OpenAI 格式），支持 function-calling
- `agent/agent.jl` — 规则优先规划，fallback LLM
- `tools/registry.jl` — 6 个工具 schema
- **未接入** SatelliteSimLab 的 study 体系

**cli/**（成熟原型，~1100行）：
- `providers.jl` — 抽象 ModelProvider + OpenAIProvider（流式 chat）
- `agent.jl` — 完整 ReAct 循环 + 历史持久化 + 上下文压缩
- **未接入** SatelliteSimLab

### AI 适配的断点

```
用户自然语言
    ↓ ❌ 缺失：NL→意图理解（需要 LLM）
意图（Symbol）
    ↓ ✅ 已有：intent → intent_resolution
ExperimentConfig
    ↓ ✅ 已有：run_experiment
ExperimentResult
    ↓ ✅ 已有：to_dict/to_csv/to_markdown
    ↓ ❌ 缺失：结果→自然语言解读（需要 LLM）
用户看到解读
```

**核心断点**：lab 包有完整的 AI-ready 骨架（意图/study/schema），project_docs 有可用的 LLM 调用代码，但**两者没有接线**。

### 接线方案（建议）

```
1. 把 project_docs/cli/providers.jl 的 LLM Provider 抽到 lab 包
   → src/lab/src/layers/12_interaction/llm_provider.jl

2. 把 project_docs/cli/agent.jl 的 ReAct 循环接到 study 体系
   → src/lab/src/layers/12_interaction/agent.jl
   → LLM 调用 cli_schema 生成的工具定义
   → LLM 返回 tool_call → 调 run_study

3. 自然语言→意图用 LLM function-calling
   → 用户说"看覆盖" → LLM 返回 {tool: "run_study", goal: "coverage_analysis"}
   → lab 的 study 体系执行
```

### 待完善

1. **LLM Provider 接线**：把 project_docs 的代码整合进 lab 包
2. **NL→意图**：用 LLM function-calling 替代规则匹配
3. **结果解读**：ExperimentResult → LLM → 自然语言摘要
4. **多轮对话**：ReAct 循环（观察→思考→行动→观察）
5. **实验复现**：DrWatson.jl 式 produce_or_load

---

## 总结：三部分成熟度

| 部分 | 成熟度 | 关键强项 | 关键缺口 |
|---|---|---|---|
| **仿真引擎** | 8/10 | 裸数组主路径完整+5种传播器+7种拓扑+4种路由+可微优化 | 双路径不互通/test失效/ECMP未接入主链 |
| **实验编排** | 7/10 | 防泄漏意图层+预编排工具+参数扫描+32个实验193检查 | routing_algorithm名存实亡/无多壳层/无DrWatson |
| **AI 适配** | 4/10 | 骨架完整(意图/study/schema/DSL)+两份LLM原型 | **src/内零LLM调用**/骨架与原型未接线/NL理解缺失 |

**综合判断**：仿真引擎能支撑论文级实验（已验证193个检查），实验编排够用但需打磨，AI适配是最大短板——骨架在但没接线。
