# SatelliteSimGPU

`SatelliteSimGPU` 是 SatelliteSimJulia 的可选 GPU 加速包，当前提供
覆盖损失、GSL 可见性和独立轨道解析传播的 KernelAbstractions
后端无关实现。

它被设计为未来放入主项目 `packages/` 的独立包：

- 不加入 SatelliteSimJulia 根环境；
- 不修改现有 CPU 主链路；
- 不改变 CPU 默认行为；
- CUDA、Metal 不作为硬依赖，由调用方按需提供；
- 同一份 kernel 可运行在 CPU、CUDA 或 Metal 后端。

当前实现的入口是：

```julia
coverage_loss_gpu(positions, ground_pts, weights; kwargs...)
evaluate_gsl_batch_gpu(positions, ground_ecef, ned_rotation; kwargs...)
independent_positions_gpu(orbital_elements, times, ecef_rotation; kwargs...)
```

## 安装

在包目录中实例化依赖：

```bash
julia --project=/path/to/SatelliteSimGPU -e \
  'using Pkg; Pkg.instantiate()'
```

本包只声明：

```text
KernelAbstractions
Adapt
```

### 纯 CPU / KernelAbstractions CPU 后端

```julia
using SatelliteSimGPU

loss = coverage_loss_gpu(
    positions,
    ground_pts,
    weights;
    min_el=10.0,
    τ_cov=5.0,
    dt=1.0,
    τ_revisit=1.0,
    λ=0.1,
)
```

### CUDA

CUDA.jl 由用户环境自带，不是本包依赖：

```julia
using CUDA
using SatelliteSimGPU

positions_d = CuArray(positions)
ground_pts_d = CuArray(ground_pts)
weights_d = CuArray(weights)

loss = coverage_loss_gpu(
    positions_d,
    ground_pts_d,
    weights_d,
)
```

### Metal

Metal.jl 由用户环境自带，不是本包依赖：

```julia
using Metal
using SatelliteSimGPU

positions_d = MtlArray(positions)
ground_pts_d = MtlArray(ground_pts)
weights_d = MtlArray(weights)

loss = coverage_loss_gpu(
    positions_d,
    ground_pts_d,
    weights_d,
)
```

传入的三个数组应已经位于同一个目标后端，并且具有相同的浮点
`eltype`。CUDA/Tesla 可以使用 `Float64`；Apple Metal 通常应使用
`Float32`。

## API 与 CPU reference

`coverage_loss_gpu` 的签名和默认参数与
`src/opt/src/layers/06_optimization/coverage.jl` 中的 CPU
`coverage_loss` 一致：

```julia
coverage_loss_gpu(
    positions::AbstractArray{T,3},
    ground_pts::AbstractMatrix{T},
    weights::AbstractVector{T};
    min_el::T=T(10.0),
    τ_cov::T=T(5.0),
    dt::T=T(1.0),
    τ_revisit::T=one(T),
    λ::T=T(0.1),
) where T <: Number
```

数据形状：

```text
positions : (N_satellite, N_time, 3)
ground_pts: (N_ground, 3)
weights   : (N_ground,)
```

返回单个与输入浮点类型对应的标量。

实现保持以下 CPU 语义：

```text
soft coverage:
    1 / (1 + exp(-(elevation - min_el) / τ_cov))

noisy OR:
    1 - ∏ᵢ(1 - coverageᵢ)

leaky revisit:
    gap_next = (gap + dt) * (1 - coverage)

objective:
    -mean_coverage + λ * logsumexp(revisit_gaps; τ_revisit)
```

CPU `coverage_loss` 仍是 golden reference。GPU 版本是显式 opt-in
加速路径，不替代 CPU 默认路径。

## GSL 可见性批量评估

`evaluate_gsl_batch_gpu` 评估所有卫星、地面站和时间步的 GSL
可见性。GPU 核心不依赖 SatelliteToolbox；调用方需要在 host 侧使用
SatelliteToolbox 预先计算每个地面站的 ECEF 坐标和 ECEF→NED 旋转矩阵。
旋转矩阵的每一列应通过官方 `ecef_to_ned(...; translate=true)` 对 ECEF
基向量的响应提取，避免手写坐标约定。

