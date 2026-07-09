#!/usr/bin/env julia
# satnet-run.jl — 容器内仿真执行入口
#
# 从 MinIO 下载实验配置 → 反序列化为 ExperimentConfig → 跑仿真 → 上传结果
#
# 用法：
#   julia --project=platform/runner platform/runner/bin/satnet-run.jl \
#     --config-s3 s3://configs/<exp_id>/config.json \
#     --output-s3 s3://results/<job_id>/
#
# 环境变量：DATABASE_URL, MINIO_ENDPOINT, MINIO_ACCESS_KEY, MINIO_SECRET_KEY,
#          MINIO_BUCKET_CONFIGS, MINIO_BUCKET_RESULTS
# 退出码：0=成功, 1=配置错误, 2=仿真错误, 3=上传错误

using Dates
using JSON
using JLD2
using SHA
using SatelliteSimJulia        # SatelliteSimLab / SatelliteSimCore 在此
using Storage                  # db + s3 封装

const DEFAULT_TSPAN = [0.0, 3600.0]
const DEFAULT_STEPS = 30
const SUPPORTED_TOPOLOGY_STRATEGIES = Set(["low_latency", "high_robust", "balanced", "low_cost"])
const LEGACY_TOPOLOGY_ALIASES = Dict(
    "mesh" => "balanced",
    "gridplus" => "balanced",
    "grid_plus" => "balanced",
)

function _normalize_topology_strategy(value)::Symbol
    name = lowercase(String(value))
    name = get(LEGACY_TOPOLOGY_ALIASES, name, name)
    name in SUPPORTED_TOPOLOGY_STRATEGIES || error(
        "unsupported topology_strategy: $(value) (use one of $(join(sort(collect(SUPPORTED_TOPOLOGY_STRATEGIES)), ", ")))"
    )
    return Symbol(name)
end

# ── 参数解析（最小实现，不依赖 Comonicon，保持容器内零依赖） ──
function parse_args(args::Vector{String})
    cfg = (; config_s3 = "", output_s3 = "")
    i = 1
    while i <= length(args)
        a = args[i]
        if a == "--config-s3" && i + 1 <= length(args)
            cfg = (; config_s3 = args[i + 1], output_s3 = cfg.output_s3)
            i += 2
        elseif a == "--output-s3" && i + 1 <= length(args)
            cfg = (; config_s3 = cfg.config_s3, output_s3 = args[i + 1])
            i += 2
        else
            println(stderr, "unknown arg: $a")
            exit(1)
        end
    end
    isempty(cfg.config_s3) && (println(stderr, "missing --config-s3"); exit(1))
    isempty(cfg.output_s3) && (println(stderr, "missing --output-s3"); exit(1))
    return cfg
end

# ── 配置反序列化：JSON Dict → ExperimentConfig 关键字参数 ──
# JSON schema（platform/README.md §3）：
#   name, constellation, propagator, tspan, steps, topology_strategy,
#   routing_algorithm, traffic, ground_pairs
function build_config(d::Dict)
    kwargs = Dict{Symbol,Any}()

    haskey(d, "name")          && (kwargs[:name] = String(d["name"]))
    haskey(d, "constellation") && (kwargs[:constellation] = Symbol(String(d["constellation"])))
    haskey(d, "propagator")    && (kwargs[:propagator] = Symbol(String(d["propagator"])))

    # tspan：schema 允许 [起, 止] 或省略
    if haskey(d, "tspan")
        tspan = Float64.(d["tspan"])
        steps = haskey(d, "steps") ? Int(d["steps"]) : DEFAULT_STEPS
        kwargs[:tspan] = collect(range(tspan[1], tspan[2]; length = steps))
    else
        kwargs[:tspan] = collect(range(DEFAULT_TSPAN[1], DEFAULT_TSPAN[2];
                                       length = DEFAULT_STEPS))
    end

    haskey(d, "topology_strategy") &&
        (kwargs[:topology_strategy] = _normalize_topology_strategy(d["topology_strategy"]))
    haskey(d, "routing_algorithm") &&
        (kwargs[:routing_algorithm] = Symbol(String(d["routing_algorithm"])))
    haskey(d, "traffic") &&
        (kwargs[:traffic] = Symbol(String(d["traffic"])))

    if haskey(d, "ground_pairs")
        gp = d["ground_pairs"]
        kwargs[:ground_pairs] = Tuple{Int,Int}[(Int(p[1]), Int(p[2])) for p in gp]
    end

    return SatelliteSimLab.ExperimentConfig(; kwargs...)
end

