# SatelliteSimJulia

> **AgentOS/MCP 安全边界（默认）**：本仓库的 `agentos_app.py`、`scripts/mcp_tool_runner.jl` 与 `scripts/mcp_stdio_server.jl` 默认只暴露只读 safe tools：`list_constellations` 与 `describe_constellation`。仿真/传播、测试、`frame_payload_once`、PNG/CZML/JLD2/export、写文件与公网监听均不在默认 dispatch 中；AgentOS 强制绑定 `127.0.0.1` 且不启用 AgentOS API key。需要高风险或有副作用能力时，请离开默认 AgentOS/MCP 面，在本地 CLI 中显式手动运行。

**LEO 卫星星座仿真 + 可微优化 + AI 适配**——用 Julia 的类型系统、多重分派和裸数组构建的一条端到端卫星网络仿真流水线。

从「Walker 星座生成 → 轨道传播 → ISL/GSL 链路评估 → 拓扑/路由 → 流量/容量 → 指标」，全链路用裸 `Array{Float64,3}` 衔接、用多重分派扩展、并可微分以做梯度优化。上方再叠一层 AI 适配层，把自然语言请求翻译成仿真工具调用。

## 快速开始

```bash
# 1. 进入项目并安装依赖（首次）
julia --project=. -e 'using Pkg; Pkg.instantiate()'

# 2. 一行代码跑通完整仿真（Iridium 66/6 星座：生成→传播→ISL→路由→覆盖→多传播器对比→AI 工具）
julia --project=. -e 'using SatelliteSimJulia; demo()'
```

`demo()` 会依次演示：Walker 星座生成、二体传播、+Grid 拓扑、ISL 物理评估、最短时延路由、覆盖率计算、GSL 可见性、TwoBody/J2 传播器对比，最后列出可用的 AI 工具。全程无需任何外部数据。

## 部署与 CLI 快速验证

```bash
# 1. 部署依赖
julia --project=. -e 'using Pkg; Pkg.instantiate()'

# 2. 查看 CLI
julia --project=. bin/satnet.jl --help

# 3. 生成 Walker 星座位置矩阵
julia --project=. bin/satnet.jl propagate --T 12 --P 3 --steps 3 --duration 120 --output outputs/cli/positions.jld2

# 4. 生成 3D 快照 PNG
julia --project=. bin/satnet.jl viz snapshot outputs/cli/positions.jld2 --output outputs/cli/snapshot.png

# 5. 导出 Cesium CZML
julia --project=. bin/satnet.jl viz czml outputs/cli/positions.jld2 --output outputs/cli/constellation.czml

# 6. 回归测试
julia --project=. test/runtests_current.jl
```

> 注：可视化会优先尝试下载 NaturalEarth 海岸线数据；离线/网络失败时自动使用内嵌简化海岸线，不影响 PNG/CZML 产物生成。

如果想跑预编排实验或交互式 AI 助手：

```julia
using SatelliteSimJulia

run_examples()                  # 跑 3 个预编排示例（覆盖/路由/全套评估）
agent_repl(LLMProvider())       # 启动 AI 仿真助手 REPL（需配 DEEPSEEK_API_KEY）
```

## 三层架构

```
┌─────────────────────────────────────────────────────────────┐
│  AI 适配层（Layer 11-12）                                     │
│  自然语言 → 意图 → 工具编排 → 结果解读                          │
│  ExperimentConfig · Study/Goal · SimAgent(agent_repl) · LLM  │
├─────────────────────────────────────────────────────────────┤
│  编排层                                                       │
│  预编排工具（assess_coverage/assess_routing）                  │
│  + 实验框架（run_experiment / sweep / optimize_coverage）      │
│  + 意图翻译（Intent → 具体实现，防泄漏）                        │
├─────────────────────────────────────────────────────────────┤
│  工具层（原子工具，单一真相源）                                 │
│  Foundation → Orbit → Link → Net → Metrics → Traffic → Opt   │
│  Walker 传播 拓扑/路由 指标 流量 可微优化                       │
│  数据用裸 Array{Float64,3} (N×T×3) 串联，零抽象开销            │
└─────────────────────────────────────────────────────────────┘
```

每一层只调下一层的公开 API：工具层是单一真相源，编排层/AI 层都只是它的「便利组合」，不引入新的物理实现。

## 包结构

项目由 `SatelliteSimJulia` 这个聚合包统一 re-export，普通用户 `using SatelliteSimJulia` 即可拿到全部符号。底层按依赖方向拆成 10 个子包：

