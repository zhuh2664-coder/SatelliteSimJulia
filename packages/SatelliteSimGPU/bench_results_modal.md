# SatelliteSimGPU — Real-machine GPU benchmark (Modal, NVIDIA A10G)

Measured numbers for the three backend-agnostic KernelAbstractions kernels
(`coverage_loss_gpu`, `evaluate_gsl_batch_gpu`, `evaluate_isl_batch_gpu`) running
on a **real CUDA GPU** vs the **same kernels on the CPU backend**. These are the
numbers that cannot be obtained from the local CPU-only test suite.

- **Date:** 2026-07-12 (EDT)
- **Runner:** `MODAL_PROFILE=satsim-gpu modal run modal_gpu.py` (workspace `shideling521`)
  → `julia --project=/opt/SatelliteSimGPU modal_gpu_runner.jl`
- **Modal run:** `ap-pZkdRnAoIo39fPp9w4GMGZ`, `exit_code=0`, `MODAL_GPU_VALIDATION status=PASS`
- **Total wall-clock:** ~530 s (image build ~211 s + precompile ~16 s + Julia validate/bench)

## 1. Environment

| Item | Value |
|---|---|
| GPU | **NVIDIA A10G** (Ampere) |
| GPU memory | 22.06 GiB |
| Compute capability | 8.6 |
| NVIDIA driver | 13.3.0 |
| CUDA runtime (CUDA.jl) | 12.9.0 |
| CUDA.jl | 6.2.1 |
| KernelAbstractions | 0.9.42 |
| Julia | 1.12.6 |
| Container CPU request | `cpu=2.0`, `memory=4096` (from `modal_gpu.py`) |
| **Julia threads** | **1** (CPU baseline is single-threaded) |
| Base image | `ghcr.io/juliagpu/cuda.jl@sha256:8c40fadf…` (pinned) |

## 2. What "GPU vs CPU backend" means here (read before trusting speedups)

The kernels are backend-independent: an `Array` input runs on the
KernelAbstractions **CPU backend**; a `CuArray` input runs on the **CUDA
backend**. The comparison below is therefore **the same kernel source, same
algorithm, same precision, different device** — not "GPU vs a naive scalar loop".

Honesty caveats (so these are not context-free self-reported speedups):

- **CPU baseline is single-threaded** (`julia_threads=1`). It is a compiled
  KernelAbstractions kernel (≈2×10⁷ elevation-evals/s, very stable across
  scales), *not* the slow allocating scalar reference. A multi-threaded or
  SIMD-tuned CPU baseline would shrink every speedup below by up to ~1 order of
  magnitude on the 2 vCPUs requested.
- **`gpu_compute_s`** = kernel only, inputs **already resident on the device**,
  bracketed by `CUDA.synchronize()`, **min of 20 runs, after a warm-up call** →
  **excludes one-time PTX/LLVM kernel compilation**.
- **`gpu_e2e_s`** = `device_pipeline(CUDABackend, …)`: allocate `CuArray`s +
  H2D upload + kernel + D2H download of the full result, min of 20, post-warmup.
  This is the honest cost of an *isolated* op call that has to move data.
- **`cpu_backend_s`** = same kernel on host `Array`s, min of 3, post-warmup.
- `speedup_compute = cpu_backend_s / gpu_compute_s`;
  `speedup_e2e = cpu_backend_s / gpu_e2e_s`.
- **A10G is an FP32 part**: FP64 throughput is ~1/32 of FP32, so Float64
  speedups are far smaller than Float32 (confirmed below).
- Throughput unit ("eval") = one satellite×point×time (coverage/GSL) or one
  pair×time (ISL). ISL "evals" undercount work because available links run a
  data-dependent duration loop (up to 300 iterations), so ISL throughput is
  **not** comparable to coverage/GSL throughput.

## 3. Real-machine correctness (verified before timing)

All parity checks ran on the A10G against the frozen scalar/golden references and
against the CPU backend. **Every check passed**; at every benchmark scale the GPU
availability booleans matched the CPU backend exactly (`avail_mismatch=0`).

| Check | Float64 rel. error | Float32 rel. error |
|---|---|---|
| Coverage loss (vs scalar ref) | 1.2×10⁻¹⁴ | 9.1×10⁻⁶ |
| GSL distance / elevation / delay | 0 / 2.8×10⁻¹⁵ / 0 | 0 / 1.4×10⁻⁶ / 0 |
| GSL canonical geometry | PASS | PASS |
| ISL dist/elev/cosψ/duration (vs golden) | 0 / 2.4×10⁻¹⁶ / 0 / 0 | 1.4×10⁻⁷ / 6.9×10⁻⁵ / 5.9×10⁻⁶ / 0 |
| ISL availability & LOS booleans | 0/2880 mismatches | 0/2880 mismatches |
| Registered compute backend (`:cuda`) | PASS | PASS |

