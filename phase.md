# SatelliteSimJulia Phase 3：Lab 编排边界与根包 API 收敛

## 已完成的前置工作

- **Phase 1**：建立可重复的根包测试基线，修复 Link 批量 API 对零拷贝视图的兼容性，并明确根包与高级包的入口契约。
- **Phase 2**：移除 Net、Traffic、Security、Opt 对 `SatelliteSimCore` 聚合转发的隐式依赖；各子包改为声明直接依赖并支持独立解析。

## Phase 3 目标

把 `SatelliteSimLab` 固化为实验编排层，使依赖方向保持为：

```text
intent/config → resolution → runner → result ← interaction/agent/demo
```

根包 `SatelliteSimJulia` 只提供日常仿真的稳定门面；Agent、LLM、规划器及低层领域包必须从 `SatelliteSimLab` 或相应子包显式导入。

## 公开入口矩阵

| 场景 | 推荐入口 |
| --- | --- |
| 日常实验编排 | `using SatelliteSimJulia`；`ExperimentConfig`、`run_experiment`、`study`、`run_study` |
| 快速评估 | `assess_coverage`、`assess_routing`、`full_constellation_assessment` |
| 兼容演示 | `demo()`、`run_examples()` |
| Agent / LLM / REPL | `using SatelliteSimLab`；例如 `SatelliteSimLab.agent_repl(...)` |
| 轨道、链路、拓扑、指标等低层 API | 显式导入 `SatelliteSimCore`、`SatelliteSimNet` 或更细的子包 |
| 可微优化 | 显式导入 `SatelliteSimOpt` |

## 兼容与迁移

- 保留 `demo()` 与 `run_examples()`，但它们仅展示根包支持的日常仿真能力。
- `demo()` 不再宣传 `optimize_coverage` 或其他自动可用的优化 API；高级优化属于 `SatelliteSimOpt`。
- 根包不再自动转出 Agent/LLM、规划器和底层 Core/Net/Traffic 符号。现有调用应改为显式子包入口。
- `ExperimentConfig` 继续接受意图对象、旧 Symbol 写法与具体策略，以保留实验配置兼容性。

## 验证与验收

```bash
julia --project=. test/runtests.jl
julia --project=src/lab -e 'using Pkg; Pkg.instantiate(); Pkg.test()'
```

验收条件：Lab 可独立加载和测试；根包只导出约定的日常编排 API；交互 API 仍可由 `SatelliteSimLab` 调用；Demo 与预编排示例不再引用根包之外的 Opt 功能。

## 非本阶段范围

不修改 Server、Distributed、Security、Opt、Viz 的内部架构或包边界；它们将在后续 adapter/package 阶段单独处理。
