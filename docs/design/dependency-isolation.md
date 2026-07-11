# SatelliteSimJulia 依赖与后端隔离设计（正本）

> 更新：2026-07-09。完成状态只按测试证据判断，不按旧 Phase 文档判断。

## 目标

| 环境 | 目标规模/职责 | 用途 |
|---|---|---|
| `envs/core` | 约 130–140 包 | 主链 CI 冒烟与裸数组契约 |
| 根 / `envs/sim` | 日常编排 | `SatelliteSimJulia` + Lab 主流程 |
| `envs/opt` / `src/opt` | 独立重依赖 | Enzyme/Zygote/Lux 可微优化 |
| `envs/viz` | 独立重依赖 | Makie 可视化加载/出图 |
| `envs/gmat` | 独立适配 | GMAT 与高阶 ODE |
| `envs/security` | 独立实验 | 攻防与故障注入 |
| `envs/backends-stub` | 小于 20 包 | Stub 后端离线 CI |
| `envs/backends-integration` | 显式三后端集成 | Native / Stub / JuliaSpace 高层 E2E 与性能基线 |

## 依赖方向

```text
Foundation → Orbit → Link → Net → Traffic
     └──────────────→ Metrics
Foundation/Orbit/Link/Metrics → Core
主链领域包 → Lab（编排与 AI 控制面）

SatelliteSimBackends → Orbit（传播契约）
SatelliteSimBackends → Lab（选择/配置契约）
SatelliteSimBackends ← StubBackend
SatelliteSimBackends + SatelliteToolbox ← JuliaSpaceBackend

Opt / Security / Viz / GMAT：显式选择，不由根伞包隐式导出
```

硬约束：

1. `Net`、`Traffic`、`Security`、`Opt` 不依赖 `SatelliteSimCore`。
2. 本地包依赖必须有 `[sources]`。
3. 主链位置数组接受 `AbstractArray{<:Real,3}`，形状为 `(satellite,time,xyz)`。
4. 外部轨道后端返回 ECEF km，并通过 `validate_orbit_result`。
5. Stub 后端必须确定性、无重依赖，可在无网络服务的 CI 中运行。
6. 具体后端包不进入主链聚合依赖；用户必须显式加载它，才能在当前 Julia session 注册后端名称。

## 后端契约当前范围

已实现：

- `AbstractOrbitBackend`
- `OrbitResult`
- `backend_name` / `backend_capabilities`
- `propagate_orbit`
- `validate_orbit_result`
- `OrbitBackendSpec`
- `register_orbit_backend!` / `unregister_orbit_backend!`
- `available_orbit_backends` / `orbit_backend_registered`
- `create_orbit_backend`
- 确定性 `StubOrbitBackend`
- `SatelliteSimOrbit.propagate_with_backend` 与 `propagate_to_ecef(backend, ...)` 的显式 dispatch 入口
- `JuliaSpaceOrbitBackend` 在包内独立实现 `:two_body`、`:j2`、`:j4` 的长期项传播方程；运行时不调用或依赖 `SatelliteSimOrbit`
- JuliaSpace 与 Native 的多星、多时刻 ECEF 跨实现误差测试，当前最大误差 `5.46e-12 km`，门限 `1 m`；两者只共享 EGM2008 常数与 SatelliteToolbox TEME→PEF 坐标变换
- Stub 与 JuliaSpace 包通过 `__init__()` 分别注册 `:stub` 与 `:julia_space`
- `ExperimentConfig.orbit_backend` 保存后端中立规格；默认 `nothing` 走原生传播，具体类型不会泄漏到 Lab 配置
- Lab 单帧/多帧公共传播入口、缓存 hash 与实验记录均消费同一后端规格
- Native、Stub、JuliaSpace 经过同一个 `run_experiment(config)`，输出直接进入 GSL、ISL、全对路由与 Traffic AON
- 三个后端的 `(satellite,time,xyz)` `Array` 与三维 `SubArray` 端到端结果一致
- `scripts/benchmark_orbit_backends.jl` 记录三后端 shape、耗时、分配量与 JuliaSpace 相对 Native 的误差 CSV

