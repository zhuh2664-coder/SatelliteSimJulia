# Platform Alpha 实施记录

> 本文件是 `platform/` 的逐步实施证据，不是另一份总路线图。仓库当前全貌以根目录
> [`CURRENT.md`](../CURRENT.md) 为准；每次平台切片的实现、验证与边界在这里追加。

## 2026-07-09 — Step 1：Storage 与本地调度语义

**目标**：在既有 `PlatformRunner` 的 JSON/artifact 契约上增加可替换传输边界，但不引入任何云、
Kubernetes、数据库或凭据依赖。

**实现**：

- 新增 `SatelliteSimPlatformStorage`：`AbstractExperimentStorage`、安全的 object-key 验证、原子写入、
  `LocalFilesystemStorage`、目录上传/物化和 SHA-256 metadata；
- 新增 `SatelliteSimPlatformScheduler`：`AbstractExperimentScheduler`、内存 `FakeScheduler`、作业状态记录、
  `submit!` / `run_next!` / `run_all!`；
- Scheduler 只通过 Storage 读取配置、传递 Runner 的四份产物并逐项校验 artifact index 的 hash；无效配置
  转为 `:failed` job，不将执行异常泄露为调度器崩溃；
- 修复 artifact 契约比较中的 `Set` 差集实现，使 Runner 的 `artifacts.index.json` 只描述其余三份工件，
  而存储 prefix 保留完整四件套。

**验证**：

```text
SatelliteSimPlatformStorage:   13 + 4 tests passed
SatelliteSimPlatformScheduler: 12 + 6 tests passed
```

**边界**：这不是队列、Kubernetes 或云存储实现；未来远程适配器必须实现当前抽象接口，不得让服务端依赖进入
Foundation → Orbit → Link → Net → Metrics/Traffic → Core → Lab 主链。

## 2026-07-09 — Step 2：Constellation Optimization Benchmark v1

**目标**：发布第一个可独立复跑、不会伪造跨机器性能结论的公开优化 benchmark。

**实现**：

- 新增 `platform/benchmarks/constellation-optimization-v1/`；
- 固定 `walker4-raan-coverage-v1`：2 个轨道面 × 每面 2 星、550 km、53°、12 个地面采样点、3 个时间点；
- 使用 `SatelliteSimOpt.coverage_depth_loss` 与三步 `adam-enzyme` RAAN 优化；
- 输入、baseline、绝对容差和最小 `0.1%` loss 改进门槛均纳入版本控制；
- 结果 JSON 包含维度、初始/最终 loss、改进百分比、优化 trace、最终参数、梯度范数和记录型耗时；
- verifier 对结构和数值漂移失败，但明确不把硬件/编译相关 elapsed time 当作 pass/fail 门槛；
- CLI 支持 `--verify` 与 `--output`，测试覆盖独立 JSON 复读、数值漂移及畸形输入拒绝。

**实测基线**：

```text
initial_loss:         -0.03489635925158924
final_loss:           -0.035134686822005705
improvement_percent:   0.6829582670737024
final_parameters_deg: [-0.29999713357478336, 179.7002431177428]
```

**验证**：

```text
SatelliteSimPlatformBenchmarks: 9 + 2 tests passed
```

**边界**：这是小尺寸优化链路的数值契约，不是生产级星座设计推荐、真实性能承诺或真实任务指标。它直接选择
可选 `SatelliteSimOpt` 环境，不由根伞包隐式导出，也不增加主仿真链的 AD/云服务依赖。

## 后续执行规则

下一步若增加远程存储、Job 渲染、身份认证、配额或新的 benchmark，必须在实现后在本文件追加：范围、明确
未做事项、执行命令和实测结果。不得用计划文本替代测试或远程运行证据；不得把生成的 Manifest、运行输出、
artifact 或凭据提交进仓库。

## 2026-07-09 — Step 3：独立复跑与仓库门禁

**执行**：未修改用户现有的 `scripts/test_all.jl`（其中有独立的 backend-integration 未提交工作）；平台切片
保留可单独运行的包测试与 CLI 验证，避免把未审查的工作区改动带入本次提交。

**实测结果**：

```text
SatelliteSimPlatformStorage:       17/17
SatelliteSimPlatformScheduler:     18/18
PlatformRunner:                    21/21
SatelliteSimPlatformBenchmarks:    11/11
Benchmark CLI --verify:            PASS
Dependency boundaries:             PASS
Manifest baseline:                 PASS
Platform Project.toml parse:       4/4 PASS
git diff --check:                  PASS
```

**生成文件控制**：将 `platform/**/Manifest.toml` 统一忽略；此次运行产生的 benchmark 输出仅写入 `/tmp` 并已清理。
平台 README、输入、baseline、源代码、测试与本实施记录是需要版本控制的源文件。
