# ===== 实验缓存 + 结果对比 API =====
# P2: produce_or_load（借鉴 DrWatson）
# P3: compare_results（通用对比）

using Printf
using Serialization
using SHA: sha256

export cached_experiment, compare_results

# ────────────────────────────────────────────────────────────
# P2: 实验缓存
# ────────────────────────────────────────────────────────────

_cache_dir() = joinpath("data", "cache")
const _CACHE_ENVELOPE_MAGIC = "SatelliteSimLab.ExperimentResult"
const _CACHE_ENVELOPE_VERSION = 1
const _CACHE_EXTENSION = ".bin"

"""
    config_hash(config) -> String

根据 ExperimentConfig 生成唯一 hash（用于缓存文件名）。
"""
function _backend_package_version(backend)::String
    return try
        version = Base.pkgversion(parentmodule(typeof(backend)))
        version === nothing ? "unknown" : string(version)
    catch
        "unknown"
    end
end

function _module_source_files(module_)::Vector{String}
    entrypoint = try
        pathof(module_)
    catch
        nothing
    end
    entrypoint === nothing && return String[]
    source_root = dirname(entrypoint)
    files = String[]
    for (root, _, names) in walkdir(source_root)
        append!(
            files,
            joinpath(root, name) for name in names if endswith(name, ".jl"),
        )
    end
    project = joinpath(dirname(source_root), "Project.toml")
    isfile(project) && push!(files, project)
    return sort!(unique!(files))
end

function _source_files_fingerprint(files)::String
    existing = sort!(unique!(String[file for file in files if isfile(file)]))
    isempty(existing) && return "unavailable"
    payload = UInt8[]
    for (index, file) in enumerate(existing)
        append!(payload, codeunits("file[$index]:$(basename(file))\n"))
        append!(payload, read(file))
        push!(payload, 0x00)
    end
    return bytes2hex(sha256(payload))
end

function _active_environment_fingerprint()::String
    project = Base.active_project()
    project === nothing && return "unknown"
    manifest = joinpath(dirname(project), "Manifest.toml")
    return _source_files_fingerprint(
        isfile(manifest) ? (project, manifest) : (project,),
    )
end

function _local_simulation_source_files()::Vector{String}
    repository_root = normpath(joinpath(@__DIR__, "..", "..", "..", "..", ".."))
    files = String[]
    for source_root in (
        joinpath(repository_root, "src"),
        joinpath(repository_root, "packages"),
    )
        isdir(source_root) || continue
        for (root, _, names) in walkdir(source_root)
            append!(
                files,
                joinpath(root, name) for name in names
                if endswith(name, ".jl") || name == "Project.toml",
            )
        end
    end
    return sort!(unique!(files))
end

function _orbit_backend_fingerprint(config::ExperimentConfig)
    if config.orbit_backend === nothing
        return (
            name=:native,
            implementation_module="SatelliteSimOrbit",
            implementation_version=string(Base.pkgversion(SatelliteSimOrbit)),
            source_sha256=_source_files_fingerprint(
                _module_source_files(SatelliteSimOrbit),
            ),
        )
    end
    backend = create_orbit_backend(config.orbit_backend)
    module_ = parentmodule(typeof(backend))
    return (
        name=backend_name(backend),
        type=string(typeof(backend)),
        version=_backend_package_version(backend),
        capabilities=backend_capabilities(backend),
        source_sha256=_source_files_fingerprint(_module_source_files(module_)),
    )
end

function _gsl_backend_fingerprint(backend::ResolvedComputeBackend)
    cache_token = compute_backend_cache_token(backend)
    cache_token === nothing &&
        throw(ArgumentError(
            "compute backend '$(compute_backend_name(backend))' does not define " *
            "a deterministic cache token and cannot be used with cached_experiment",
        ))
    source_files = compute_backend_source_files(backend)
    return merge(
        compute_backend_fingerprint(backend),
        (
            cache_token=cache_token,
            source_sha256=_source_files_fingerprint(source_files),
        ),
    )
end