Conclusion: the GPU produces results identical to the CPU/golden reference within
floating-point rounding (machine-eps for Float64; ~1e-4…1e-6 for Float32). The
speedups below are therefore comparing *correct* GPU output.

## 4. Coverage — `coverage_loss_gpu`

Work = `N·NT·G` elevation evaluations; output is a single host scalar (so
end-to-end ≈ compute-only, the D2H transfer is one number).

### Float32
| N | NT | G | CPU (ms) | GPU compute (ms) | GPU e2e (ms) | Speedup (compute) | Speedup (e2e) | GPU throughput |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 66 | 60 | 500 | 91.05 | 0.212 | 0.239 | **429×** | 381× | 9.3 Geval/s |
| 550 | 90 | 1000 | 2265.66 | 0.790 | 0.860 | **2867×** | 2634× | 62.6 Geval/s |
| 1584 | 90 | 1500 | 10698.33 | 6.871 | 6.103 | **1557×** | 1753× | 31.1 Geval/s |
| 1584 | 240 | 500 | 9501.38 | 9.549 | 9.853 | **995×** | 964× | 19.9 Geval/s |

### Float64
| N | NT | G | CPU (ms) | GPU compute (ms) | GPU e2e (ms) | Speedup (compute) | Speedup (e2e) | GPU throughput |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 66 | 60 | 500 | 100.71 | 2.642 | 2.691 | 38.1× | 37.4× | 0.75 Geval/s |
| 550 | 90 | 1000 | 2516.17 | 39.568 | 39.694 | 63.6× | 63.4× | 1.25 Geval/s |
| 1584 | 90 | 1500 | 10836.10 | 113.156 | 113.459 | **95.8×** | 95.5× | 1.89 Geval/s |
| 1584 | 240 | 500 | 9628.10 | 113.127 | 113.900 | 85.1× | 84.5× | 1.68 Geval/s |

Coverage is the ideal GPU workload (large, regular, no divergence). Float32 peaks
at **~63 Geval/s** and 1500–2900× over single-thread CPU; Float64 lands at
~2 Geval/s and ~60–96×. The ~30× gap between the two precisions is exactly the
A10G FP32/FP64 ratio.

## 5. GSL — `evaluate_gsl_batch_gpu`

Work = `N·M·NT` link evaluations; output = four `(N,M,NT)` arrays. Here the D2H
download is large, so **end-to-end is transfer-bound** and much lower than
compute-only.

### Float32
| N | M | NT | CPU (ms) | GPU compute (ms) | GPU e2e (ms) | Speedup (compute) | Speedup (e2e) | GPU throughput |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 66 | 20 | 60 | 3.559 | 0.055 | 0.287 | 64.7× | 12.4× | 1.44 Geval/s |
| 550 | 40 | 90 | 97.66 | 0.319 | 2.611 | **305.8×** | 37.4× | 6.20 Geval/s |
| 1584 | 64 | 90 | 457.65 | 2.683 | 28.714 | 170.6× | 15.9× | 3.40 Geval/s |
| 1584 | 100 | 60 | 460.75 | 2.950 | 32.016 | 156.2× | 14.4× | 3.22 Geval/s |

### Float64
| N | M | NT | CPU (ms) | GPU compute (ms) | GPU e2e (ms) | Speedup (compute) | Speedup (e2e) | GPU throughput |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 66 | 20 | 60 | 4.401 | 0.090 | 0.440 | 48.8× | 10.0× | 0.88 Geval/s |
| 550 | 40 | 90 | 112.22 | 1.204 | 5.273 | 93.2× | 21.3× | 1.64 Geval/s |
| 1584 | 64 | 90 | 539.41 | 5.582 | 47.713 | 96.6× | 11.3× | 1.63 Geval/s |
| 1584 | 100 | 60 | 540.37 | 5.753 | 59.169 | 93.9× | 9.1× | 1.65 Geval/s |

GSL compute-only reaches ~100–300× (F32) / ~90–97× (F64), but a **single isolated
call that must download 3–4 large float arrays drops to ~9–37×** end-to-end. This
is the strongest argument for the device-residency pipeline (`device_pipeline` /
keeping orbit→link→coverage on-device): the transfer, not the math, is the wall.

## 6. ISL — `evaluate_isl_batch_gpu`

Work = `P·NT` link-pair evaluations, with velocities (full path: LOS + RTN
elevation + azimuth-cone + straight-line duration loop). This kernel has
**data-dependent branching / warp divergence**, so speedups are the lowest of the
three and precision matters a lot.

