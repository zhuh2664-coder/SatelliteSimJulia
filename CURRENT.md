# CURRENT — 唯一现状入口

> 更新：2026-07-09（分支 `refactor/v2-architecture`）
> 规则：当前事实与“明确不做”只改这一页；`重构计划.md` 是本轮短期验收记录，合并稳定后归档。

## 一句话

仓库已经收敛出一条可重复验证的 LEO 裸数组主链，并把 Traffic/Lab 编排、可选重依赖和轨道后端隔离为显式边界；Native、Stub、JuliaSpace 已能经过同一高层实验入口并直接进入 GSL/ISL/路由/Traffic，JuliaSpace 的独立长期项实现也已完成跨实现对标；下一阶段重点是高保真数值参考、后端 options schema 与长期性能回归。

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
- Orbit/Link/Lab/Traffic bridge 的位置入口已放宽到 `AbstractArray{<:Real,3}` / `AbstractMatrix{<:Real}`；Native、Stub、JuliaSpace 的三维 `SubArray` 已端到端穿过 GSL、ISL、路由和 Traffic，并与 `Array` 结果一致。
- 根包继续兼容 re-export Core、Net、Traffic、Lab；Opt、Security、Viz、GMAT 不再由根包隐式导出。

### 包边界与环境

- Net、Traffic、Security、Opt 已解除对 `SatelliteSimCore` 的反向依赖。
- Foundation、Orbit、Link、Metrics、Net、Traffic、Core、Lab、Security、Opt、GMAT 与三个 backend path package 均进入依赖边界检查；结果为 `DEPENDENCY BOUNDARIES: PASS`。
- 已建立 `SatelliteSimBackends`、`SatelliteSimStubBackend`、`SatelliteSimJuliaSpaceBackend` 三个 path package；JuliaSpace 运行时只依赖后端契约与 SatelliteToolbox 坐标变换，不依赖 `SatelliteSimOrbit`。
- 后端统一返回 `(satellite, time, xyz)`、ECEF、km 的 `OrbitResult`；Orbit 提供显式 `propagate_with_backend` / `propagate_to_ecef(backend, ...)` 转回下游裸数组契约，原生传播 API 不变。
- `SatelliteSimBackends` 已提供 `OrbitBackendSpec`、注册/注销、发现和按规格构造 API；注册表是 session-local，具体可选包通过 `__init__()` 注册 `:stub` / `:julia_space`，仍必须由用户显式加载。
- `ExperimentConfig.orbit_backend` 只接受 `nothing`、名称或 `OrbitBackendSpec`，不接受具体后端对象；默认 `nothing` 完全保留原生传播路径。Lab 的单帧、多帧、缓存 hash 和实验记录已经统一纳入后端选择；Native、Stub、JuliaSpace 均由同一 `run_experiment(config)` 集成测试覆盖。
- Platform Alpha 已有本地 `PlatformRunner`、`LocalFilesystemStorage`、`FakeScheduler`、固定优化 benchmark、受限 Kubernetes Job renderer/fake client，以及本地 identity + quota 提交控制面；它仍没有公共 API、真实 OIDC/JWKS、分布式 quota lease、S3/MinIO、真实 Kubernetes client/集群或数据库元数据。
- 已建立 `envs/core`、`envs/sim`、`envs/viz`、`envs/gmat`、`envs/security`、`envs/backends-stub`、`envs/backends-integration`；既有 `envs/opt` 保持独立。
- `envs/core/Manifest.toml` 与 `envs/backends-stub/Manifest.toml` 作为核心可复现基线提交；optional 环境 Manifest 保持本地生成并忽略。
- Manifest 基线实测：root 155、core 139、backends-stub 12，增长门禁 `PASS`。

### 实测结果