尚未实现：

- 独立高保真数值力模型相对长期项解析模型的真值对标与物理误差预算；当前跨实现测试验证两份长期项实现及 frame/unit/shape/order 契约。
- backend options 的 schema、冲突校验与跨版本迁移策略。
- TLE/SGP4 等专用传播入口纳入统一后端配置。
- 跨提交的长期性能历史、抗噪统计与稳定回归阈值；当前脚本只记录单次基线，不设脆弱墙钟门限。

注册表只在当前 Julia session 内有效。`OrbitBackendSpec(:julia_space; propagator=:j2)` 中的 `propagator` 是后端专属选项；一旦选择外部后端，`ExperimentConfig.propagator` 不会隐式覆盖该选项。

## CI 分层

| 层 | 工作流 | 内容 |
|---|---|---|
| Core | `.github/workflows/test.yml` | boundary、core smoke、bare-array、Lab、Stub backend |
| Optional | `.github/workflows/optional.yml` | Opt、Security、Viz、GMAT |
| Nightly | `.github/workflows/nightly.yml` | 根当前回归、JuliaSpace adapter、三后端高层 E2E、性能基线 smoke |

本地门禁：

```bash
julia scripts/check_dependency_boundaries.jl
julia scripts/check_manifest_baseline.jl
julia --project=envs/core test/runtests_core_smoke.jl
julia --project=envs/core test/test_bare_array_contract.jl
julia --project=envs/backends-stub test/backends/test_stub_backend_pkg.jl
julia --project=envs/backends-integration -e 'using Pkg; Pkg.instantiate()'
julia --project=envs/backends-integration test/backends/test_backend_end_to_end.jl
julia --project=envs/backends-integration scripts/benchmark_orbit_backends.jl --smoke
```

Manifest 检查对不存在的文件输出 `SKIP`；在核心 CI 中，`envs/core` 与 `envs/backends-stub` 会先 instantiate，因此这两个基线有实际约束。根 Manifest 不提交，只在本地存在时报告。

## 实施状态

- **完成**：领域包去 Core 反向依赖、`[sources]`、边界脚本。
- **完成**：core/stub 环境 Manifest 与 +20% 增长门禁。
- **完成**：bare-array/SubArray 契约修复与测试。
- **完成**：后端接口包、Stub、JuliaSpace adapter 的包级测试；Orbit 显式 dispatch，以及 JuliaSpace `:two_body` / `:j2` / `:j4` 多星多时刻 `1 m` 误差门禁。
- **完成**：session-local 后端注册表、稳定规格/发现/构造 API，以及 Lab 配置、执行、缓存和记录的后端中立集成。
- **完成**：Native、Stub、JuliaSpace 共用 `run_experiment(config)`，并通过 GSL、ISL、路由、Traffic AON 与三维 `SubArray` 的调用链级 E2E。
- **完成**：可复现的三后端性能/分配 CSV 基线脚本与 nightly smoke；性能数据暂不作为墙钟 pass/fail 门禁。
- **完成**：Lab provider 抽象、离线 Mock、CLI/OpenAI-compatible 实现及旧名兼容。
- **完成**：独立领域包回归、optional/nightly 本地开关和统一测试入口验证。
- **本地验收**：默认统一入口 `14 passed, 0 failed, 7 skipped`；nightly 后端筛选 `3 passed, 0 failed`；三后端 E2E `71/71`；根回归 `200/200`；`demo()` 全通过。
- **未远程验证**：GitHub Actions YAML 与命令已本地验证，尚无托管 runner 运行证据。
- **后续**：高保真数值参考对标、options schema、TLE/SGP4 配置统一，以及长期性能历史与抗噪阈值。
