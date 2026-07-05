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
using SatelliteSimJulia        # SatelliteSimLab / SatelliteSimCore 在此
using Storage                  # db + s3 封装

const DEFAULT_TSPAN = [0.0, 3600.0]
const DEFAULT_STEPS = 30

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
        (kwargs[:topology_strategy] = Symbol(String(d["topology_strategy"])))
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
function result_to_dict(r::SatelliteSimLab.ExperimentResult)
    return Dict(
        "coverage_ratio"     => Float64(r.coverage.coverage_ratio),
        "avg_latency_ms"     => Float64(r.latency.avg_latency_ms),
        "connectivity"       => Float64(r.network.connectivity_ratio),
        "fitness"            => Float64(r.fitness),
        "duration_s"         => Float64(r.duration_s),
    )
end

# ── 主流程 ──
function main()
    args = parse_args(ARGS)

    println("[runner] connecting to storage...")
    Storage.connect()

    println("[runner] downloading config: $(args.config_s3)")
    cfg_dict = Storage.download_config(args.config_s3)

    println("[runner] building ExperimentConfig...")
    try
        config = build_config(cfg_dict)
    catch e
        println(stderr, "[runner] config build failed: ", e)
        exit(1)
    end

    println("[runner] running simulation...")
    try
        result = SatelliteSimLab.run_experiment(config)
    catch e
        println(stderr, "[runner] simulation failed: ", e)
        exit(2)
    end

    # 写到临时目录，再上传整个目录到 MinIO
    out_dir = mktempdir()
    open(joinpath(out_dir, "result.json"), "w") do io
        JSON.print(io, result_to_dict(result), 2)
    end

    # positions.jld2：完整位置数组（仿真内部产物，目前 run_experiment 不返回）
    # viz.czml：可视化文件（可选，M3+ 阶段补）
    # 第一期仅产出 result.json

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
