# SatelliteSimJulia 全项目 Debug / Review 记录

> 日期：2026-07-09
> 分支：`refactor/v2-architecture`
> 范围：依赖边界、主链数组契约、各包测试、可选环境、轨道后端集成、静态代码审查。
> 说明：本文是本次 Debug 的逐步证据记录，不是新的项目路线图；当前项目状态仍以 `CURRENT.md` 为准。

## 步骤 1：确认协作约束与工作区状态

执行内容：

- 阅读 `AGENTS.md`、`CURRENT.md`、`README.md`。
- 确认当前主线为 `Foundation → Orbit → Link → Net → Metrics / Traffic → Core → Lab`。
- 确认位置数据契约为 `(satellite, time, xyz)`、ECEF、km，并要求 `SubArray` / `AbstractArray` 视图通过主链。
- 检查 Git 工作区，发现已有未提交修改和新增 backend integration 文件；后续不覆盖、不回滚这些改动。
- 确认 Julia 版本为 `1.12.6`。

结果：完成，无文件破坏性操作。

## 步骤 2：运行架构与主链最小验证

执行：

```bash
julia scripts/check_dependency_boundaries.jl
julia scripts/check_manifest_baseline.jl
julia --project=envs/core test/runtests_core_smoke.jl
julia --project=envs/core test/test_bare_array_contract.jl
```

结果：

- `DEPENDENCY BOUNDARIES: PASS`
- `MANIFEST BASELINE: PASS`
- Core smoke：3/3 通过
- Bare-array contract：7/7 通过

## 步骤 3：运行默认统一测试入口

执行：

```bash
SATSIM_VERBOSE=1 julia --project=. scripts/test_all.jl
```

结果：14 个目标通过，0 失败，7 个显式可选目标跳过。

通过目标：

- boundary
- manifest
- core-smoke
- bare-array
- foundation
- orbit
- link
- metrics
- net
- traffic
- root
- lab
- backend-contract
- stub-backend

## 步骤 4：运行 Opt / Security 可选包测试

执行：

```bash
SATSIM_VERBOSE=1 SATSIM_RUN_OPTIONAL=1 \
SATSIM_TEST_ONLY=opt,security \
julia --project=. scripts/test_all.jl
```

结果：

- Opt：通过
- Security：通过

## 步骤 5：运行后端 nightly 集成验证

执行：

```bash
SATSIM_VERBOSE=1 SATSIM_RUN_NIGHTLY=1 \
SATSIM_TEST_ONLY=juliaspace-backend,backend-e2e,backend-benchmark \
julia --project=. scripts/test_all.jl
```

结果：

- JuliaSpace backend adapter：通过
- 三后端端到端契约：通过
- Orbit backend benchmark smoke：通过

## 步骤 6：运行 Viz / GMAT 可选验证并定位失败

执行：

```bash
SATSIM_VERBOSE=1 SATSIM_RUN_VIZ=1 SATSIM_RUN_GMAT=1 \
SATSIM_TEST_ONLY=viz,gmat \
julia --project=. scripts/test_all.jl
```

结果：

- GMAT：通过
- Viz：首次失败

根因：

- `envs/viz/Manifest.toml` 是本地忽略文件，仍保存 Orbit 引入 `SatelliteSimBackends` 之前的依赖图。
- `Pkg.instantiate()` 不会自动修复这种已存在但过期的 Manifest。
- 因此加载 `SatelliteSimOrbit` 时报告它在当前 Manifest 中没有 `SatelliteSimBackends` 依赖。

复核修复方式：

```bash
julia --project=envs/viz -e \
'using Pkg; Pkg.resolve(); Pkg.instantiate(); using SatelliteSimViz'
```

结果：`SatelliteSimBackends` 被补入本地 Viz Manifest，Viz 成功预编译和加载。

## 步骤 7：全仓 Julia 语法解析检查

对 `src/`、`packages/`、`scripts/`、`test/` 下所有 `.jl` 文件执行 `Meta.parseall`。

结果：393 个 Julia 文件全部解析成功，无语法错误。

## 步骤 8：静态审查主链数组契约

发现以下剩余问题：

