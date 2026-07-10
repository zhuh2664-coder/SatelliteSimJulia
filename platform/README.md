# SatelliteSimJulia Platform Alpha

> **当前状态（2026-07-09）：已实现本地 Runner、可替换的本地对象存储、内存 fake
> scheduler 和第一个可复现优化 benchmark。**
>
> 这仍然**不是**已上线的公共云服务：没有 PostgreSQL、S3/MinIO、HTTP API、OIDC、配额、
> Kubernetes 控制器或公开注册入口。任何未来远程服务只能运输既有的 schema、作业和 artifact
> 契约，不能改写仿真语义，也不能把云依赖回灌进主仿真链。

Platform Alpha 为未来面向研究团队的 API/CLI-first 仿真平台定义可在本地独立验证的最小垂直切片：

```text
严格 JSON 配置 → 本地运行 → SHA-256 artifact → Storage 接口 → Fake Scheduler
                                     ↘ 固定优化基准 + source-controlled baseline
```

## 已实现的组件

```text
platform/
├── schemas/experiment-v1.schema.json                 # versioned public JSON contract
├── examples/walker8-local-v1.json                    # source-controlled runner example
├── runner/                                            # local execution + artifact producer
├── storage/                                           # AbstractExperimentStorage + local filesystem adapter
├── scheduler/                                         # AbstractExperimentScheduler + local fake implementation
└── benchmarks/constellation-optimization-v1/          # fixed scenario + baseline + verifier
```

### Runner：受限配置与可复现工件

`PlatformRunner` 只接受 `satellitesim.experiment/v1` JSON，拒绝未知字段和原始 Julia 代码；它将合法配置映射为
`SatelliteSimLab.ExperimentConfig`，不让后端对象越过公共配置边界。每次成功运行写入：

```text
config.snapshot.json  # runner 实际消费的归一化配置
result.json           # ExperimentResult 摘要
run_metadata.json     # Julia/Lab/环境 hash、seed、backend、输入 hash
artifacts.index.json  # 前三项的名称、字节数、SHA-256
```

输出目录默认必须为空，避免意外覆盖；Runner 不访问网络、不读取云凭据、不包含鉴权逻辑。

### Storage：可替换而不绑定云厂商

`SatelliteSimPlatformStorage` 提供对象键接口：

```julia
AbstractExperimentStorage
put_bytes! / put_json! / get_bytes / get_json
has_object / object_metadata / list_objects
upload_directory! / materialize_prefix!
```

当前 `LocalFilesystemStorage(root)` 是离线开发适配器。键严格拒绝绝对路径、`..`、空 segment、反斜杠和 NUL；写入
通过临时文件与原子移动完成。未来 S3/MinIO 等适配器应实现同一接口，而非侵入 Runner 或仿真包。

### Scheduler：可测试的本地作业语义

`SatelliteSimPlatformScheduler` 提供：

```julia
AbstractExperimentScheduler
submit! / run_next! / run_all! / get_job / list_jobs
```

`FakeScheduler` 把配置和产物仅通过 Storage 接口传递：排队作业在临时目录调用 Runner，上传四个工件，逐个校验
`artifacts.index.json` 中的 SHA-256，再把作业标记为 `:succeeded` 或 `:failed`。它没有 Kubernetes、消息队列、数据库
或网络依赖；因此是未来 Job renderer / queue adapter 的行为参考，而不是云调度的伪宣称。

### Benchmark：公开、固定、可独立复跑

[`benchmarks/constellation-optimization-v1`](benchmarks/constellation-optimization-v1/) 定义
`satellitesim.constellation-optimization/v1`：固定 4 星 Walker（2×2）RAAN 覆盖优化、三次 Adam/Enzyme
更新、source-controlled JSON 输入、数值 baseline 和绝对容差。结果以 JSON 输出；结构、损失下降、参数和优化 trace
均独立验证。耗时只记录、不作为跨机器 pass/fail 阈值。

详见该目录的 README 与 [`IMPLEMENTATION_LOG.md`](IMPLEMENTATION_LOG.md)。

## 本地运行

### Runner CLI

```bash
julia --project=platform/runner -e 'using Pkg; Pkg.instantiate()'

julia --project=platform/runner platform/runner/bin/satnet-run.jl \
  --config platform/examples/walker8-local-v1.json \
  --output-dir /tmp/satnet-walker8
```

成功时输出：

```json
{"output_dir":"/tmp/satnet-walker8","status":"succeeded"}
```

Runner 退出码：`0` 成功；`1` 配置不合法；`2` 执行或文件系统错误。

### Benchmark CLI

```bash
julia --project=platform/benchmarks/constellation-optimization-v1 \
  platform/benchmarks/constellation-optimization-v1/bin/run.jl \
  --verify --output /tmp/satellitesim-constellation-benchmark-v1.json
```

## 验证

```bash
julia --project=platform/runner -e 'using Pkg; Pkg.test(; coverage=false)'
julia --project=platform/storage -e 'using Pkg; Pkg.test(; coverage=false)'
julia --project=platform/scheduler -e 'using Pkg; Pkg.test(; coverage=false)'
julia --project=platform/benchmarks/constellation-optimization-v1 -e 'using Pkg; Pkg.test(; coverage=false)'

julia scripts/check_dependency_boundaries.jl
julia scripts/check_manifest_baseline.jl
```

包内和 Platform 目录的生成 `Manifest.toml`、运行输出和临时 artifact 都不提交。平台执行过程记录位于
[`IMPLEMENTATION_LOG.md`](IMPLEMENTATION_LOG.md)；仓库总体现状仍以根目录的 [`CURRENT.md`](../CURRENT.md) 为准。

## 明确尚未实施

1. 存储适配器：S3/MinIO、保留策略、跨区域复制、数据库元数据索引。
2. 远程调度：队列、Kubernetes Job renderer/controller、取消/重试/幂等语义和资源隔离。
3. 面向公众的服务：`validate` / `submit` / `status` / `download` / `reproduce` HTTP API、OIDC、组织与配额。
4. Benchmark 规模化：多情景、独立参考物理实现、黄金数据、性能历史与抗噪回归判定。

在这些能力及远程运行证据出现前，不得将 Platform Alpha 描述为可公开注册、云端提交任务或生产级多租户系统。