function config_hash(
    config::ExperimentConfig;
    gsl_resolution::Union{Nothing,ResolvedComputeBackend}=nothing,
)::String
    # ExperimentConfig contains only deterministic value objects. Hashing its
    # full representation avoids collisions from omitted thresholds, endpoint
    # coordinates, time samples, demands, and backend options.
    resolution = gsl_resolution === nothing ?
        _resolve_experiment_gsl_backend(config) :
        gsl_resolution
    gsl_backend = _backend_from_resolution(config, resolution)
    payload = (
        config=config,
        orbit_backend=_orbit_backend_fingerprint(config),
        gsl_backend=_gsl_backend_fingerprint(gsl_backend),
        environment_sha256=_active_environment_fingerprint(),
        simulation_source_sha256=_source_files_fingerprint(
            _local_simulation_source_files(),
        ),
    )
    return bytes2hex(sha256(repr(payload)))
end

"""
    cached_experiment(config; force=false) -> ExperimentResult

带缓存的实验执行。相同参数的实验只跑一次。

```julia
# 第一次：跑仿真 + 缓存
result = cached_experiment(config)
# 第二次：从缓存读（秒级返回）
result2 = cached_experiment(config)
# 强制重跑
result3 = cached_experiment(config; force=true)
```
"""
_cache_path(hash::AbstractString) =
    joinpath(_cache_dir(), string(hash, _CACHE_EXTENSION))

function _atomic_write(writer::Function, path::AbstractString)
    directory = dirname(path)
    mkpath(directory)
    temp_path, io = mktemp(directory)
    try
        writer(io)
        flush(io)
        close(io)
        Base.Filesystem.rename(temp_path, path)
    catch
        isopen(io) && close(io)
        isfile(temp_path) && rm(temp_path; force=true)
        rethrow()
    end
    return path
end

function _serialize_result(result::ExperimentResult)::Vector{UInt8}
    io = IOBuffer()
    Serialization.serialize(io, result)
    return take!(io)
end

function _write_cached_result(path::AbstractString, result::ExperimentResult)
    payload = _serialize_result(result)
    envelope = (
        magic=_CACHE_ENVELOPE_MAGIC,
        version=_CACHE_ENVELOPE_VERSION,
        payload_sha256=sha256(payload),
        payload=payload,
    )
    return _atomic_write(path) do io
        Serialization.serialize(io, envelope)
    end
end

function _decode_cache_envelope(envelope)::ExperimentResult
    envelope isa NamedTuple ||
        throw(ArgumentError("cache envelope must be a NamedTuple"))
    for field in (:magic, :version, :payload_sha256, :payload)
        hasproperty(envelope, field) ||
            throw(ArgumentError("cache envelope is missing field '$field'"))
    end
    envelope.magic == _CACHE_ENVELOPE_MAGIC ||
        throw(ArgumentError("cache envelope magic mismatch"))
    envelope.version == _CACHE_ENVELOPE_VERSION ||
        throw(ArgumentError("unsupported cache envelope version $(envelope.version)"))
    envelope.payload isa Vector{UInt8} ||
        throw(ArgumentError("cache payload must be a byte vector"))
    envelope.payload_sha256 isa Vector{UInt8} ||
        throw(ArgumentError("cache checksum must be a byte vector"))
    envelope.payload_sha256 == sha256(envelope.payload) ||
        throw(ArgumentError("cache payload checksum mismatch"))

    payload_io = IOBuffer(envelope.payload)
    result = Serialization.deserialize(payload_io)
    eof(payload_io) ||
        throw(ArgumentError("cache payload contains trailing data"))
    result isa ExperimentResult ||
        throw(ArgumentError("cache payload is not an ExperimentResult"))
    return result
end

function _read_cached_result(path::AbstractString)::Union{Nothing,ExperimentResult}
    try
        return open(path, "r") do io
            envelope = Serialization.deserialize(io)
            eof(io) ||
                throw(ArgumentError("cache envelope contains trailing data"))
            _decode_cache_envelope(envelope)
        end
    catch err
        @warn "Ignoring invalid experiment cache entry; treating as miss" path exception=(err, catch_backtrace())
        return nothing
    end
