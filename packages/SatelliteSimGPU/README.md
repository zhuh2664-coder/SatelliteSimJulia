# SatelliteSimGPU

`SatelliteSimGPU` 是 SatelliteSimJulia 的可选 GPU 加速包，当前提供
`coverage_loss` 的 KernelAbstractions 后端无关实现。

它被设计为未来放入主项目 `packages/` 的独立包：

- 不加入 SatelliteSimJulia 根环境；
- 不修改现有 CPU 主链路；
- 不改变 CPU 默认行为；
- CUDA、Metal 不作为硬依赖，由调用方按需提供；
- 同一份 kernel 可运行在 CPU、CUDA 或 Metal 后端。

当前实现的入口是：

```julia
coverage_loss_gpu(positions, ground_pts, weights; kwargs...)
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

## 实现结构

核心 kernel 对 `(ground_point, time)` 并行，每个线程顺序遍历卫星并
完成 noisy-OR。随后：

1. 每个 ground point 顺序扫描时间维度，计算 leaky revisit；
2. 使用数组后端的 `sum` / `maximum` 和广播完成归约；
3. CUDA/Metal 的设备数组由 KernelAbstractions 和底层数组包负责执行。

没有在包中加入 CUDA 或 Metal 专用分支。

## Golden reference

目录：

```text
golden/
├── golden_coverage_source.jl
└── golden_reference.jl
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

Float64 CPU 后端实测最大相对误差：

```text
2.87e-13
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