# ── ExperimentResult → JSON Dict（只取可序列化的摘要字段） ──
_json_number(x) = isfinite(Float64(x)) ? Float64(x) : 0.0

function result_to_dict(r::SatelliteSimLab.ExperimentResult)
    return Dict(
        "coverage_ratio"     => _json_number(r.coverage.coverage_ratio),
        "avg_latency_ms"     => _json_number(r.latency.avg_latency_ms),
        "connectivity"       => _json_number(r.network.connectivity_ratio),
        "fitness"            => _json_number(r.fitness),
        "duration_s"         => _json_number(r.duration_s),
    )
end

function _write_json(path::AbstractString, data)
    open(path, "w") do io
        JSON.print(io, data, 2)
    end
    return path
end

function _content_type(name::AbstractString)::String
    endswith(name, ".json") && return "application/json"
    endswith(name, ".txt") && return "text/plain"
    endswith(name, ".md") && return "text/markdown"
    endswith(name, ".csv") && return "text/csv"
    return "application/octet-stream"
end

function _artifact_role(name::AbstractString)::String
    name == "result.json" && return "metrics_summary"
    name == "config.snapshot.json" && return "config_snapshot"
    name == "run_metadata.json" && return "run_metadata"
    return "artifact"
end

function _artifact_record(path::AbstractString, name::AbstractString)
    data = read(path)
    return Dict(
        "path" => String(name),
        "role" => _artifact_role(name),
        "content_type" => _content_type(name),
        "bytes" => length(data),
        "sha256" => bytes2hex(sha256(data)),
    )
end

function write_artifact_bundle!(out_dir::AbstractString, cfg_dict::Dict, result_dict::Dict,
                                args, started_at::DateTime, finished_at::DateTime)
    config_path = _write_json(joinpath(out_dir, "config.snapshot.json"), cfg_dict)
    config_sha = bytes2hex(sha256(read(config_path)))

    _write_json(joinpath(out_dir, "result.json"), result_dict)
    _write_json(joinpath(out_dir, "run_metadata.json"), Dict(
        "schema_version" => "1",
        "status" => "succeeded",
        "started_at" => string(started_at),
        "finished_at" => string(finished_at),
        "duration_s" => Dates.value(finished_at - started_at) / 1000,
        "config_s3" => args.config_s3,
        "output_s3" => args.output_s3,
        "config_sha256" => config_sha,
        "julia" => Dict(
            "version" => string(VERSION),
            "project" => get(ENV, "JULIA_PROJECT", ""),
        ),
        "container" => Dict(
            "hostname" => get(ENV, "HOSTNAME", ""),
            "image" => get(ENV, "SATNET_RUNNER_IMAGE", nothing),
            "image_digest" => get(ENV, "SATNET_IMAGE_DIGEST", nothing),
        ),
        "runner" => "satnet-run.jl",
    ))

    artifact_names = ["result.json", "config.snapshot.json", "run_metadata.json"]
    artifacts = [_artifact_record(joinpath(out_dir, name), name) for name in artifact_names]
    _write_json(joinpath(out_dir, "artifacts.index.json"), Dict(
        "schema_version" => "1",
        "generated_at" => string(now()),
        "files" => artifacts,
    ))
    return out_dir
end

# ── 主流程 ──
function main()
    args = parse_args(ARGS)

    started_at = now()

    println("[runner] downloading config: $(args.config_s3)")
    cfg_dict = Storage.download_config(args.config_s3)

    println("[runner] building ExperimentConfig...")
    config = try
        build_config(cfg_dict)
    catch e
        println(stderr, "[runner] config build failed: ", e)
        exit(1)
    end

    println("[runner] running simulation...")
    result = try
        SatelliteSimLab.run_experiment(config)
    catch e
        println(stderr, "[runner] simulation failed: ", e)
        exit(2)
    end

    # 写到临时目录，再上传整个目录到 MinIO
    out_dir = mktempdir()
    result_dict = result_to_dict(result)
    write_artifact_bundle!(out_dir, cfg_dict, result_dict, args, started_at, now())

    # positions.jld2：完整位置数组（仿真内部产物，目前 run_experiment 不返回）
    # viz.czml：可视化文件（可选，M3+ 阶段补）

    println("[runner] uploading results to $(args.output_s3)")
    try
        Storage.upload_result_prefix(out_dir, args.output_s3)
    catch e
        println(stderr, "[runner] upload failed: ", e)
        exit(3)
    end

    println("[runner] done.")
end

if basename(PROGRAM_FILE) == "satnet-run.jl"
    main()
end