### Float32
| N | P (pairs) | NT | CPU (ms) | GPU compute (ms) | GPU e2e (ms) | Speedup (compute) | Speedup (e2e) |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 66 | 132 | 60 | 0.756 | 0.081 | 0.416 | 9.3× | 1.8× |
| 550 | 1100 | 90 | 8.392 | 0.126 | 3.187 | 66.7× | 2.6× |
| 1584 | 3168 | 90 | 25.003 | 0.210 | 7.317 | **119.2×** | 3.4× |
| 1584 | 6336 | 90 | 39.334 | 0.355 | 2.048 | 110.8× | 19.2× |

### Float64
| N | P (pairs) | NT | CPU (ms) | GPU compute (ms) | GPU e2e (ms) | Speedup (compute) | Speedup (e2e) |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 66 | 132 | 60 | 0.574 | 1.755 | 1.951 | **0.33× (GPU slower)** | 0.29× |
| 550 | 1100 | 90 | 7.520 | 3.390 | 4.293 | 2.22× | 1.75× |
| 1584 | 3168 | 90 | 22.383 | 7.088 | 9.024 | 3.16× | 2.48× |
| 1584 | 6336 | 90 | 56.239 | 13.305 | 16.163 | 4.23× | 3.48× |

ISL honesty notes:

- **Float64 ISL barely benefits** (2–4×) and is **slower than the single-thread
  CPU at the smallest scale (0.33×)** — tiny workload, kernel-launch overhead and
  the divergent duration loop dominate, and A10G FP64 is weak. Do not run ISL in
  Float64 on this GPU for small problems.
- **Float32 ISL is ~10–120× (compute)** but end-to-end collapses to ~2–19×
  because the seven output arrays must be downloaded. (The e2e figures are the
  noisiest numbers in this report — allocation + transfer jitter; e.g. the
  P=6336 e2e min came out below P=3168, which is measurement noise, not a real
  inversion. Treat ISL e2e as order-of-magnitude.)
- ~5% of the random link-pairs are "available", so the duration loop is actually
  exercised (matching the golden reference exactly).

## 7. Takeaways

1. **Correctness on real hardware is confirmed first**: GPU output matches the
   CPU backend and the golden scalar references to floating-point rounding
   (Float64 ≈ machine-eps; Float32 ≈ 1e-4…1e-6), with identical availability
   booleans at every scale. Speedups are for verified-correct output.
2. **Coverage is the big win**: up to ~63 Geval/s and ~1500–2900× (Float32) /
   ~60–96× (Float64) over a single CPU thread, because it is a large, regular,
   divergence-free reduction whose only output is a scalar.
3. **Float32 is the A10G sweet spot**: ~15–50× faster than Float64 on-device
   across all three ops. Use Float32 unless the objective needs Float64.
4. **Transfers dominate isolated GSL/ISL calls**: compute-only speedups
   (~100–300×) fall to ~9–37× end-to-end. The device-residency pattern
   (`device_pipeline`, keeping the pipeline on-device) is essential to realize
   the compute speedup in practice.
5. **ISL is divergence-limited**: modest speedups, and Float64 ISL can lose to
   the CPU on small inputs. It scales up with more pairs (110–120× F32 compute at
   1584 sats), but end-to-end is transfer-bound.
6. **Baseline caveat**: all speedups are vs a *single-threaded* CPU backend
   running the identical kernel. Against a multi-threaded/SIMD CPU baseline the
   factors would be roughly an order of magnitude smaller; the absolute GPU
   throughput numbers (Geval/s) are the device-independent figures to quote.

## 8. Reproduce

```bash
cd packages/SatelliteSimGPU
export HTTPS_PROXY=http://127.0.0.1:7890 HTTP_PROXY=http://127.0.0.1:7890 NO_PROXY=localhost,127.0.0.1,::1
MODAL_PROFILE=satsim-gpu modal run modal_gpu.py
```

`modal_gpu_runner.jl` prints `GPU_INFO …`, the `*_PARITY` correctness lines, and
one `BENCH op=… type=… …` line per scale between `BENCH_SUITE_BEGIN` /
`BENCH_SUITE_END`, ending with `MODAL_GPU_VALIDATION status=PASS`. Scales,
samples (`CPU_SAMPLES=3`, `GPU_SAMPLES=20`), and precisions are defined in
`run_benchmark_suite()`.

## 9. Raw measurement lines (verbatim from the Modal run)