| 验证项 | 结果 |
|---|---|
| 统一默认入口 `scripts/test_all.jl` | `14 passed, 0 failed, 7 skipped` |
| 根当前回归 | `200/200` |
| 根包边界契约 | `16/16` |
| Lab | `105/105`，network traffic `10/10` |
| core smoke / bare-array | `3/3`、`7/7` |
| Backends / Stub / Stub env / JuliaSpace | `18/18`、`7/7`、`3/3`、`22/22` |
| Security | `38/38 + 30/30` |
| GMAT | `21/21` |
| Opt / Link / Net / Traffic / Viz | 包内测试或加载门禁通过 |
| `demo()` | 7 个步骤全部通过 |
| GitHub Actions YAML | 三份工作流通过 Ruby YAML 静态解析 |
| Orbit backend 增量回归 | registry/config `13/13`；Orbit dispatch `4/4`；JuliaSpace 二体 ECEF golden vector（`1 m` 容差）通过 |
| 三后端高层 E2E | `71/71`：同一 `run_experiment` + GSL/ISL/路由/Traffic + Array/SubArray |
| JuliaSpace 跨实现误差 | 包内独立长期项实现；`:two_body` / `:j2` / `:j4` 在 12 星、4 时刻（最长 600 s）下最大误差 `5.46e-12 km`，门限 `1 m` |
| backend 性能基线 smoke | Native / Stub / JuliaSpace 输出 shape、elapsed、allocations CSV 通过 |
| optional/nightly 本地开关 | Opt、Security、Viz、GMAT、JuliaSpace 均通过 |
| PlatformRunner | package contract `21/21`，CLI artifact smoke 通过 |
| Platform Alpha local contracts | Storage `17/17`；FakeScheduler `18/18`；Constellation Optimization v1 `11/11`；Kubernetes renderer/fake client `36/36`；Control Plane `43/43`；benchmark CLI `--verify` 通过 |

本次 backend E2E 增量后，默认统一入口已重跑为 `14 passed, 0 failed, 7 skipped`；JuliaSpace、三后端 E2E、性能 baseline 的 nightly 筛选入口为 `3 passed, 0 failed`。集成测试为 `71/71`，Lab 为 `105/105 + 10/10`，Traffic 为 `22/22`，JuliaSpace 为 `22/22`；依赖边界、Manifest 基线、core smoke 与 bare-array 均在当前本地环境通过。

## CI 分层

- Core：boundary、core smoke、bare-array、Lab、Stub backend。
- Optional：Opt、Security、Viz、GMAT。
- Nightly：根当前回归、JuliaSpace backend、三后端高层 E2E、性能基线 smoke。
- 三份工作流已完成本地命令验证和 YAML 静态解析；**尚未在 GitHub 托管 runner 上实际执行**。

## 下一阶段缺口

1. Platform Alpha 已补本地的受限 Job renderer/fake client 与 identity/quota 控制面契约；S3/MinIO、提交 HTTP API、真实 OIDC/JWKS、分布式 quota lease、真实 Kubernetes client/集群、数据库元数据和公开注册仍未实现。
2. JuliaSpace 与 Native 已是两条独立代码路径，但使用同一组 EGM2008 常数、同一类长期项解析模型，并共享 SatelliteToolbox TEME→PEF 坐标变换；现有误差证据不是相对高保真数值力模型的精度认证。
3. 性能脚本已能记录 elapsed/allocations，但尚未积累跨提交历史、噪声模型或稳定的回归阈值。
4. backend options 尚无统一 schema、冲突校验与跨版本迁移策略；TLE/SGP4 等专用传播入口也未统一到注册表配置。
5. 远程 GitHub Actions runner 尚未产生实际运行证据。
6. 根 Manifest 仍设计为不提交；增长门禁只对当前存在或已提交的环境 Manifest 生效。

## 下一阶段优先级

1. 在既有 PlatformRunner/Storage/FakeScheduler/artifact、Job renderer 与本地 control-plane 契约上补真实 remote adapter：先做 OIDC/JWKS、持久化/分布式 quota lease、Kubernetes RBAC/NetworkPolicy 与单区域集群验收，始终不把云依赖引回仿真主链。
2. 扩展已发布的 constellation-optimization/v1：多场景、独立参考实现、golden vectors、数值误差预算及跨提交性能历史；在有抗噪证据前不设硬时间门禁。
3. 接入独立的高保真数值参考传播实现，复用现有 E2E/误差 harness，建立相对真值的物理误差预算。
4. 为 backend options 增加 schema、冲突校验和版本迁移；专用 Orbit 入口保持在 Orbit 边界，不把具体后端回灌到 Link/Net/Traffic。
5. 为性能 CSV 建立跨提交存档和抗噪回归判定，再决定是否成为强制门禁。
6. 在远程 runner 验证 Core/Optional/Nightly，并记录平台特有失败而不是修改业务逻辑迎合环境。
7. 本轮分支合并稳定后，将 `重构计划.md` 迁入归档，避免继续生长为长期总规划。

## 明确不做

- 不在本轮重写论文、文献库、Godot/Unity 或平台实验资产。
- 不把 Opt、Security、Viz、GMAT 或具体外部轨道库塞回日常根环境。
- 不在本轮处理 PAT；不读取、输出或记录任何远程凭据。
- 不做 hard reset、clean、stash 删除或未经要求的 push/fetch。
- `docs/STATUS.md` 是冻结的 Godot 客户端状态，不代表仿真主链状态。
