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

## 依赖方向

```text
Foundation → Orbit → Link → Net → Traffic
     └──────────────→ Metrics
Foundation/Orbit/Link/Metrics → Core
主链领域包 → Lab（编排与 AI 控制面）

SatelliteSimBackends ← StubBackend
SatelliteSimBackends + Orbit ← JuliaSpaceBackend

Opt / Security / Viz / GMAT：显式选择，不由根伞包隐式导出
```

硬约束：

1. `Net`、`Traffic`、`Security`、`Opt` 不依赖 `SatelliteSimCore`。
2. 本地包依赖必须有 `[sources]`。
3. 主链位置数组接受 `AbstractArray{<:Real,3}`，形状为 `(satellite,time,xyz)`。
4. 外部轨道后端返回 ECEF km，并通过 `validate_orbit_result`。
5. Stub 后端必须确定性、无重依赖，可在无网络服务的 CI 中运行。

## 后端契约当前范围

已实现：

- `AbstractOrbitBackend`
- `OrbitResult`
- `backend_name` / `backend_capabilities`
- `propagate_orbit`
- `validate_orbit_result`
- 确定性 `StubOrbitBackend`
- 现有 `SatelliteSimOrbit.propagate_to_ecef` 的 `JuliaSpaceOrbitBackend` 适配

尚未实现：

- Orbit/Link/frames 主链所有调用点通过 backend dispatch。
- 跨后端 golden vectors、误差阈值和性能基线。
- 后端发现/配置的稳定用户 API。

## CI 分层

| 层 | 工作流 | 内容 |
|---|---|---|
| Core | `.github/workflows/test.yml` | boundary、core smoke、bare-array、Lab、Stub backend |
| Optional | `.github/workflows/optional.yml` | Opt、Security、Viz、GMAT |
| Nightly | `.github/workflows/nightly.yml` | 根当前回归、JuliaSpace adapter |

本地门禁：

```bash
julia scripts/check_dependency_boundaries.jl
julia scripts/check_manifest_baseline.jl
julia --project=envs/core test/runtests_core_smoke.jl
julia --project=envs/core test/test_bare_array_contract.jl
julia --project=envs/backends-stub test/backends/test_stub_backend_pkg.jl
```

Manifest 检查对不存在的文件输出 `SKIP`；在核心 CI 中，`envs/core` 与 `envs/backends-stub` 会先 instantiate，因此这两个基线有实际约束。根 Manifest 不提交，只在本地存在时报告。

## 实施状态

- **完成**：领域包去 Core 反向依赖、`[sources]`、边界脚本。
- **完成**：core/stub 环境 Manifest 与 +20% 增长门禁。
- **完成**：bare-array/SubArray 契约修复与测试。
- **完成**：后端接口包、Stub、JuliaSpace adapter 的初始包级测试。
- **完成**：Lab provider 抽象、离线 Mock、CLI/OpenAI-compatible 实现及旧名兼容。
- **完成**：独立领域包回归、optional/nightly 本地开关和统一测试入口验证。
- **本地验收**：默认统一入口 `14 passed, 0 failed, 5 skipped`；根回归 `200/200`；`demo()` 全通过。
- **未远程验证**：GitHub Actions YAML 与命令已本地验证，尚无托管 runner 运行证据。
- **后续**：主链 backend migration、golden vectors、性能/精度基线。