| 包 (`src/<dir>`) | 领域 | 一句话说明 |
|---|---|---|
| `foundation` | Foundation | 物理常量、时间网格、坐标/参考系、基础实体（Satellite/GroundStation/UserTerminal）|
| `orbit` | Orbit | Walker 星座生成、二体/J2/J4/SGP4 传播、星历容器、TLE 数据源 |
| `link` | Link | ISL/GSL 物理链路评估（距离/LOS/仰角/方位/时延）、容量模型、约束 |
| `net` | Net | ISL 拓扑策略（Grid+/T/Honeycomb/Ring/...）、路由（Dijkstra/ECMP/MinLoad）、接入决策 |
| `netsim` | NetSim | 分组级离散事件仿真：队列、传输协议、DTN、监控与双保真验证 |
| `metrics` | Metrics | 覆盖率、时延、网络指标、链路利用率、图论分析（介数/PageRank/Fiedler）、网络容量 |
| `traffic` | Traffic | AoN 流量分配：demand → RoutePath → ISL/GSL 链路负载样本 |
| `opt` | Opt | 可微 J2 传播、软 ISL/覆盖、端到端梯度、Adam、`optimize_coverage` 覆盖优化 driver |
| `lab` | Lab | 编排层：ExperimentConfig/run_experiment/sweep、Study/Goal、AI Agent(agent_repl)、demo |
| `core` | Core | 聚合包，re-export Foundation+Orbit+Link+Metrics，并持有星座目录/路由/流量目录 |

> `viz`（GLMakie 可视化）、`gmat`（GMAT 力模型适配）、`sysimage`（预编译镜像）是辅助包，不参与核心计算链路。

## 核心设计原则

1. **时间解耦**：所有层共享同一个 `SimulationTimeGrid`（epoch + offsets）。轨道传播、链路评估、流量、指标都按时间片索引对齐——改一处步长，全链路自动重对齐。
2. **多重分派扩展**：拓扑策略、路由算法、传播器、实验、AI 工具全是 `abstract type` + 子类型 + 方法分派。**加新功能 = 加新子类型，不改老代码**（Open-Closed）。
3. **裸数组主路径**：位置/速度用裸 `Array{Float64,3}`（N×T×3），配 `position_at_instant` / `positions_at_last` 等自解释访问器。零抽象、可多线程、易微分。
4. **可微优化**：`SatelliteSimOpt` 用 Enzyme/Zygote 提供可微 J2 传播 + 软覆盖 loss，`optimize_coverage(loss, x0)` 用 Adam 做端到端星座参数优化。
5. **意图防泄漏**：用户/AI 只看到 `TopologyIntent` / `RoutingIntent` / `ConstellationIntent` 这类工程意图，看不到 `GridPlusStrategy`/`DijkstraRouting` 等实现名词。翻译规则集中在防腐层。
6. **官方库优先**：能直接用 SatelliteToolbox（TLE/SGP4/ECEF↔LLA/带谐项传播）的，绝不自己写。

## 一个完整例子

```julia
using SatelliteSimJulia

# ── 用意图声明实验（防泄漏：不碰实现名词）──
config = ExperimentConfig(;
    name          = "quick_demo",
    constellation = ConstellationIntent(coverage=GlobalCoverage(),
                                        latency=LowLatencyConst(),
                                        scale=MediumScale()),  # → 自动选 Walker 参数
    topology      = BalancedTopo(),   # → 按 ctx 解析成具体策略
    routing       = ShortestPath(),
    traffic       = HotspotLoad(),
)

result = run_experiment(config)
println("覆盖: $(round(result.coverage.coverage_ratio*100, digits=1))%")
println("时延: $(round(result.latency.avg_latency_ms, digits=1)) ms")
println("连通: $(round(result.network.connectivity_ratio*100, digits=1))%")
```

## 文档

- [用户手册](docs/USER_GUIDE.md) — 6 个场景（覆盖评估 / 参数扫描 / 星座对比 / AI 仿真 / 可微优化 / TLE 仿真）
- [API 参考](docs/API_REFERENCE.md) — 每个包导出的类型与函数，按领域分组
- [开发者指南](docs/DEVELOPER_GUIDE.md) — 怎么加新拓扑 / 路由 / 传播器 / AI 工具 / 实验
- [平台状态报告](docs/PLATFORM_STATUS_REPORT.md) — 当前能力边界与路线图

## 测试

```bash
julia --project=. -e 'using Pkg; Pkg.test()'
# 或直接跑
julia --project=. test/runtests.jl
```

## 许可

内部研究项目，详见仓库根目录。