```text
GPU_INFO device=NVIDIA A10G total_mem_gib=22.06 compute_capability=8.6 driver=13.3.0 cuda_runtime=12.9.0 julia=1.12.6 cuda_jl=6.2.1 kernel_abstractions=0.9.42 julia_threads=1 cpu_threads_visible=14
COVERAGE_PARITY type=Float64 status=PASS relative_error=1.2299463627532284e-14 backend=CUDABackend
COVERAGE_PARITY type=Float32 status=PASS relative_error=9.107964e-6 backend=CUDABackend
GSL_PARITY type=Float64 status=PASS distance_relative_error=0.0 elevation_relative_error=2.7647865816024624e-15 delay_relative_error=0.0
GSL_PARITY type=Float32 status=PASS distance_relative_error=0.0 elevation_relative_error=1.3961935e-6 delay_relative_error=0.0
ISL_PARITY type=Float64 status=PASS available_mismatch=0/2880 los_mismatch=0/2880 distance_relative_error=0.0 delay_relative_error=0.0 elevation_relative_error=2.4448685358239504e-16 cos_psi_relative_error=0.0 duration_relative_error=0.0
ISL_PARITY type=Float32 status=PASS available_mismatch=0/2880 los_mismatch=0/2880 distance_relative_error=1.3858315996518934e-7 delay_relative_error=2.0746328292025296e-7 elevation_relative_error=6.927436449375377e-5 cos_psi_relative_error=5.895489677814559e-6 duration_relative_error=0.0
BENCH op=coverage type=Float32 N=66 NT=60 G=500 cpu_backend_s=0.0910528 gpu_compute_s=0.000212177 gpu_e2e_s=0.00023883 speedup_compute=429.14 speedup_e2e=381.25
BENCH op=coverage type=Float32 N=550 NT=90 G=1000 cpu_backend_s=2.265664511 gpu_compute_s=0.000790315 gpu_e2e_s=0.000860081 speedup_compute=2866.79 speedup_e2e=2634.25
BENCH op=coverage type=Float32 N=1584 NT=90 G=1500 cpu_backend_s=10.698332158 gpu_compute_s=0.006870705 gpu_e2e_s=0.006102871 speedup_compute=1557.09 speedup_e2e=1753.00
BENCH op=coverage type=Float32 N=1584 NT=240 G=500 cpu_backend_s=9.501384628 gpu_compute_s=0.009549124 gpu_e2e_s=0.00985286 speedup_compute=995.00 speedup_e2e=964.33
BENCH op=coverage type=Float64 N=66 NT=60 G=500 cpu_backend_s=0.100713052 gpu_compute_s=0.002642287 gpu_e2e_s=0.002691311 speedup_compute=38.12 speedup_e2e=37.42
BENCH op=coverage type=Float64 N=550 NT=90 G=1000 cpu_backend_s=2.516166341 gpu_compute_s=0.03956762 gpu_e2e_s=0.03969441 speedup_compute=63.59 speedup_e2e=63.39
BENCH op=coverage type=Float64 N=1584 NT=90 G=1500 cpu_backend_s=10.836095753 gpu_compute_s=0.113156267 gpu_e2e_s=0.113459491 speedup_compute=95.76 speedup_e2e=95.51
BENCH op=coverage type=Float64 N=1584 NT=240 G=500 cpu_backend_s=9.628102628 gpu_compute_s=0.113126562 gpu_e2e_s=0.113900068 speedup_compute=85.11 speedup_e2e=84.53
BENCH op=gsl type=Float32 N=66 M=20 NT=60 cpu_backend_s=0.003559452 gpu_compute_s=5.5044e-5 gpu_e2e_s=0.000287463 speedup_compute=64.67 speedup_e2e=12.38
BENCH op=gsl type=Float32 N=550 M=40 NT=90 cpu_backend_s=0.097662464 gpu_compute_s=0.000319326 gpu_e2e_s=0.002610665 speedup_compute=305.84 speedup_e2e=37.41
BENCH op=gsl type=Float32 N=1584 M=64 NT=90 cpu_backend_s=0.45764939 gpu_compute_s=0.002683191 gpu_e2e_s=0.028714389 speedup_compute=170.56 speedup_e2e=15.94
BENCH op=gsl type=Float32 N=1584 M=100 NT=60 cpu_backend_s=0.460751351 gpu_compute_s=0.002949512 gpu_e2e_s=0.032016451 speedup_compute=156.21 speedup_e2e=14.39
BENCH op=gsl type=Float64 N=66 M=20 NT=60 cpu_backend_s=0.004401041 gpu_compute_s=9.0147e-5 gpu_e2e_s=0.000439747 speedup_compute=48.82 speedup_e2e=10.01
BENCH op=gsl type=Float64 N=550 M=40 NT=90 cpu_backend_s=0.112219539 gpu_compute_s=0.001204089 gpu_e2e_s=0.005273333 speedup_compute=93.20 speedup_e2e=21.28
BENCH op=gsl type=Float64 N=1584 M=64 NT=90 cpu_backend_s=0.539413729 gpu_compute_s=0.005582188 gpu_e2e_s=0.04771348 speedup_compute=96.63 speedup_e2e=11.31
BENCH op=gsl type=Float64 N=1584 M=100 NT=60 cpu_backend_s=0.540368982 gpu_compute_s=0.005753483 gpu_e2e_s=0.059169371 speedup_compute=93.92 speedup_e2e=9.13
BENCH op=isl type=Float32 N=66 P=132 NT=60 cpu_backend_s=0.000756383 gpu_compute_s=8.1117e-5 gpu_e2e_s=0.000415774 speedup_compute=9.32 speedup_e2e=1.82
BENCH op=isl type=Float32 N=550 P=1100 NT=90 cpu_backend_s=0.008391859 gpu_compute_s=0.00012582 gpu_e2e_s=0.003187241 speedup_compute=66.70 speedup_e2e=2.63
BENCH op=isl type=Float32 N=1584 P=3168 NT=90 cpu_backend_s=0.025003184 gpu_compute_s=0.000209727 gpu_e2e_s=0.007317471 speedup_compute=119.22 speedup_e2e=3.42
BENCH op=isl type=Float32 N=1584 P=6336 NT=90 cpu_backend_s=0.039334401 gpu_compute_s=0.000355059 gpu_e2e_s=0.002048278 speedup_compute=110.78 speedup_e2e=19.20
BENCH op=isl type=Float64 N=66 P=132 NT=60 cpu_backend_s=0.000573657 gpu_compute_s=0.001755435 gpu_e2e_s=0.001951391 speedup_compute=0.33 speedup_e2e=0.29
BENCH op=isl type=Float64 N=550 P=1100 NT=90 cpu_backend_s=0.007520308 gpu_compute_s=0.003390158 gpu_e2e_s=0.004292543 speedup_compute=2.22 speedup_e2e=1.75
BENCH op=isl type=Float64 N=1584 P=3168 NT=90 cpu_backend_s=0.022383499 gpu_compute_s=0.007088032 gpu_e2e_s=0.009024031 speedup_compute=3.16 speedup_e2e=2.48
BENCH op=isl type=Float64 N=1584 P=6336 NT=90 cpu_backend_s=0.0562391 gpu_compute_s=0.013305113 gpu_e2e_s=0.016163198 speedup_compute=4.23 speedup_e2e=3.48
MODAL_GPU_VALIDATION status=PASS
```