1. `NearestNeighborStrategy.positions` 仍限定为 `Array{Float64,3}`，不能保存 `SubArray`。
2. CGR 的 `build_contact_plan_from_positions!` 仍限定 `AbstractArray{Float64,3}`，不能接受其他 `Real` 元素类型。
3. Traffic bridge 的 GSL 时间序列仍限定为 `Vector{Matrix{...}}`，不能接受矩阵视图序列。
4. Lab 的 `ExperimentState`、checkpoint、城市流量辅助函数仍有具体 `Array` / `Matrix` 类型屏障。
5. `run_multiframe_experiment` 和 `_evaluate_traffic_full` 对时间切片产生了不必要复制，没有复用 `position_at_instant` 的零复制视图契约。
6. 可选环境 smoke runner 只执行 `Pkg.instantiate()`，无法修复本地过期 Manifest。
7. CGR 位置构造器缺少 xyz 维度、节点数量、时间步长和距离参数验证。

## 步骤 9：实施第一轮修复

已修改：

- `scripts/test_all.jl`
  - optional environment 和 backend integration 在 instantiate 前执行 `Pkg.resolve()`。
- `src/net/src/layers/03_topology/nearest_neighbor.jl`
  - 策略参数化为 `AbstractArray{<:Real,3}`。
  - 时间切片改为 `@view`。
  - 增加 `time_step` 和 `k` 参数验证。
- `src/net/src/layers/04_routing/cgr.jl`
  - 接受 `AbstractArray{<:Real,3}`。
  - 增加 xyz、node id 数量、`dt`、`max_dist` 验证。
- `src/traffic/src/traffic_bridge.jl`
  - GSL 矩阵序列放宽为 `AbstractVector` + `AbstractMatrix`。
- `src/lab/src/layers/11_experiment/state.jl`
  - 状态位置字段允许三维 `AbstractArray`。
- `src/lab/src/layers/11_experiment/checkpoint.jl`
  - checkpoint 摘要允许三维 `AbstractArray`。
- `src/lab/src/layers/11_experiment/runner.jl`
  - 使用 `positions_at_last` / `position_at_instant`，移除时间切片复制。
- `src/lab/src/layers/11_experiment/precomposed.jl`
  - Traffic 全评估中的 ISL/GSL 时间切片改为零复制视图。
- `src/lab/src/layers/11_experiment/traffic_scenarios.jl`
  - 城市流量辅助函数接受 `AbstractMatrix{<:Real}`。
- `src/metrics/src/capacity.jl`
  - 城市容量入口接受 `AbstractMatrix{<:Real}`。

状态：代码修改完成，下一步补回归测试并运行小步验证。

## 步骤 10：补充数组视图回归测试

新增测试覆盖：

- Net：`NearestNeighborStrategy` 直接保存 `SubArray{Float32}`，并通过拓扑生成。
- Net/CGR：`build_contact_plan_from_positions!` 接受三维位置视图，并验证错误节点数量会抛出 `ArgumentError`。
- Traffic：位置数据和 GSL availability/distance/elevation 时间序列全部使用视图，完整 bridge 仍能生成可达路由。
- Lab：`ExperimentState` 保存位置视图；checkpoint 在临时目录中对位置视图生成和读取摘要。

状态：测试代码已添加，下一步运行 Net、Traffic、Metrics、Lab 的针对性测试。

## 步骤 11：运行第一轮针对性回归

执行：

```bash
julia --project=src/net -e 'using Pkg; Pkg.test(; coverage=false)'
julia --project=src/traffic -e 'using Pkg; Pkg.test(; coverage=false)'
julia --project=src/metrics -e 'using Pkg; Pkg.test(; coverage=false)'
julia --project=src/lab -e 'using Pkg; Pkg.test(; coverage=false)'
```

结果：四个包测试全部通过，进程退出码为 0。

新增回归结果：

- Net position view / CGR 测试通过。
- Traffic bridge 矩阵视图序列测试通过。
- Lab 原测试 105/105 通过。
- Lab network traffic candidates 10/10 通过。
- Lab state/checkpoint position view 3/3 通过。

说明：`Pkg.test` 提示部分本地 package Manifest 尚未 resolve；这些 package 内 Manifest 属于本地临时文件，不作为业务逻辑失败处理，也不提交。

## 步骤 12：纠正第一轮针对性回归记录并收集全选项结果

