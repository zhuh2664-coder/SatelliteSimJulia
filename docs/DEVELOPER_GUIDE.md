# SatelliteSimJulia — 开发者指南 / Developer Guide

> **状态 / Status**: 框架已就位，各扩展点的详细步骤待补全。
> This file was created to fix broken README links ([#3](https://github.com/zhuh2664-coder/SatelliteSimJulia/issues/3)). Detailed content TBD.

---

## 核心扩展原则

本项目遵循 **Open-Closed 原则**：所有扩展点均通过 `abstract type` + 子类型 + 多重分派实现。  
**加新功能 = 加新子类型，不改老代码。**

---

## 如何添加新拓扑策略 / Adding a New Topology Strategy

1. 在 `src/net/` 下新建文件，定义 `abstract type TopologyStrategy` 的子类型：

```julia
# src/net/my_topology.jl
struct MyTopologyStrategy <: TopologyStrategy
    param::Int
end
```

2. 实现 `build_topology(s::MyTopologyStrategy, sats, t) -> AdjacencyMatrix` 方法。
3. 在防腐层添加 `TopologyIntent` → `MyTopologyStrategy` 的翻译规则。

> TODO: 补充完整的函数签名、测试模板和示例。

---

## 如何添加新路由算法 / Adding a New Routing Algorithm

1. 在 `src/net/` 下定义 `abstract type RoutingAlgorithm` 的子类型。
2. 实现 `route(algo::MyRouting, graph, src, dst) -> RoutePath`。
3. 在 `RoutingIntent` 防腐层注册。

> TODO: 补充 ECMP / MinLoad 参考实现对比。

---

## 如何添加新传播器 / Adding a New Propagator

1. 在 `src/orbit/` 下定义 `abstract type Propagator` 的子类型。
2. 实现 `propagate(p::MyProp, sat, tgrid) -> Array{Float64,3}`，返回 N×T×3 位置数组。
3. 确保与 `SimulationTimeGrid` 的时间轴对齐。

> TODO: 补充与 SatelliteToolbox 的集成示例（SGP4/TLE）。

---

## 如何添加新 AI 工具 / Adding a New AI Tool

1. 在 `src/lab/` 下用函数定义工具，并以 `@tool` 宏（或等效方式）注册。
2. 提供 schema：工具名、描述、参数类型。
3. 在 `LLMProvider` 的工具列表中声明，`demo()` 会自动列出。

> TODO: 补充 schema 格式与 DeepSeek API 对接示例。

---

## 如何添加新实验 / Adding a New Experiment

1. 在 `ExperimentConfig` 中声明意图字段（使用 `ConstellationIntent` / `TopologyIntent` 等，不暴露实现名词）。
2. 在 `run_experiment` 的分派链中添加对应实现。
3. 在 `sweep` 中注册新参数轴（如有需要）。

> TODO: 补充完整示例与测试模板。

---

## 测试规范 / Testing

```bash
julia --project=. -e 'using Pkg; Pkg.test()'
```

每个新功能须在 `test/` 下添加对应测试，确保：
- 新子类型能被 `demo()` 跑通
- 新传播器输出与 `SimulationTimeGrid` 对齐
- 新 AI 工具能被 `agent_repl` 正确调用

---

## 另见 / See Also

- [用户手册](USER_GUIDE.md)
- [API 参考](API_REFERENCE.md)
- [平台状态报告](PLATFORM_STATUS_REPORT.md)