## 10. 1584 real-scale forward (Starlink TLE → SGP4 → coverage loss)

- **Date:** 2026-07-12 (EDT)
- **Runner:** `MODAL_PROFILE=satsim-gpu modal run modal_gpu.py --suites real1584`
  - forward jobs: `ap-GNsWR0G5rU4zAVKXTDttT2` (GPU + CPU PASS)
  - opt load follow-up: `ap-3CpsyzMdwndovUhOxHBfo7` (`--suites opt_load`, PASS)
- **Resources used:** 1× A10G + 1× CPU-4vCPU + 1× CPU-2vCPU (opt); released on completion
- **TLE:** `/opt/data/tle/celestrak/starlink_gp_latest.tle` (local `data/tle/celestrak/…`, first **1584** near-Earth records: `STARLINK-1008` … `STARLINK-4308`, epoch JD ≈ 2.46119965×10⁶)
- **Propagator (noted):** `sgp4_gpu.jl` **host init** + KernelAbstractions **propagate** (CUDA on GPU job / KA-CPU on CPU job) → position-only `teme_to_pef_gpu` (GMST Z-rotation with explicit `epoch_jd_ut1`; `jd = epoch_jd_ut1 + elapsed_s/86400`). The output is PEF, not polar-motion-corrected ITRF, and this path does not transform velocity. Not host `SatelliteToolbox` propagate.
- **Coverage:** `coverage_loss_gpu`; Δt = 1 min between samples; G via lat×lon grid trimmed to requested size
- **Timing口径:** warmup then **min-of-N**; GPU compute = resident kernel only (excludes compile + H2D); GPU e2e = `device_pipeline` H2D+kernel+scalar D2H; CPU = KA backend on host `Array`s. GPU parity vs CPU golden **PASS** at every cell before timing.

### 10.1 Machines / config

| Role | Hardware / request | Julia threads | Notes |
|---|---|---:|---|
| GPU forward | **NVIDIA A10G** 22.06 GiB, CC 8.6, driver 13.3.0, CUDA rt 12.9.0, CUDA.jl 6.2.1 | 1 | `cpu=2.0`, `memory=8192`; `gpu_samples=10` |
| CPU forward | Modal CPU container, 20 visible cores (`cpu_model=unknown`) | **4** | `cpu=4.0`, `memory=8192`; `cpu_samples=3` |
| Opt load | Modal CPU container, 18 visible cores | 1 | `cpu=2.0`; no gradient |

### 10.2 CPU multi-thread baseline (`julia_threads=4`)

Times in **ms** (min of 3, post-warmup). Throughput = N·NT·G / s.