复核发现步骤 11 的四条测试命令是以普通换行串联执行，未使用 `set -e` 或 `&&`。因此最后一个 Lab 命令的退出码 0 掩盖了此前 Net 测试的失败；“四个包测试全部通过”的记录不准确，现予以明确纠正，不回写或隐藏原始过程记录。

Net 的实际失败来自本轮新增测试中的字段名拼写错误：测试访问了不存在的 `topology.dynamic_candidate_links`，而 `TopologyOutput` 的实际字段是 `topology.dynamic_candidates`。Traffic、Metrics、Lab 的结果仍为通过。

随后完成了全选项统一入口：

```bash
SATSIM_VERBOSE=1 \
SATSIM_RUN_OPTIONAL=1 \
SATSIM_RUN_VIZ=1 \
SATSIM_RUN_GMAT=1 \
SATSIM_RUN_NIGHTLY=1 \
julia --project=. scripts/test_all.jl
```

结果：18 个目标通过，3 个目标失败，0 个跳过。

通过：boundary、manifest、core-smoke、bare-array、foundation、orbit、link、metrics、traffic、root、lab、backend-contract、stub-backend、opt、security、viz、gmat、backend-benchmark。

失败：

1. `net`：仅因上述新增测试字段名拼写错误。
2. `juliaspace-backend`：适配器结果与 native 轨道实现最大偏差 `0.3631059763656026 km`，要求不超过 `0.001 km`。
3. `backend-e2e`：同一 JuliaSpace/native 交叉实现误差导致失败；其余两个测试组分别为 41/41 和 21/21 通过。

本步骤同时复查了工作区状态。JuliaSpace backend、文档、平台和其他若干文件存在并发用户修改；后续只基于最新内容诊断，不回退或覆盖这些修改。

## 步骤 13：修复 Net 新增回归测试字段名

仅修正 `src/net/test/runtests.jl` 中已确认的测试拼写错误：

```diff
- topology.dynamic_candidate_links
+ topology.dynamic_candidates
```

未修改 Net 业务逻辑。下一步使用单独、可准确传播退出码的命令验证 Net。

## 步骤 14：单独验证 Net

执行：

```bash
julia --project=src/net -e 'using Pkg; Pkg.test(; coverage=false)'
```

结果：进程退出码 0，Net 全部测试通过。

- RoutingGraph：14/14
- ECMP：4/4
- 新增 position view / topology / CGR：5/5

存在的 Manifest 未 resolve 提示是包内本地临时 Manifest 警告，不影响本次测试结论。

## 步骤 15：检查 JuliaSpace 后端最新实现与失败测试

基于当前工作区最新文件检查后确认：JuliaSpace backend 已被并发修改为独立的 secular-elements 二体/J2/J4 实现，不再委托 `SatelliteSimOrbit.propagate_to_ecef`。因此测试第 39–42 行仍声称“adapter delegates physics to SatelliteSimOrbit, so zero error is expected”，注释已与实现不一致。

实现与 native 使用相同的 TEME→PEF 旋转调用和相同的秒到 Julian day 换算；当前偏差更可能来自独立轨道传播公式，而非 ECEF 旋转入口。下一步按 propagator、卫星和时刻分解误差，并与 SatelliteToolbox 的版本锁定实现逐项对照；在定位前不放宽 1 m 阈值。

## 步骤 16：定位 JuliaSpace J4 偏差根因

误差分解结果：

- `:two_body` 最大偏差约 `4.09e-12 km`。
- `:j2` 最大偏差约 `5.00e-12 km`。
- `:j4` 在 17、60、600 秒的最大偏差分别约为 `0.00938`、`0.03334`、`0.36311 km`。

因此 ECEF 旋转、二体传播和 J2 公式均正常，问题严格局限于 J4 secular rate。

进一步对照 SatelliteToolboxPropagators 版本锁定源码及其内部 `n̄`、`∂Ω`、`∂ω` 后定位到 Julia 词法陷阱：独立实现将偏心率平方命名为 ASCII `e2`，但公式写成了 `4e2`、`12e2`、`96e2` 等。Julia 将这些 token 解析为科学计数法常量（例如 `12e2 == 1200.0`），而不是 `12 * e2`。这使 J4 的 RAAN 和近地点幅角速率严重失真；J4 mean motion 中使用了独立的 `e2` 乘法，因此 mean motion 本身恰好仍与 native 一致。

