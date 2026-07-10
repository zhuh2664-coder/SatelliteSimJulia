# PlatformRunner — 本地可复现实验 Runner

`PlatformRunner` 是云平台的第一个可执行垂直切片。它严格校验
`platform/schemas/experiment-v1.schema.json` 所定义的 JSON 配置，调用
`SatelliteSimLab`，并生成平台兼容的可复现工件：

- `config.snapshot.json`
- `result.json`
- `run_metadata.json`
- `artifacts.index.json`

本地运行：

```bash
julia --project=platform/runner -e 'using Pkg; Pkg.instantiate()'
julia --project=platform/runner platform/runner/bin/satnet-run.jl \
  --config path/to/experiment.json --output-dir /tmp/satnet-result
```

该 runner 不执行用户提供的 Julia 代码，也不访问网络。对象存储、鉴权和
Kubernetes Job 调度将在后续的 Storage、API 和 Scheduler 模块中传输相同的
配置与工件，不改变 schema 或 artifact 契约。