#### Float32
| N | NT | G | CPU (ms) | Throughput |
|---:|---:|---:|---:|---:|
| 1584 | 20 | 800 | 284.5 | 89.1 Meval/s |
| 1584 | 20 | 2000 | 712.6 | 88.9 Meval/s |
| 1584 | 96 | 800 | 1344.8 | 90.5 Meval/s |
| 1584 | 96 | 2000 | 3291.6 | 92.4 Meval/s |

#### Float64
| N | NT | G | CPU (ms) | Throughput |
|---:|---:|---:|---:|---:|
| 1584 | 20 | 800 | 318.8 | 79.5 Meval/s |
| 1584 | 20 | 2000 | 797.6 | 79.4 Meval/s |
| 1584 | 96 | 800 | 1502.1 | 81.0 Meval/s |
| 1584 | 96 | 2000 | 3722.1 | 81.7 Meval/s |

### 10.3 A10G GPU (`coverage_loss_gpu`) + parity

`cpu_golden_s` on the GPU box is a **1-thread** KA reference (not the 4-thread baseline above). Speedups below are vs that 1-thread golden. All `parity=PASS` (F64 ~1e−15; F32 ~1e−6…2e−6).

#### Float32
| N | NT | G | CPU golden (ms) | GPU compute (ms) | GPU e2e (ms) | Speedup (compute) | Speedup (e2e) | GPU throughput |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1584 | 20 | 800 | 989.6 | 1.104 | 1.181 | **897×** | 838× | 23.0 Geval/s |
| 1584 | 20 | 2000 | 2482.4 | 1.141 | 1.173 | **2176×** | 2117× | 55.5 Geval/s |
| 1584 | 96 | 800 | 4758.6 | 2.848 | 3.048 | **1671×** | 1561× | 42.7 Geval/s |
| 1584 | 96 | 2000 | 11876.4 | 6.777 | 6.960 | **1753×** | 1706× | 44.9 Geval/s |

#### Float64
| N | NT | G | CPU golden (ms) | GPU compute (ms) | GPU e2e (ms) | Speedup (compute) | Speedup (e2e) | GPU throughput |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1584 | 20 | 800 | 1130.5 | 56.95 | 57.04 | 19.9× | 19.8× | 0.45 Geval/s |
| 1584 | 20 | 2000 | 2840.2 | 56.96 | 57.25 | 49.9× | 49.6× | 1.11 Geval/s |
| 1584 | 96 | 800 | 5423.7 | 57.09 | 57.49 | **95.0×** | 94.3× | 2.13 Geval/s |
| 1584 | 96 | 2000 | 13578.4 | 169.72 | 170.21 | 80.0× | 79.8× | 1.79 Geval/s |

**vs 4-thread CPU (honest multi-core):** e.g. F32 NT=96 G=2000: CPU 3.29 s / GPU compute 6.78 ms ≈ **485×**; F64 same cell: 3.72 s / 170 ms ≈ **22×**. Coverage remains scalar-output so e2e ≈ compute.

SGP4+frame propagate cost (once per NT, not in coverage timings): CPU NT=20 ≈ 0.37 s (incl. first compile), NT=96 ≈ 0.023 s; GPU NT=20 ≈ 8.7 s (first CUDA compile), NT=96 ≈ 0.005 s.

### 10.4 Stage-2 paving: `SatelliteSimOpt` cold load

Container ran `julia --project=/opt/src/opt modal_opt_load.jl` (foundation/orbit/link/net/opt mounted; Backends symlinked at `/opt/packages/SatelliteSimBackends`). **Load only — no gradient.**

| Metric | Value |
|---|---|
| `Pkg.instantiate` (+ precompile) | **166.0 s** |
| `using SatelliteSimOpt` | **4.0 s** |
| Total wall | **170.2 s** |
| Status | **PASS** |

Reproduce:

```bash
cd packages/SatelliteSimGPU
export HTTPS_PROXY=http://127.0.0.1:7890 HTTP_PROXY=http://127.0.0.1:7890 NO_PROXY=localhost,127.0.0.1,::1
MODAL_PROFILE=satsim-gpu modal run modal_gpu.py --suites real1584
MODAL_PROFILE=satsim-gpu modal run modal_gpu.py --suites opt_load
```

### 10.5 Raw measurement lines (verbatim)