修复原则：仅将所有“系数 × e2”改为显式乘号写法，同时更新已过时的测试注释；不回退当前独立实现，也不放宽 1 m 交叉实现阈值。

## 步骤 17：修复 JuliaSpace J4 数值公式

已在 `packages/SatelliteSimJuliaSpaceBackend/src/SatelliteSimJuliaSpaceBackend.jl` 中把 J4 速率公式里的所有歧义 token 改成显式乘法，例如：

```diff
- 12e2
+ 12 * e2
```

覆盖 RAAN 与 argument-of-perigee 公式中的 `4/5/12/21/72/96/116/189/252 × e2` 项。测试说明同步改为“独立 secular-elements 实现”，保留 `0.001 km` 阈值。

下一步先单独运行 JuliaSpace package 测试和 backend E2E。

## 步骤 18：单独验证 JuliaSpace backend 与 backend E2E

执行 JuliaSpace package 测试：

```bash
julia --project=packages/SatelliteSimJuliaSpaceBackend \
  -e 'using Pkg; Pkg.test(; coverage=false)'
```

结果：15/15 通过，退出码 0。二体、J2、J4 交叉实现误差均重新满足 `<= 0.001 km`。

执行 backend integration E2E：

```bash
julia --project=envs/backends-integration -e \
'using Pkg; Pkg.resolve(); Pkg.instantiate(); include("test/backends/test_backend_end_to_end.jl")'
```

结果：退出码 0。

- 三种轨道实现共用 Lab 入口：41/41
- Array/SubArray 贯穿 GSL、ISL、routing、Traffic：21/21
- native/JuliaSpace 交叉实现：3/3

J4 修复已在 package 层与集成层同时得到验证。

## 步骤 19：重跑依赖边界与核心契约

使用 `set -e` 确保任一子命令失败都会准确传播退出码，依次执行：

```bash
julia scripts/check_dependency_boundaries.jl
julia scripts/check_manifest_baseline.jl
julia --project=envs/core test/runtests_core_smoke.jl
julia --project=envs/core test/test_bare_array_contract.jl
```

结果全部通过：

- Dependency boundaries：PASS
- Manifest baseline：root/core/backends_stub 全部 PASS
- Core smoke：3/3
- Bare-array orchestration contract：7/7

## 步骤 20：重跑全仓语法与差异格式检查

- 对 `src/`、`packages/`、`scripts/`、`test/` 下 393 个 Julia 文件执行 `Meta.parseall`：全部成功。
- 执行 `git diff --check`：通过，无尾随空格或补丁格式错误。

下一步运行最终全选项统一测试入口。

## 步骤 21：完成最终全选项验收

先执行完整全选项入口：

```bash
SATSIM_VERBOSE=1 \
SATSIM_RUN_OPTIONAL=1 \
SATSIM_RUN_VIZ=1 \
SATSIM_RUN_GMAT=1 \
SATSIM_RUN_NIGHTLY=1 \
julia --project=. scripts/test_all.jl
```

桥接一次性命令存在 600 秒硬上限；该命令在依次完成 boundary、manifest、core-smoke、bare-array、foundation、orbit、link、metrics、net、traffic、root、lab、backend-contract、stub-backend、opt、security 共 16 个目标且全部通过后，于 Viz 预编译阶段被桥接终止。此终止不是测试失败。

为获得准确退出码，随后按统一入口的正式筛选方式拆分剩余目标：

```bash
SATSIM_VERBOSE=1 SATSIM_RUN_VIZ=1 SATSIM_TEST_ONLY=viz julia --project=. scripts/test_all.jl
SATSIM_VERBOSE=1 SATSIM_RUN_GMAT=1 SATSIM_TEST_ONLY=gmat julia --project=. scripts/test_all.jl
SATSIM_VERBOSE=1 SATSIM_RUN_NIGHTLY=1 SATSIM_TEST_ONLY=juliaspace-backend,backend-e2e,backend-benchmark julia --project=. scripts/test_all.jl
```

结果：

- Viz：`1 passed, 0 failed`；
- GMAT：`1 passed, 0 failed`；
- Nightly：JuliaSpace backend、backend E2E、backend benchmark 共 `3 passed, 0 failed`；
- 合并前述完整运行证据，本轮统一入口覆盖的 21 个目标全部通过，无业务逻辑失败。

本步骤未修改业务代码；只补齐了步骤 20 留下的最终验收断点。
