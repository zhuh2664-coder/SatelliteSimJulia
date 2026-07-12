# 数据驻留策略（device residency）
#
# 现状：契约算子 evaluate_gsl_series(::KernelComputeBackend, ...) 是"host 进 host 出"，
# 每次调用都 H2D→算→D2H。对单个算子没问题；但把多个算子串成管线
# （orbit→link→coverage）时，每步都回 host 会把加速吃光。
#
# 本文件提供"上传一次 → 设备上算多步 → 下载一次"的驻留策略：
#   - 底层核 evaluate_gsl_batch_gpu / evaluate_isl_batch_gpu 本身就是设备原生的
#     （用 get_backend(positions) + similar(positions,...)）：传入设备数组即得设备数组，
#     中途不回 host。
#   - to_device / to_host / device_pipeline 把"只在两端各传输一次"变成一等、可测的模式。

export to_device, to_host, device_pipeline

"""
    to_device(backend, x) -> array

把 host 数组上传到给定后端的设备（CPU 后端为恒等/普通数组）。`backend` 可以是
`KernelAbstractions.Backend`（如 `CPU()`、`CUDABackend()`）或 `KernelComputeBackend`。
"""
to_device(backend::KernelAbstractions.Backend, x) = adapt(backend, x)
to_device(backend::KernelComputeBackend, x) = adapt(backend.backend, x)

"""
    to_host(x) -> Array

把（可能驻留在设备上的）数组取回 host 内存。
"""
to_host(x) = adapt(Array, x)

# 递归下载：数组直接下载；NamedTuple/Tuple 逐字段下载；其它原样返回。
_download_result(x::AbstractArray) = to_host(x)
_download_result(x::NamedTuple) = map(_download_result, x)
_download_result(x::Tuple) = map(_download_result, x)
_download_result(x) = x

"""
    device_pipeline(f, backend, host_arrays...) -> 下载回 host 的 f 结果

数据驻留策略入口：把 `host_arrays` 一次性上传到 `backend` 的设备，调用
`f(device_arrays...)`（其中应只用设备原生核 `evaluate_*_gpu`，中途不回 host），
最后把 `f` 的返回值（数组 / NamedTuple / Tuple 递归）一次性下载回 host。

```julia
out = device_pipeline(CPU(), positions, velocities) do pos_d, vel_d
    gsl = evaluate_gsl_batch_gpu(pos_d, ground_ecef_d, ned_d; ...)
    isl = evaluate_isl_batch_gpu(pos_d, pairs; velocities=vel_d)
    (gsl = gsl, isl = isl)
end
```
"""
function device_pipeline(f, backend, host_arrays...)
    device_arrays = map(x -> to_device(backend, x), host_arrays)
    result = f(device_arrays...)
    return _download_result(result)
end