end

function cached_experiment(
    config::ExperimentConfig;
    force::Bool=false,
)::ExperimentResult
    mkpath(_cache_dir())
    gsl_resolution = _resolve_experiment_gsl_backend(config)
    h = config_hash(config; gsl_resolution=gsl_resolution)
    path = _cache_path(h)

    # 缓存命中
    if !force && isfile(path)
        cached = _read_cached_result(path)
        if cached !== nothing
            @printf("[Cache] 命中: %s\n", path)
            return cached
        end
    end

    # 缓存未命中：跑实验
    @printf("[Cache] 未命中，执行仿真...\n")
    result = _run_experiment(config, gsl_resolution)

    # 保存到缓存
    _write_cached_result(path, result)

    return result
end

# ────────────────────────────────────────────────────────────
# P3: 结果对比 API
# ────────────────────────────────────────────────────────────

"""
    compare_results(results::Dict{String,<:Any}) -> String

对比多个实验结果，返回 Markdown 格式对比表。

```julia
# 跑 3 个星座
r1 = cached_experiment(ExperimentConfig(name="iridium", constellation_params=Dict(:T=>66.0,:P=>6.0,:F=>2.0,:alt_km=>780.0,:inc_deg=>86.4), tspan=[0.0,60.0]))
r2 = cached_experiment(ExperimentConfig(name="starlink", constellation_params=Dict(:T=>158.0,:P=>72.0,:F=>1.0,:alt_km=>550.0,:inc_deg=>53.0), tspan=[0.0,60.0]))
# 对比
compare_results(Dict("Iridium" => r1, "Starlink" => r2))
```
"""
function compare_results(results::Dict{String,<:Any})::String
    isempty(results) && return "无结果可对比"

    # 统一提取指标（兼容 ExperimentResult 和 Dict）
    function get_metric(r, key, default=0.0)
        if r isa ExperimentResult
            key == :coverage && return isnan(r.coverage.coverage_ratio) ? 0.0 : r.coverage.coverage_ratio
            key == :avg_latency && return r.latency.avg_latency_ms
            key == :max_latency && return r.latency.max_latency_ms
            key == :p95 && return r.latency.p95_ms
            key == :connectivity && return r.network.connectivity_ratio
            key == :diameter && return r.network.diameter
            key == :fitness && return r.fitness
        elseif r isa AbstractDict
            # 缓存的 Dict 用不同 key 名
            key_map = Dict(:coverage => "coverage_ratio", :avg_latency => "avg_latency_ms",
                          :max_latency => "max_latency_ms", :p95 => "p95_latency_ms",
                          :connectivity => "connectivity_ratio", :diameter => "diameter_ms",
                          :fitness => "fitness")
            return get(r, get(key_map, key, string(key)), default)
        end
        return default
    end

    lines = String[]
    push!(lines, "| 星座 | 覆盖率 | avg时延(ms) | p95时延(ms) | 连通率 | 直径(ms) | fitness |")
    push!(lines, "|------|--------|-------------|-------------|--------|----------|---------|")

    for (name, r) in results
        @printf("| %-12s | %.1f%% | %11.1f | %11.1f | %6.1f%% | %8.1f | %7.3f |\n",
            name,
            get_metric(r, :coverage) * 100,
            get_metric(r, :avg_latency),
            get_metric(r, :p95),
            get_metric(r, :connectivity) * 100,
            get_metric(r, :diameter),
            get_metric(r, :fitness),
        )
        push!(lines, @sprintf("| %-12s | %.1f%% | %11.1f | %11.1f | %6.1f%% | %8.1f | %7.3f |",
            name,
            get_metric(r, :coverage) * 100,
            get_metric(r, :avg_latency),
            get_metric(r, :p95),
            get_metric(r, :connectivity) * 100,
            get_metric(r, :diameter),
            get_metric(r, :fitness),
        ))
    end

    table = join(lines, "\n")
    println("\n", table)
    return table
end