```julia
evaluate_gsl_batch_gpu(
    positions,
    ground_ecef,
    ned_rotation;
    gsl_min_elevation_deg,
    gsl_max_range_km,
)
```

输入契约：

```text
positions    : (N, NT, 3), ECEF km
ground_ecef : (M, 3),     ECEF km
ned_rotation: (M, 3, 3),  每站 ECEF→NED 矩阵
```

输出均为 `(N, M, NT)`：

```text
available   : Bool
distance_km : 输入浮点类型
elevation_deg
delay_ms
```

默认门限与 CPU reference 的 `LEO_DEFAULTS` 一致：

```text
gsl_min_elevation_deg = 25.0
gsl_max_range_km      = 2000.0
```

GSL 仰角严格使用 CPU reference 的 NED 公式，而不是 coverage kernel
使用的 ECEF 法向量 atan2 公式。SatelliteToolbox 仅作为测试和 host
预处理依赖，未加入包的运行时 `[deps]`。

## 独立轨道解析传播

`independent_positions_gpu` 对应
`SatelliteSimJuliaSpaceBackend._independent_positions` 的
TwoBody/J2/J4 secular-element 解析实现。每个 `(satellite, time)` 由
GPU kernel 独立计算，输出保持主链契约 `(N, NT, 3)`、ECEF、km。

```julia
positions = independent_positions_gpu(
    orbital_elements,
    times,
    ecef_rotation;
    propagator=:j4,
)
```

输入契约：

```text
orbital_elements: (N, 6)
  columns = (a_m, e, i_rad, Ω_rad, ω_rad, f_rad)
times          : (NT,), seconds
ecef_rotation  : (NT, 3, 3), TEME→PEF
```

`ecef_rotation[t, :, :]` 必须在 host 侧通过官方 SatelliteToolbox
预计算，再与其它输入一起移动到目标后端：

```julia
for (time_index, elapsed_s) in pairs(times)
    ecef_rotation[time_index, :, :] .=
        SatelliteToolbox.r_eci_to_ecef(
            SatelliteToolbox.TEME(),
            SatelliteToolbox.PEF(),
            elapsed_s / 86_400,
        )
end
```

这与 GSL 的 host 几何预处理采用相同边界：GPU 包不重新实现官方参考系
转换，也不把 SatelliteToolbox 加入运行时依赖。支持的传播器为
`:two_body`、`:j2`、`:j4`。

## 实现结构

coverage 核心 kernel 对 `(ground_point, time)` 并行，每个线程顺序遍历
卫星并完成 noisy-OR。随后：

1. 每个 ground point 顺序扫描时间维度，计算 leaky revisit；
2. 使用数组后端的 `sum` / `maximum` 和广播完成归约；
3. CUDA/Metal 的设备数组由 KernelAbstractions 和底层数组包负责执行。

GSL kernel 对 `(satellite, station, time)` 并行。轨道传播先用一个
`N` 规模 kernel 预计算每颗卫星的 mean motion、RAAN/近地点进动率和
初始 mean anomaly，再用 `N×NT` 规模 kernel 求解 Kepler 方程、计算
ECI 位置并应用 host 预计算的 TEME→PEF 旋转。

没有在包中加入 CUDA 或 Metal 专用分支。

## Golden reference

目录：

```text
golden/
├── golden_coverage_source.jl
├── golden_reference.jl
├── golden_gsl_geometry_constants.jl
├── golden_gsl_geometry_source.jl
├── golden_gsl_constraints_source.jl
├── golden_gsl_evaluator_source.jl
├── golden_gsl_reference.jl
├── golden_orbit_source.jl
└── golden_orbit_reference.jl
```

`golden_coverage_source.jl` 是

```text
src/opt/src/layers/06_optimization/coverage.jl
```

的逐字副本，SHA-256 与原始 reference 一致：

```text
8fad749872c1759fd7d9abb89174ba04057776cb8294c9972ac1c82a100b2d46
```

它只用于独立 CPU parity 测试，不 include SatelliteSimJulia 主项目，
因此不会引入 SatelliteToolbox 等重依赖。

