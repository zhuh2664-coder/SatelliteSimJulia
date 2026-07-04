# SatelliteSimJulia — API 参考 / API Reference

> **状态 / Status**: 框架已就位，各子包的完整符号列表待补全。
> This file was created to fix broken README links ([#3](https://github.com/zhuh2664-coder/SatelliteSimJulia/issues/3)). Detailed content TBD.

`using SatelliteSimJulia` 会 re-export 以下所有子包的公开符号。

---

## Foundation — 基础层

物理常量、时间网格、坐标/参考系、基础实体。

| 符号 | 类型 | 说明 |
|------|------|------|
| `SimulationTimeGrid` | struct | epoch + offsets，全链路共享的时间基准 |
| `Satellite` | struct | 卫星实体 |
| `GroundStation` | struct | 地面站实体 |
| `UserTerminal` | struct | 用户终端实体 |

> TODO: 补全所有导出函数与类型的签名和说明。

---

## Orbit — 轨道层

Walker 星座生成、二体/J2/J4/SGP4 传播、星历容器、TLE 数据源。

| 符号 | 类型 | 说明 |
|------|------|------|
| `walker_constellation` | function | 生成 Walker Star/Delta 星座 |
| `propagate_twobody` | function | 二体轨道传播 |
| `propagate_j2` | function | J2 摄动传播 |
| `position_at_instant` | function | 按时刻索引位置向量 |
| `positions_at_last` | function | 返回末时刻全星座位置 |

> TODO: 补全参数类型、返回值格式（Array{Float64,3} N×T×3）。

---

## Link — 链路层

ISL/GSL 物理链路评估、容量模型、约束。

> TODO: 补全 `assess_isl` / `assess_gsl` / `link_capacity` 等符号。

---

## Net — 网络层

ISL 拓扑策略（Grid+/T/Honeycomb/Ring/…）、路由（Dijkstra/ECMP/MinLoad）、接入决策。

> TODO: 补全 `TopologyIntent` / `RoutingIntent` 及其子类型列表。

---

## Metrics — 指标层

覆盖率、时延、网络指标、链路利用率、图论分析（介数/PageRank/Fiedler）、网络容量。

> TODO: 补全 `assess_coverage` / `assess_routing` 返回结构说明。

---

## Traffic — 流量层

AoN 流量分配：demand → RoutePath → ISL/GSL 链路负载样本。

> TODO: 补全流量模型 API。

---

## Opt — 优化层

可微 J2 传播、软 ISL/覆盖、端到端梯度、Adam、`optimize_coverage`。

| 符号 | 类型 | 说明 |
|------|------|------|
| `optimize_coverage` | function | 以 Adam 做端到端星座参数覆盖优化 |

> TODO: 补全 Enzyme/Zygote 可微接口说明。

---

## Lab — 编排层

`ExperimentConfig` / `run_experiment` / `sweep` / `Study` / `Goal` / `agent_repl` / `demo`。

| 符号 | 类型 | 说明 |
|------|------|------|
| `ExperimentConfig` | struct | 实验声明（星座意图 + 拓扑 + 路由 + 流量）|
| `run_experiment` | function | 执行单次实验，返回结构化结果 |
| `sweep` | function | 对某参数做扫描，返回结果数组 |
| `demo` | function | 跑通 Iridium 66/6 完整演示 |
| `agent_repl` | function | 启动 AI 仿真助手交互 REPL |

> TODO: 补全每个符号的完整函数签名与关键字参数。

---

## 另见 / See Also

- [用户手册](USER_GUIDE.md)
- [开发者指南](DEVELOPER_GUIDE.md)
- [平台状态报告](PLATFORM_STATUS_REPORT.md)
