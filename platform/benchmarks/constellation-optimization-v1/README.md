# Constellation Optimization Benchmark v1

`satellitesim.constellation-optimization/v1` 是平台的第一个可复现数值基准。它固定了一个
4 星 Walker 星座（2 个轨道面 × 每面 2 星）的 RAAN 覆盖优化问题，以小尺寸、可在开发机上
复跑的输入验证优化链路，而不是宣称代表生产规模或真实任务级收敛质量。

## 受版本控制的契约

- `scenarios/walker4-raan-coverage-v1.json`：唯一的固定输入；
- `baselines/walker4-raan-coverage-v1.json`：参考数值、绝对容差及最小改进门槛；
- `src/SatelliteSimPlatformBenchmarks.jl`：严格读取、运行、验证和 JSON 输出；
- `test/runtests.jl`：独立复跑并检查结构、数值和失败语义。

优化目标为 `SatelliteSimOpt.coverage_depth_loss`，优化变量是两个轨道面的 RAAN。运行结果同时
保存初始/最终损失、三步优化 trace、最终参数、模型尺寸及耗时。耗时只作观测，**不**作为跨机器
的通过门槛；数值结果才与 source-controlled baseline 比较。

## 运行

```bash
julia --project=platform/benchmarks/constellation-optimization-v1 -e 'using Pkg; Pkg.instantiate()'

julia --project=platform/benchmarks/constellation-optimization-v1 \
  platform/benchmarks/constellation-optimization-v1/bin/run.jl \
  --verify --output /tmp/satellitesim-constellation-benchmark-v1.json
```

`--verify` 以独立加载的 baseline 验证输出；数值偏离、结构缺失或没有达到最小改进阈值时退出非零。
不提交 `/tmp` 中的运行输出或此目录生成的 `Manifest.toml`。

## 边界

此基准直接选择 `SatelliteSimOpt` 这个可选研究环境。它不被根伞包 re-export，也不向
Foundation / Orbit / Link / Net / Traffic 主仿真链引入 Enzyme、云服务、Kubernetes、认证或配额依赖。
生产平台未来可以调度这个契约，但不得把调度细节倒灌进优化模型或主仿真包。
