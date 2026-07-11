# CURRENT — 唯一现状入口

> 更新：2026-07-09（分支 `refactor/v2-architecture`）
> 规则：当前事实与“明确不做”只改这一页；`重构计划.md` 是本轮短期验收记录，合并稳定后归档。

## 一句话

仓库已经收敛出一条可重复验证的 LEO 裸数组主链，并把 Traffic/Lab 编排、可选重依赖和轨道后端隔离为显式边界；下一阶段不再继续拆包，而是把 Orbit 主链逐步接到稳定后端契约并建立数值对标。

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
- Foundation、Orbit、Link、Metrics、Net、Traffic、Core、Lab、Security、Opt、GMAT 均进入依赖边界检查；结果为 `DEPENDENCY BOUNDARIES: PASS`。
- 已建立 `SatelliteSimBackends`、`SatelliteSimStubBackend`、`SatelliteSimJuliaSpaceBackend` 三个 path package。
- 后端统一返回 `(satellite, time, xyz)`、ECEF、km 的 `OrbitResult`。
- 已建立 `envs/core`、`envs/sim`、`envs/viz`、`envs/gmat`、`envs/security`、`envs/backends-stub`；既有 `envs/opt` 保持独立。
- `envs/core/Manifest.toml` 与 `envs/backends-stub/Manifest.toml` 作为核心可复现基线提交；optional 环境 Manifest 保持本地生成并忽略。
- Manifest 基线实测：root 154、core 138、backends-stub 12，增长门禁 `PASS`。

### 实测结果

| 验证项 | 结果 |
|---|---|
| 统一默认入口 `scripts/test_all.jl` | `14 passed, 0 failed, 5 skipped` |
| 根当前回归 | `200/200` |
| 根包边界契约 | `16/16` |
| Lab | `97/97`，network traffic `10/10` |
| core smoke / bare-array | `3/3`、`7/7` |
| Backends / Stub / Stub env / JuliaSpace | `5/5`、`4/4`、`3/3`、`2/2` |
| Security | `38/38 + 30/30` |
| GMAT | `21/21` |
| Opt / Link / Net / Traffic / Viz | 包内测试或加载门禁通过 |
| `demo()` | 7 个步骤全部通过 |
| GitHub Actions YAML | 三份工作流通过 Ruby YAML 静态解析 |
| optional/nightly 本地开关 | Opt、Security、Viz、GMAT、JuliaSpace 均通过 |

## CI 分层

- Core：boundary、core smoke、bare-array、Lab、Stub backend。
- Optional：Opt、Security、Viz、GMAT。
- Nightly：根当前回归、JuliaSpace backend。
- 三份工作流已完成本地命令验证和 YAML 静态解析；**尚未在 GitHub 托管 runner 上实际执行**。

## 下一阶段缺口

1. Orbit 主链尚未全面通过 `SatelliteSimBackends` dispatch；当前完成的是稳定契约和两个实现。
2. JuliaSpace backend 尚无跨实现 golden vectors、误差阈值和性能基线。
3. 后端发现、配置和选择尚无稳定的用户 API。
4. 远程 GitHub Actions runner 尚未产生实际运行证据。
5. 根 Manifest 仍设计为不提交；增长门禁只对当前存在或已提交的环境 Manifest生效。

## 下一阶段优先级

1. 先定义 golden vectors 和允许误差，再迁移一个最小 Orbit 调用点到 backend dispatch。
2. 增加明确的 backend 配置/选择 API，不让具体后端类型泄漏到高层实验配置。
3. 在远程 runner 验证 Core/Optional/Nightly，并记录平台特有失败而不是修改业务逻辑迎合环境。
4. 本轮分支合并稳定后，将 `重构计划.md` 迁入归档，避免继续生长为长期总规划。

## 明确不做

- 不在本轮重写论文、文献库、Godot/Unity 或平台实验资产。
- 不把 Opt、Security、Viz、GMAT 或具体外部轨道库塞回日常根环境。
- 不在本轮处理 PAT；不读取、输出或记录任何远程凭据。
- 不做 hard reset、clean、stash 删除或未经要求的 push/fetch。
- `docs/STATUS.md` 是冻结的 Godot 客户端状态，不代表仿真主链状态。