GSL golden 模块逐字保存了以下 CPU reference 文件，并在测试中通过
`using SatelliteToolbox` 运行真实的 `evaluate_gsl_batch`：

```text
foundation__geometry_constants.jl
link__geometry.jl
link__constraints.jl
link__evaluator.jl
```

四个逐字副本分别与本机 `reference/` 快照 SHA-256 一致。SatelliteToolbox
只在 `[extras]`/测试与可选 benchmark 环境中出现，不是包运行时依赖。

`golden_orbit_source.jl` 是用户开发分支中
`packages/SatelliteSimJuliaSpaceBackend/src/SatelliteSimJuliaSpaceBackend.jl`
的逐字快照：

```text
fd24bff9ea252558b36a265b02b2e613b13875a1a54cea8f1bbae7257dcda111
```

测试会现场校验 SHA-256，并通过 `golden_orbit_reference.jl` 中独立保存的
CPU 解析实现运行 TwoBody/J2/J4 parity。

## CPU parity 测试

```bash
julia --project=. -e 'using Pkg; Pkg.test()'
```

当前 CPU KernelAbstractions 后端测试规模：

```text
(N, NT, G) = (24, 10, 50)
(N, NT, G) = (66, 30, 200)
(N, NT, G) = (132, 60, 500)
```

GSL 测试规模：

```text
(N, M, NT) = (66, 10, 30)
(N, M, NT) = (132, 20, 60)
```

轨道传播测试覆盖：

```text
propagator = two_body / j2 / j4
(N, NT) = (24, 61)
duration = 5400 s
Float64 + Float32
```

Float64 CPU 后端实测最大相对误差：

```text
2.87e-13
```

GSL CPU 后端实测：

```text
available: 完全一致
distance:  相对误差 0
delay:     相对误差 0
elevation: 最大相对误差 2.11e-11
```

## 已验证硬件结果

### NVIDIA Tesla T4 / CUDA / Float64

该实现已在 Modal Tesla T4 上完成真实 GPU 验证：

| 后端 | 精度 | 测试规模 | parity 相对误差 | 加速比 |
|---|---:|---|---:|---:|
| Tesla T4 / CUDA | Float64 | `24×10×50` 至 `400×200×2000` | ≤ `4e-12` | 最高约 `76×` |

测试脚本使用 warmup，并对 GPU 计时进行同步；详见开发环境中的
`cuda_parity.jl`。

### Apple M2 Max / Metal / Float32

在用户 Mac 的隔离临时项目中实测，`Metal.functional() == true`：

| 精度 | 测试规模 | parity 相对误差 | CPU/Metal 加速比 |
|---:|---|---:|---:|
| Float32 | `66×30×200` | `1.886e-7` | `5.87×` |
| Float32 | `132×60×500` | `9.864e-8` | `48.51×` |

CPU golden 使用 Float64，Metal 使用 Float32。误差小于预期的
`1e-3` 至 `1e-4` 量级。GPU 计时包含 warmup，并使用 `Metal.@sync`
确保计算完成后取时。

## Benchmark

CPU/reference 与 `coverage_loss_gpu` 对照脚本：

```bash
julia --project=. bench_coverage.jl N NT G
```

例如：

```bash
julia --project=. bench_coverage.jl 132 60 500
```

该脚本在正式计时前执行 warmup，并输出两个实现的耗时、loss 和相对误差。

GSL benchmark：

```bash
julia --project=/path/to/optional-env \
  bench_gsl.jl N M NT
```

该 optional environment 需要同时提供 `SatelliteToolbox` 和本地
`SatelliteSimGPU`（例如先执行 `Pkg.develop(path=".../SatelliteSimGPU")`）。
脚本输出 CPU golden 与 KernelAbstractions 实现的耗时、speedup、三个
浮点输出的最大相对误差以及 `available` 是否完全一致。

轨道传播 benchmark：

```bash
julia --project=/path/to/optional-env \
  bench_orbit.jl N NT [two_body|j2|j4]
```

脚本分别报告 CPU golden、host TEME→PEF 旋转预计算和 kernel 耗时，
并同时给出纯 kernel 与包含 host 预处理的端到端加速比。
