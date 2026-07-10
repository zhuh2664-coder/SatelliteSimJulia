# Orbital propagation GPU benchmark

## Environment

- Date: 2026-07-10
- Cloud runner: Modal
- GPU: NVIDIA Tesla T4
- Julia: 1.12.6
- CUDA.jl: 5.x
- SatelliteToolbox.jl: 1.x
- Numeric type: `Float64`
- CPU reference threads: 1
- Time interval: 86,400 seconds
- Modal run: <https://modal.com/apps/zhuh2664-coder/main/ap-E0RdrJcD2LyZRnHfropW05>

The benchmark compares `independent_positions_gpu` with the preserved CPU
golden implementation in `golden/golden_orbit_reference.jl`. The CPU
reference and host TEME→PEF rotation measurements use the minimum of three
samples. GPU compute uses a warmup, synchronization, and the minimum of five
samples.

Each scale runs in a fresh Julia subprocess. H2D and D2H are one-shot
measurements, so the reported pipeline includes fresh-process CUDA transfer
and allocation overhead:

```text
pipeline =
    host rotation precompute + H2D upload + GPU compute + D2H download
```

## Results

| N | NT | Propagator | CPU reference (s) | Host rotation (s) | H2D (s) | GPU compute (s) | D2H (s) | Compute speedup | Pipeline speedup | Max abs. error (km) | Max elementwise rel. error |
|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 24 | 61 | `two_body` | 0.000631 | 0.000087 | 0.041132 | 0.000599 | 0.000163 | 1.05× | 0.02× | 9.91e-11 | 1.56e-11 |
| 24 | 61 | `j2` | 0.000649 | 0.000089 | 0.031833 | 0.000595 | 0.000059 | 1.09× | 0.02× | 9.98e-11 | 6.55e-12 |
| 24 | 61 | `j4` | 0.000811 | 0.000095 | 0.044131 | 0.000631 | 0.000062 | 1.28× | 0.02× | 1.92e-10 | 6.40e-12 |
| 132 | 1441 | `j4` | 0.106060 | 0.002026 | 0.050776 | 0.002552 | 0.003170 | 41.56× | 1.81× | 1.95e-10 | 2.63e-10 |
| 512 | 1441 | `j4` | 0.427099 | 0.001982 | 0.030869 | 0.008128 | 0.010288 | 52.55× | 8.33× | 1.98e-10 | 6.19e-09 |
| 2048 | 1441 | `j4` | 1.861768 | 0.002003 | 0.036300 | 0.030629 | 0.101554 | 60.78× | 10.92× | 2.01e-10 | 6.84e-08 |
| 4096 | 1441 | `j4` | 3.604263 | 0.001996 | 0.041592 | 0.041718 | 0.088429 | 86.40× | 20.75× | 1.98e-10 | 1.07e-07 |

## Interpretation

- `:two_body`, `:j2`, and `:j4` all pass real CUDA parity at the focused
  `24 × 61` scale.
- Kernel acceleration grows from approximately `1×` for the small launch-bound
  case to `86.40×` at `4096 × 1441`.
- The measured fresh-process pipeline becomes faster than the CPU reference at
  `132 × 1441` and reaches `20.75×` at `4096 × 1441`.
- Maximum absolute Cartesian-component error remains at or below
  `2.01e-10 km` (`2.01e-7 m`) across all scales.
- The elementwise relative metric divides by each individual Cartesian
  component. It therefore grows when a reference component is close to zero;
  the stable absolute bound is the more informative accuracy measure for the
  largest cases.

## Reproduction

Use an optional Julia environment that provides CUDA.jl and
SatelliteToolbox.jl, while developing the local `SatelliteSimGPU` package:

```bash
julia --project=/path/to/optional-env \
  bench_orbit_cuda.jl N NT [two_body|j2|j4]
```

CUDA.jl and SatelliteToolbox.jl remain optional benchmark dependencies and are
not runtime dependencies of `SatelliteSimGPU`.