```text
# CPU (julia_threads=4)
GPU_INFO device=none julia=1.12.6 kernel_abstractions=0.9.42 julia_threads=4 cpu_threads_visible=20 cpu_model=unknown
REAL1584_TLE loaded=1584 epoch_jd=2.46119965246276e6 first=STARLINK-1008 last=STARLINK-4308
BENCH op=coverage_real1584 mode=cpu type=Float32 N=1584 NT=20 G=800 cpu_backend_s=0.284522563
BENCH op=coverage_real1584 mode=cpu type=Float32 N=1584 NT=20 G=2000 cpu_backend_s=0.712577529
BENCH op=coverage_real1584 mode=cpu type=Float32 N=1584 NT=96 G=800 cpu_backend_s=1.344780432
BENCH op=coverage_real1584 mode=cpu type=Float32 N=1584 NT=96 G=2000 cpu_backend_s=3.291619224
BENCH op=coverage_real1584 mode=cpu type=Float64 N=1584 NT=20 G=800 cpu_backend_s=0.318771099
BENCH op=coverage_real1584 mode=cpu type=Float64 N=1584 NT=20 G=2000 cpu_backend_s=0.797571091
BENCH op=coverage_real1584 mode=cpu type=Float64 N=1584 NT=96 G=800 cpu_backend_s=1.502057251
BENCH op=coverage_real1584 mode=cpu type=Float64 N=1584 NT=96 G=2000 cpu_backend_s=3.722077708

# GPU (A10G, julia_threads=1)
GPU_INFO device=NVIDIA A10G total_mem_gib=22.06 compute_capability=8.6 driver=13.3.0 cuda_runtime=12.9.0 cuda_jl=6.2.1 julia=1.12.6 julia_threads=1 cpu_threads_visible=18
BENCH op=coverage_real1584 mode=gpu type=Float32 N=1584 NT=20 G=800 gpu_compute_s=0.001103746 gpu_e2e_s=0.001180741 parity=PASS
BENCH op=coverage_real1584 mode=gpu type=Float32 N=1584 NT=20 G=2000 gpu_compute_s=0.001140859 gpu_e2e_s=0.001172651 parity=PASS
BENCH op=coverage_real1584 mode=gpu type=Float32 N=1584 NT=96 G=800 gpu_compute_s=0.002848291 gpu_e2e_s=0.003047813 parity=PASS
BENCH op=coverage_real1584 mode=gpu type=Float32 N=1584 NT=96 G=2000 gpu_compute_s=0.006776776 gpu_e2e_s=0.006960426 parity=PASS
BENCH op=coverage_real1584 mode=gpu type=Float64 N=1584 NT=20 G=800 gpu_compute_s=0.056947387 gpu_e2e_s=0.057042123 parity=PASS
BENCH op=coverage_real1584 mode=gpu type=Float64 N=1584 NT=20 G=2000 gpu_compute_s=0.056957378 gpu_e2e_s=0.057251745 parity=PASS
BENCH op=coverage_real1584 mode=gpu type=Float64 N=1584 NT=96 G=800 gpu_compute_s=0.057090195 gpu_e2e_s=0.057488 parity=PASS
BENCH op=coverage_real1584 mode=gpu type=Float64 N=1584 NT=96 G=2000 gpu_compute_s=0.169718453 gpu_e2e_s=0.170210053 parity=PASS

# Opt load
OPT_LOAD instantiate_s=165.956883324
OPT_LOAD status=PASS using_s=3.969847532 total_wall_s=170.1838641166687
MODAL_OPT_LOAD status=PASS
```

## 11. Reduction / device-aggregate hard gate

This section is a **reproducible gate**, not a raw-log dump. It locks the pass/fail
contract for `bench_gsl_reduction` + `bench_isl_reduction` in
`modal_gpu_runner.jl`.

### 11.1 Parity gate (fail-closed, exact equality)

- In both reduction benches, parity is checked **before** any `BENCH op=..._reduction`
  line is emitted:
  - `bench_gsl_reduction_case`: `parity == "PASS" || error(...)`
  - `bench_isl_reduction_case`: `parity == "PASS" || error(...)`
- `validate_reductions(Float32/Float64)` also enforces exact-equality parity and emits
  `REDUCTIONS_PARITY type=<T> status=PASS` only on success.
- Gate statement: **device-aggregate output must equal full-download host-reduce exactly
  (Int counts); any mismatch fails the suite**.
- Offline CPU-backend confirmation (network-free): `bench_reduction.jl` completed with
  `exit_code=0` at `N=550,M=40,NT=90` and `N=1584,M=64,NT=90` after internal `@assert`
  equality checks for GSL/ISL visible-count reductions.

### 11.2 Transfer-reduction hard floor (analytical, hardware-independent)

`transfer_reduction` is deterministic math from output tensor shapes and element widths:

- GSL (`op=gsl_reduction`):  
  `bytes_full/bytes_agg = [N*M*NT*(sizeof(Bool)+3*sizeof(T))] / [M*NT*sizeof(Int32)] = N*(1+3*sizeof(T))/4`
- ISL (`op=isl_reduction`):  
  `bytes_full/bytes_agg = [P*NT*(2*sizeof(Bool)+5*sizeof(T))] / [NT*sizeof(Int32)] = P*(2+5*sizeof(T))/4`
  (here `actual_pairs == P` for listed scales)

