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

## 2026-07-09 — Step 4：根现状同步

**执行**：将本切片的已完成能力、实测结果与下一阶段边界同步到根 `CURRENT.md`：不再将 Platform Alpha
描述为“只有 Runner”，但仍明确其缺少远程存储、Kubernetes、OIDC、配额、数据库元数据和公开服务。

**工作区保护**：`CURRENT.md` 同时存在独立的 backend-integration 更新；本次只暂存平台相关的四个文档 hunk，
其余 hunk 继续留在工作区，未被覆盖或提交。

## 2026-07-09 — Step 5：受限 Kubernetes Job 契约

**目标**：为远程执行准备可独立测试的 Job 渲染/客户端边界，同时避免 Kubernetes SDK、集群凭据或任意 PodSpec
进入 Runner、Storage、Scheduler 或仿真主链。

**实现**：

- 新增 `platform/kubernetes/`（`SatelliteSimPlatformKubernetes`）；
- `KubernetesJobSpec` 只接受明确的 image、namespace、service account、Storage config key、artifact prefix、
  CPU/memory、TTL/backoff，以及有限白名单 metadata；image 必须有明确 tag 或 sha256 digest，拒绝 `:latest` 和
  namespace 的 `default` service account；
- `render_job` 确定性生成 `batch/v1 Job`，固定 `restartPolicy=Never`、resource requests/limits、非 root、只读根、
  `allowPrivilegeEscalation=false`、`seccomp=RuntimeDefault`、drop ALL capabilities 和禁用 service-account token 自动挂载；
- 不提供外部 PodSpec/volume/host network/privileged/command/args/任意 env 注入口；只传入受控的 job/config/output
  三个环境变量；
- 提供 `AbstractKubernetesJobClient` 与离线 `FakeKubernetesJobClient`，覆盖 submit/status/cancel 生命周期。

**验证**：

```text
SatelliteSimPlatformKubernetes: 36/36
```

**边界与未做事项**：这只是 manifest 与 client adapter contract；没有 Kubernetes SDK、HTTP 调用、cluster credential、
RBAC、NetworkPolicy、admission webhook 或真实集群运行证据。生产 client 必须在本边界之外处理 TLS、身份、endpoint
和审计，且不得把这些依赖倒灌回仿真包。

## 2026-07-09 — Step 6：身份/配额提交控制面（本地契约）

**目标**：把认证、租户隔离、幂等、quota reservation 与受限 Kubernetes 提交组合为可测的 edge control-plane，
但不把本地 fake 误表述成生产认证或分布式配额系统。

**实现**：

- 新增 `platform/control/`（`SatelliteSimPlatformControl`）；
- `AbstractIdentityVerifier` 与 `AuthenticatedPrincipal` 明确 tenant、subject、role；`StaticIdentityVerifier` 仅在
  本地测试使用，存储的是本地 identity reference，不读取/持久化 API key，也不伪造 OIDC claim parser；
- `AbstractQuotaStore` 与 `InMemoryQuotaStore` 按 tenant 预留 concurrent jobs、CPU millicores、memory MiB、daily jobs 和
  声明 artifact bytes；相同 `(tenant, idempotency_key)` 只能重放资源一致的 reservation；
- `PlatformControlPlane` 在写入 storage / 调用 Kubernetes 前先验证 Runner schema 并预留 quota；object key 和 output
  prefix 固定在 `tenants/<tenant>/...`；Kubernetes job identity 含 tenant 前缀，避免相同用户 job id 的跨租户碰撞；
- K8s terminal/cancel 状态经 `sync_submission!` / `cancel_submission!` 释放 reservation；提交错误也会进行补偿释放。

**验证**：

```text
SatelliteSimPlatformControl: 43/43
```

测试同时覆盖了无权限拒绝、同租户 quota 拒绝、不同 tenant 不互相消耗 quota、幂等重放、不同 payload 重用 idempotency
key 的拒绝、tenant object namespace、受控 Job env，以及 terminal/cancel 后释放 reservation。

**边界与未做事项**：`StaticIdentityVerifier`、`InMemoryQuotaStore` 和 fake Kubernetes client 只用于单进程离线测试；
没有 HTTP/gRPC API、OIDC/JWKS 验签、数据库、分布式原子 lease、计量结算、不可变审计、S3/MinIO 或真实 Kubernetes
client/cluster。生产多副本控制面必须替换这些 adapter，并在真实集群上产生独立验收证据。

## 2026-07-09 — Step 7：将 Platform 包纳入依赖边界门禁

**目标**：让平台 edge packages 与主仿真包使用同一套显式本地依赖/source 检查，防止未来控制面反向把云/服务
依赖带回模拟主链，或让 platform 包之间形成未声明的路径依赖。

**实现**：扩展 `scripts/check_dependency_boundaries.jl`，将 `PlatformRunner`、Storage、Scheduler、Kubernetes、
Control 和 Benchmark 作为本地包登记，定义允许依赖方向：

```text
PlatformRunner → SatelliteSimBackends / SatelliteSimLab
PlatformScheduler → PlatformRunner / PlatformStorage
PlatformControl → PlatformRunner / PlatformStorage / PlatformKubernetes
PlatformKubernetes / PlatformStorage → ∅
PlatformBenchmarks → SatelliteSimOpt
```

每个 local dependency 继续必须有对应 `[sources]` 条目；因此新增控制面不会逃逸现有 package-boundary gate。

**验证**：

```text
julia scripts/check_dependency_boundaries.jl
DEPENDENCY BOUNDARIES: PASS
```
