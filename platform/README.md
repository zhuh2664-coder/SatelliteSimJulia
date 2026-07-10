# SatelliteSimJulia Platform Alpha

> **当前状态（2026-07-09）：仅实现本地可复现实验 Runner。**
> 本目录不是已上线的公共云服务；PostgreSQL、对象存储、认证、配额、HTTP API 和
> Kubernetes 调度均尚未实现，也不得据此宣称可公开注册或可云端提交任务。

Platform Alpha 为后续面向研究团队的 API/CLI-first 仿真平台定义一个小而可验证的
起点：**严格校验的实验配置 + 本地执行 + 可复现结果工件**。远程服务以后只能传输
相同的 schema 和 artifact 契约，而不能改变实验语义。

## 已实现

```text
platform/
├── schemas/experiment-v1.schema.json   # versioned public JSON contract
├── examples/walker8-local-v1.json      # source-controlled smoke example
└── runner/                              # local Julia package and CLI
    ├── src/PlatformRunner.jl
    ├── bin/satnet-run.jl
    └── test/runtests.jl
```

`PlatformRunner`：

- 只接受 `satellitesim.experiment/v1` JSON，拒绝未知字段和任何原始 Julia 代码；
- 将合法配置映射为 `SatelliteSimLab.ExperimentConfig`，不让具体后端对象穿过公共配置；
- 生成确定的配置快照与带 SHA-256 的结果索引；
- 输出目录默认必须为空，避免意外覆盖已有实验结果；
- 不访问网络、不读取云凭据、不包含鉴权或存储实现。

## 本地 CLI

```bash
julia --project=platform/runner -e 'using Pkg; Pkg.instantiate()'

julia --project=platform/runner platform/runner/bin/satnet-run.jl \
  --config platform/examples/walker8-local-v1.json \
  --output-dir /tmp/satnet-walker8
```

成功时标准输出为：

```json
{"output_dir":"/tmp/satnet-walker8","status":"succeeded"}
```

Runner 退出码：`0` 成功；`1` 配置不合法；`2` 执行或文件系统错误。

## 配置与工件契约

Schema 位于 [`schemas/experiment-v1.schema.json`](schemas/experiment-v1.schema.json)。关键字段：

| 字段 | 说明 |
|---|---|
| `schema_version` | 固定为 `satellitesim.experiment/v1` |
| `name` | 1–128 字节实验名称 |
| `constellation` | catalog 名称，或 `{T,P,F,alt_km,inc_deg}` Walker 参数 |
| `propagator` | `two_body`、`j2` 或 `j4`；默认为 `j2` |
| `orbit_backend` | 可选后端名称或 `{name, options}`；具体 adapter 必须在执行环境显式加载 |
| `tspan` / `steps` | 仿真起止秒数与时间步数 |
| `topology_strategy` / `routing_algorithm` / `traffic` | 已受限的主链策略选择 |
| `ground_pairs` / `random_seed` / `alpha` | 实验输入与可复现控制参数 |

每次成功运行在输出目录写入：

```text
config.snapshot.json  # runner 实际消费的归一化配置
result.json           # ExperimentResult 摘要
run_metadata.json     # 时间、Julia/Lab 版本、环境和输入 hash、seed、backend
artifacts.index.json  # 前三项的名称、字节数、SHA-256
```

`config.snapshot.json` 的 SHA-256 记录在 `run_metadata.json` 中；各结果文件的
SHA-256 记录在 `artifacts.index.json` 中。结果目录是可传输边界：未来对象存储、作业
调度和下载 API 应原样保存这些文件。

## 验证

```bash
JULIA_DEPOT_PATH=/tmp/satellitesim-julia-depot:$HOME/.julia \
  julia --project=platform/runner -e 'using Pkg; Pkg.test(; coverage=false)'
```

还应运行仓库的边界与 Manifest 门禁：

```bash
julia scripts/check_dependency_boundaries.jl
julia scripts/check_manifest_baseline.jl
```

## 后续边界（尚未实施）

1. 在同一 schema/artifact 契约之上实现存储接口（本地实现与 S3/MinIO 实现）。
2. 实现排队和 Kubernetes Job 渲染/调度；先有可测试的渲染与本地 fake，再连真实集群。
3. 提供 API/CLI 的 `validate`、`submit`、`status`、`download`、`reproduce`；公开访问应使用 OIDC 兼容认证与服务端配额，不采用明文 token 设计。
4. 发布星座优化与可微仿真的可复现实验基准：版本化输入、公开 baseline、数值/性能阈值和独立复跑记录。

实施状态以仓库根目录的 [`CURRENT.md`](../CURRENT.md) 为准。