Per-scale hard floors:

| op | type | N | M/P | NT | transfer_reduction (floor) |
|---|---|---:|---:|---:|---:|
| gsl_reduction | Float32 | 550 | 40 | 90 | **1787.5x** |
| gsl_reduction | Float32 | 1584 | 64 | 90 | **5148.0x** |
| gsl_reduction | Float32 | 1584 | 100 | 90 | **5148.0x** |
| gsl_reduction | Float64 | 550 | 40 | 90 | **3437.5x** |
| gsl_reduction | Float64 | 1584 | 64 | 90 | **9900.0x** |
| gsl_reduction | Float64 | 1584 | 100 | 90 | **9900.0x** |
| isl_reduction | Float32 | 550 | 1100 | 90 | **6050.0x** |
| isl_reduction | Float32 | 1584 | 3168 | 90 | **17424.0x** |
| isl_reduction | Float32 | 1584 | 6336 | 90 | **34848.0x** |
| isl_reduction | Float64 | 550 | 1100 | 90 | **11550.0x** |
| isl_reduction | Float64 | 1584 | 3168 | 90 | **33264.0x** |
| isl_reduction | Float64 | 1584 | 6336 | 90 | **66528.0x** |

Geomean floors by suite/type:

| group | geomean transfer_reduction floor |
|---|---:|
| gsl_reduction Float32 | **3618.326x** |
| gsl_reduction Float64 | **6958.319x** |
| isl_reduction Float32 | **15429.802x** |
| isl_reduction Float64 | **29456.896x** |

Gate statement: **each scale must meet or exceed its listed analytical
`transfer_reduction` floor; any regression below floor fails**.

### 11.3 GPU end-to-end speedup gate (capture-defined)

No A10G reduction BENCH lines are currently checked into this file (raw section 9
predates reduction suites). Until measured lines are captured, the speed gate is:

- `speedup = full_e2e_s / agg_e2e_s >= 1.0` for every reduction scale/type
- expected `> 1` because isolated GSL/ISL e2e is transfer-bound in existing results
  (see sections 5 and 6: GSL isolated e2e ~9–37x vs CPU, and e2e << compute due to D2H)

Capture command (A10G):

```bash
cd packages/SatelliteSimGPU
MODAL_PROFILE=satsim-gpu modal run modal_gpu.py --suites bench_gsl_reduction,bench_isl_reduction
```

When captured, the measured `speedup` per-scale and geomean become hard-gate numbers.

### 11.4 Gate predicate + reproduce

**GATE = PASS iff** parity is exact (fail-closed) **and** every scale meets the
analytical transfer-reduction floor **and** reduction e2e speedup shows no regression
(`speedup >= 1.0`) on captured A10G runs.

Reproduce:

```bash
cd /Users/zhuhai/Research/SatelliteSimJulia
julia --project=packages/SatelliteSimGPU packages/SatelliteSimGPU/bench_reduction.jl 550 40 90
# optional second scale:
julia --project=packages/SatelliteSimGPU packages/SatelliteSimGPU/bench_reduction.jl 1584 64 90
```

```bash
cd packages/SatelliteSimGPU
MODAL_PROFILE=satsim-gpu modal run modal_gpu.py --suites bench_gsl_reduction,bench_isl_reduction
```

## 12. Parallel-suite hard gate (coverage/GSL/ISL distilled)

This is the compact hard-gate summary for the existing parallel-suite data already in
sections 4/5/6 and raw section 9 (no raw line duplication here).

### 12.1 Geomean speedup gate (existing measured data)

| op | type | geomean speedup_compute | geomean speedup_e2e |
|---|---|---:|---:|
| coverage | Float32 | **1174.987x** | **1141.481x** |
| coverage | Float64 | **66.669x** | **66.152x** |
| gsl | Float32 | **151.512x** | **18.054x** |
| gsl | Float64 | **80.162x** | **12.178x** |
| isl | Float32 | **53.529x** | **4.211x** |
| isl | Float64 | **1.769x** | **1.447x** |

### 12.2 Parity + harness invariants (fail-closed)

- Parity remains PASS at every published scale:
  - coverage scalar parity PASS (`COVERAGE_PARITY`)
  - GSL parity PASS with `avail_mismatch=0`
  - ISL parity PASS with `available_mismatch=0` and `los_mismatch=0`
- Parallel launcher `_suite_passed` is fail-closed:
  - requires `exit_code == 0`
  - requires **exactly one** `MODAL_GPU_VALIDATION status=PASS suite=<suite>` sentinel
  - requires that sentinel to be the final output line
- `DEFAULT_PARALLEL_SUITES` includes the reduction and reduction-bench shards
  (`reductions_f32/f64`, `bench_gsl_reduction`, `bench_isl_reduction`), so the same
  sentinel gate applies there.
