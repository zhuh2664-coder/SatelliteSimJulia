# CURRENT — 唯一现状入口

> 更新：2026-07-09（分支 `refactor/v2-architecture`）
> 规则：当前事实与“明确不做”只改这一页；`重构计划.md` 是本轮短期验收记录，合并稳定后归档。

## 一句话

仓库已经收敛出一条可重复验证的 LEO 裸数组主链，并把 Traffic/Lab 编排、可选重依赖和轨道后端隔离为显式边界；轨道后端现在已有稳定的发现、配置和选择 API，下一阶段重点是调用链迁移、跨实现数值对标与性能基线。

## 真相文档

| 用途 | 文件 |
|---|---|
| 怎么跑 / 对外说明 | [`README.md`](README.md) |
| 当前事实与优先级 | [`CURRENT.md`](CURRENT.md) |
| AI/协作者约束 | [`AGENTS.md`](AGENTS.md) |
| 本轮短期验收记录 | [`重构计划.md`](重构计划.md) |
| 依赖与后端隔离设计 | [`docs/design/dependency-isolation.md`](docs/design/dependency-isolation.md) |
| 逻辑分层参考 | [`docs/design/LAYERS.md`](docs/design/LAYERS.md) |

其它计划类文档默认是研究材料或归档，不作为完成状态。

## 本轮已完成并有验证证据

### 主链与兼容

- 已建立重构分支与第一安全检查点：`afc4215`。
- Lab Layer 12、LLM provider、tool registry、ledger、team graph、replay/eval 等控制面已恢复；旧 `LLMProvider` 名称继续兼容。
- Traffic AoN 已恢复时间片 GSL 延迟、路由算法和切换策略输入；Traffic 失败不再被完全静默吞掉。
- `clear_hooks!()` 会重置 ledger/schema/guard/permission 注册状态。
- Orbit/Link 裸数组接口已放宽到 `AbstractArray{<:Real,3}` / `AbstractMatrix{<:Real}`，`SubArray`/view 回归已覆盖。
- 根包继续兼容 re-export Core、Net、Traffic、Lab；Opt、Security、Viz、GMAT 不再由根包隐式导出。

### 包边界与环境

- Net、Traffic、Security、Opt 已解除对 `SatelliteSimCore` 的反向依赖。
- Foundation、Orbit、Link、Metrics、Net、Traffic、Core、Lab、Security、Opt、GMAT 与三个 backend path package 均进入依赖边界检查；结果为 `DEPENDENCY BOUNDARIES: PASS`。
- 已建立 `SatelliteSimBackends`、`SatelliteSimStubBackend`、`SatelliteSimJuliaSpaceBackend` 三个 path package。
- 后端统一返回 `(satellite, time, xyz)`、ECEF、km 的 `OrbitResult`；Orbit 提供显式 `propagate_with_backend` / `propagate_to_ecef(backend, ...)` 转回下游裸数组契约，原生传播 API 不变。
- `SatelliteSimBackends` 已提供 `OrbitBackendSpec`、注册/注销、发现和按规格构造 API；注册表是 session-local，具体可选包通过 `__init__()` 注册 `:stub` / `:julia_space`，仍必须由用户显式加载。
- `ExperimentConfig.orbit_backend` 只接受 `nothing`、名称或 `OrbitBackendSpec`，不接受具体后端对象；默认 `nothing` 完全保留原生传播路径。Lab 的单帧、多帧、缓存 hash 和实验记录已经统一纳入后端选择。
- 已建立 `envs/core`、`envs/sim`、`envs/viz`、`envs/gmat`、`envs/security`、`envs/backends-stub`；既有 `envs/opt` 保持独立。
- `envs/core/Manifest.toml` 与 `envs/backends-stub/Manifest.toml` 作为核心可复现基线提交；optional 环境 Manifest 保持本地生成并忽略。
- Manifest 基线实测：root 155、core 139、backends-stub 12，增长门禁 `PASS`。

### 实测结果

| 验证项 | 结果 |
|---|---|
| 统一默认入口 `scripts/test_all.jl` | `14 passed, 0 failed, 5 skipped` |
| 根当前回归 | `200/200` |
| 根包边界契约 | `16/16` |
| Lab | `105/105`，network traffic `10/10` |
| core smoke / bare-array | `3/3`、`7/7` |
| Backends / Stub / Stub env / JuliaSpace | `18/18`、`7/7`、`3/3`、`8/8` |
| Security | `38/38 + 30/30` |
| GMAT | `21/21` |
| Opt / Link / Net / Traffic / Viz | 包内测试或加载门禁通过 |
| `demo()` | 7 个步骤全部通过 |
| GitHub Actions YAML | 三份工作流通过 Ruby YAML 静态解析 |
| Orbit backend 增量回归 | registry/config `13/13`；Orbit dispatch `4/4`；JuliaSpace 二体 ECEF golden vector（`1 m` 容差）通过 |
| optional/nightly 本地开关 | Opt、Security、Viz、GMAT、JuliaSpace 均通过 |

本次 backend 增量后，默认统一入口已重跑为 `14 passed, 0 failed, 5 skipped`；Opt、Security、JuliaSpace 的筛选入口为 `3 passed, 0 failed`。Lab、根回归、Orbit、Link、Net、Traffic、后端包、依赖边界、Manifest 基线、core smoke 与 bare-array 均在当前本地环境通过。

## CI 分层

- Core：boundary、core smoke、bare-array、Lab、Stub backend。
- Optional：Opt、Security、Viz、GMAT。
- Nightly：根当前回归、JuliaSpace backend。
- 三份工作流已完成本地命令验证和 YAML 静态解析；**尚未在 GitHub 托管 runner 上实际执行**。

## 下一阶段缺口

1. Orbit 只迁移了一个显式 dispatch 入口，尚未让 Link/frames 与所有 Orbit 调用点经由 backend dispatch。
2. JuliaSpace 已有二体 ECEF golden vector（`1 m` 容差），但仍缺跨实现对标、其它传播器误差阈值和性能基线。
3. 远程 GitHub Actions runner 尚未产生实际运行证据。
4. 根 Manifest 仍设计为不提交；增长门禁只对当前存在或已提交的环境 Manifest 生效。

## 下一阶段优先级

1. 扩展 golden vectors 到跨实现/多传播器，并为耗时建立可复现性能基线。
2. 按调用链逐步迁移 Orbit/frames/Link，而不是把可选后端回灌进主链。
3. 为 backend options 增加更明确的 schema/冲突校验，避免原生 `propagator` 与后端专属选项产生歧义。
4. 在远程 runner 验证 Core/Optional/Nightly，并记录平台特有失败而不是修改业务逻辑迎合环境。
5. 本轮分支合并稳定后，将 `重构计划.md` 迁入归档，避免继续生长为长期总规划。

## 明确不做

- 不在本轮重写论文、文献库、Godot/Unity 或平台实验资产。
- 不把 Opt、Security、Viz、GMAT 或具体外部轨道库塞回日常根环境。
- 不在本轮处理 PAT；不读取、输出或记录任何远程凭据。
- 不做 hard reset、clean、stash 删除或未经要求的 push/fetch。
- `docs/STATUS.md` 是冻结的 Godot 客户端状态，不代表仿真主链状态。
