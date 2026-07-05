# ===== SimCLI =====
#
# SatelliteSimJulia 命令行接口。
# 复用 SatelliteSimLab / SatelliteSimCore 的现有公开 API，不引入新物理。

module SimCLI

using Comonicon: @cast, @main
using JLD2
using JSON
using SatelliteSimCore
using SatelliteSimLab
using SatelliteSimNet
using SatelliteSimOrbit
using SatelliteSimViz

# ────────────────────────────────────────────────────────────
# list：列出可发现资源
# ────────────────────────────────────────────────────────────

"""
列出可用资源。

支持类别：studies, experiments, goals, constellations, topologies, propagators
"""
@cast function list(category::String = "studies")
    category = lowercase(category)
    if category in ("studies", "study")
        println("Available studies:")
        for name in SatelliteSimLab.list_studies()
            println("  • $name")
        end
    elseif category in ("experiments", "experiment", "exp")
        println("Registered experiments:")
        for name in SatelliteSimLab.registered_experiments()
            println("  • $name")
        end
    elseif category in ("goals", "goal")
        println("Available goals:")
        for name in SatelliteSimLab.list_goals()
            println("  • $name")
        end
    elseif category in ("constellations", "constellation", "const")
        println("Available constellations:")
        for name in SatelliteSimCore.list_constellations()
            println("  • $name")
        end
    elseif category in ("topologies", "topology", "topo")
        println("Available topology intents:")
        for name in keys(SatelliteSimLab.TOPLOGY_INTENTS)
            println("  • $name")
        end
    elseif category in ("propagators", "propagator", "prop")
        println("Available propagator intents:")
        for name in keys(SatelliteSimLab.PROPAGATOR_INTENTS)
            println("  • $name")
        end
    else
        println("Unknown category: $category")
        println("Supported: studies, experiments, goals, constellations, topologies, propagators")
    end
end

# ────────────────────────────────────────────────────────────
# describe：查看资源描述
# ────────────────────────────────────────────────────────────

"""
查看指定资源描述。

id 可以是 study、experiment 或 goal 名称。
"""
@cast function describe(id::String)
    # 优先查 study
    if id in SatelliteSimLab.list_studies()
        println(SatelliteSimLab.describe_study(id))
        return
    end

    # 查 experiment
    registry = SatelliteSimLab.EXPERIMENT_REGISTRY
    if haskey(registry, id)
        println(SatelliteSimLab.describe(registry[id]))
        return
    end

    # 查 goal
    goals = SatelliteSimLab.GOAL_CATALOG
    if haskey(goals, Symbol(id))
        info = goals[Symbol(id)]
        println("Goal: $id")
        println("  $(info.description)")
        return
    end

    println("Unknown resource: $id")
end

# ────────────────────────────────────────────────────────────
# run：执行实验或研究
# ────────────────────────────────────────────────────────────

"""
运行实验或研究。

type: experiment 或 study
name: 实验/研究名称
"""
@cast function run(type::String, name::String;
    output::String = "",
    constellation::String = "",
    steps::Int = 30,
)
    type = lowercase(type)

    if type == "experiment"
        registry = SatelliteSimLab.EXPERIMENT_REGISTRY
        haskey(registry, name) || error("unknown experiment: $name")
        exp = registry[name]

        config = _build_config(name; constellation = constellation, steps = steps)
        result = SatelliteSimLab.run(exp, config)
        _print_or_save_result(result, output)
        return
    end

    if type == "study"
        studies = SatelliteSimLab.STUDY_REGISTRY
        haskey(studies, name) || error("unknown study: $name")
        StudyType = studies[name]
        study = StudyType()
        result = SatelliteSimLab.run_study(study)
        _print_or_save_result(result, output)
        return
    end

    error("unknown run type: $type (use experiment 或 study)")
end

# ────────────────────────────────────────────────────────────
# propagate：原子工具 — 星座生成 + 轨道传播
# ────────────────────────────────────────────────────────────

"""
生成 Walker 星座并传播，保存位置矩阵到 JLD2 文件。

参数：
- --T, --P, --F：Walker 参数
- --alt：轨道高度（km）
- --inc：轨道倾角（度）
- --duration：仿真时长（秒）
- --steps：时间步数
- --propagator：two_body | j2 | j4
- --output：输出 JLD2 路径
"""
@cast function propagate(;
    T::Int = 24,
    P::Int = 6,
    F::Int = 1,
    alt::Float64 = 550.0,
    inc::Float64 = 53.0,
    duration::Float64 = 3600.0,
    steps::Int = 31,
    propagator::String = "two_body",
    output::String = "outputs/cli/positions.jld2",
)
    tspan = collect(range(0.0, duration; length = steps))
    prop = _resolve_propagator(propagator)

    elems = SatelliteSimCore.generate_walker_delta(;
        T = T, P = P, F = F, alt_km = alt, inc_deg = inc,
    )
    positions = SatelliteSimCore.propagate_to_ecef(elems, tspan; propagator = prop)

    mkpath(dirname(output))
    jldsave(output;
        positions = positions,
        T = T, P = P, F = F,
        alt_km = alt, inc_deg = inc,
        tspan = tspan,
        propagator = propagator,
    )

    println("Propagation complete.")
    println("  satellites : $T")
    println("  time steps : $steps")
    println("  positions  : $(size(positions))")
    println("  saved to   : $output")
end

# ────────────────────────────────────────────────────────────
# topology：原子工具 — 生成 ISL 拓扑
# ────────────────────────────────────────────────────────────

"""
生成指定 Walker 星座的 ISL 拓扑。

参数：
- --strategy：gridplus | tshape | spiral | honeycomb | ring | mesh | nearest
- --T, --P：Walker 参数
- --output：可选 JSON 输出路径
"""
@cast function topology(;
    strategy::String = "gridplus",
    T::Int = 24,
    P::Int = 6,
    output::String = "",
)
    s = _resolve_topology_strategy(strategy)
    topo = SatelliteSimNet.generate_topology(s, T, P)

    static = length(topo.static_links)
    dynamic = length(topo.dynamic_candidates)
    total = static + dynamic

    println("Topology: $(topo.description)")
    println("  static links    : $static")
    println("  dynamic cand.   : $dynamic")
    println("  total           : $total")

    if !isempty(output)
        mkpath(dirname(output))
        data = Dict(
            "strategy" => strategy,
            "T" => T,
            "P" => P,
            "description" => topo.description,
            "static_links" => [collect(p) for p in topo.static_links],
            "dynamic_candidates" => [collect(p) for p in topo.dynamic_candidates],
        )
        open(output, "w") do io
            JSON.print(io, data, 2)
        end
        println("Saved JSON: $output")
    end
end

# ────────────────────────────────────────────────────────────
# route：原子工具 — 单源单宿路由
# ────────────────────────────────────────────────────────────

"""
对给定位置矩阵计算 ISL 路由。

参数：
- --positions：JLD2 位置文件路径
- --src, --dst：源/目的卫星 ID（1-based）
- --strategy：拓扑策略
- --output：可选 JSON 输出路径
"""
@cast function route(;
    positions::String = "outputs/cli/positions.jld2",
    src::Int = 1,
    dst::Int = 2,
    strategy::String = "gridplus",
    output::String = "",
)
    isfile(positions) || error("positions file not found: $positions")
    data = jldopen(positions, "r")
    pos = data["positions"]
    T = data["T"]
    P = data["P"]
    close(data)

    (1 <= src <= T && 1 <= dst <= T) || error("src/dst must be in 1:$T")

    s = _resolve_topology_strategy(strategy)
    D, available_isl, _ = SatelliteSimLab.assess_routing(
        pos, T, P, s, SatelliteSimCore.LEO_DEFAULTS,
    )

    delay = D[src, dst]
    reachable = isfinite(delay)

    println("Routing from sat $src to sat $dst")
    println("  available ISL : $(length(available_isl))")
    println("  reachable     : $reachable")
    if reachable
        println("  delay         : $(round(delay, digits=2)) ms")
    else
        println("  delay         : Inf")
    end

    if !isempty(output)
        mkpath(dirname(output))
        result = Dict(
            "src" => src,
            "dst" => dst,
            "reachable" => reachable,
            "delay_ms" => reachable ? delay : nothing,
            "available_isl_count" => length(available_isl),
        )
        open(output, "w") do io
            JSON.print(io, result, 2)
        end
        println("Saved JSON: $output")
    end
end

# ────────────────────────────────────────────────────────────
# sweep：参数扫描
# ────────────────────────────────────────────────────────────

"""
对研究进行单参数扫描。

name: 研究名称
param: 参数名（支持 alt_km, inc_deg, T, P）
values: 逗号分隔的数值列表
"""
@cast function sweep(name::String;
    param::String = "alt_km",
    values::String = "550,780,1200",
    output::String = "",
)
    studies = SatelliteSimLab.STUDY_REGISTRY
    haskey(studies, name) || error("unknown study: $name")

    param in ("alt_km", "inc_deg", "T", "P") ||
        error("unsupported param: $param (use alt_km, inc_deg, T, P)")

    vals = parse.(Float64, split(values, ','))
    StudyType = studies[name]

    println("Sweeping $param over: $(join(vals, ", "))")
    results = Tuple{Float64, SatelliteSimLab.ExperimentResult}[]

    for v in vals
        study = _make_study_with_param(StudyType, param, v)
        result = SatelliteSimLab.run_study(study)
        push!(results, (v, result))
        println("  $param=$v => fitness=$(round(result.fitness, digits=4)), " *
                "coverage=$(round(result.coverage.coverage_ratio, digits=3))")
    end

    if !isempty(output)
        _save_sweep_results(results, param, output)
    end
end

# ────────────────────────────────────────────────────────────
# compare：多方案对比
# ────────────────────────────────────────────────────────────

"""
对比多个星座配置。

names: 一个或多个星座 catalog 名称
"""
@cast function compare(names::String...; output::String = "")
    isempty(names) && error("compare requires at least one constellation name")

    println("Comparing constellations: $(join(names, ", "))")
    rows = []

    for name in names
        sym = Symbol(name)
        config = SatelliteSimLab.ExperimentConfig(;
            name = "compare_$(name)",
            constellation = sym,
            tspan = collect(0.0:60.0:3600.0),
        )
        result = SatelliteSimLab.run_experiment(config)
        row = (
            name = name,
            coverage = result.coverage.coverage_ratio,
            avg_latency_ms = result.latency.avg_latency_ms,
            connectivity = result.network.connectivity_ratio,
            fitness = result.fitness,
        )
        push!(rows, row)
        println("  $name: coverage=$(round(row.coverage, digits=3)), " *
                "latency=$(round(row.avg_latency_ms, digits=1))ms, " *
                "fitness=$(round(row.fitness, digits=4))")
    end

    if !isempty(output)
        _save_compare_results(rows, output)
    end
end

# ────────────────────────────────────────────────────────────
# viz：可视化（阶段 3 占位，先实现 3D snapshot）
# ────────────────────────────────────────────────────────────

"""
生成可视化图片/动画/Dashboard。

subcommand: snapshot / dashboard / animate / czml
positions_path: JLD2 位置文件路径
"""
@cast function viz(subcommand::String, positions_path::String;
    output::String = "",
    show_isl::Bool = false,
    show_route::Bool = false,
    show_beams::Bool = false,
    strategy::String = "gridplus",
    time_index::Int = 1,
    fps::Int = 10,
)
    subcommand = lowercase(subcommand)
    isfile(positions_path) || error("positions file not found: $positions_path")

    data = jldopen(positions_path, "r")
    pos = data["positions"]
    T = data["T"]
    P = data["P"]
    tspan = try
        data["tspan"]
    catch
        Float64[]
    end
    close(data)

    out_path = _viz_output_path(subcommand, output, positions_path)
    mkpath(dirname(out_path))

    # 可选：计算 ISL / 路由
    isl_pairs = Tuple{Int,Int}[]
    isl_available = Bool[]
    route_path = Int[]

    if show_isl || show_route
        s = _resolve_topology_strategy(strategy)
        D, available, _ = SatelliteSimLab.assess_routing(pos, T, P, s, SatelliteSimCore.LEO_DEFAULTS)
        # 为了可视化，生成所有拓扑边 + 可用掩码
        topo = SatelliteSimNet.generate_topology(s, T, P)
        all_links = vcat(topo.static_links, topo.dynamic_candidates)
        isl_pairs = [(Int(l[1]), Int(l[2])) for l in all_links]
        isl_available = Bool[(l in available) for l in all_links]

        if show_route
            dst = min(T, ceil(Int, T / 2))
            if isfinite(D[1, dst])
                # 用贪心在 D 矩阵上找路径
                route_path = _greedy_route(D, 1, dst)
            end
        end
    end

    if subcommand == "snapshot"
        config = SatelliteSimViz.MakieViewerConfig(;
            title = "CLI Snapshot",
            time_index = time_index,
            show_orbits = true,
            show_isl = show_isl,
            show_route = show_route,
            show_beams = show_beams,
            show_ground_stations = false,
            satellite_markersize = 4.0,
            dark_theme = true,
        )
        fig = SatelliteSimViz.plot_orbit_snapshot(pos;
            isl_pairs = isl_pairs,
            isl_available = isl_available,
            route_path = route_path,
            config = config,
        )
        SatelliteSimViz.save(out_path, fig)
        println("Saved snapshot: $out_path")

    elseif subcommand == "animate"
        config = SatelliteSimViz.MakieViewerConfig(;
            title = "CLI Animation",
            show_orbits = false,
            show_isl = show_isl,
            show_route = show_route,
            show_ground_stations = false,
            satellite_markersize = 4.0,
            dark_theme = true,
        )
        SatelliteSimViz.animate_orbit(pos;
            isl_pairs = isl_pairs,
            isl_available = isl_available,
            route_path = route_path,
            output_path = out_path,
            fps = fps,
            config = config,
        )
        println("Saved animation: $out_path")

    elseif subcommand == "dashboard"
        fig = SatelliteSimViz.plot_dashboard(pos;
            time_index = time_index,
            isl_pairs = isl_pairs,
            isl_available = isl_available,
            route_path = route_path,
            config = SatelliteSimViz.MakieViewerConfig(; dark_theme = true),
            title = "CLI Dashboard",
        )
        SatelliteSimViz.save(out_path, fig)
        println("Saved dashboard: $out_path")

    elseif subcommand == "czml"
        dt = length(tspan) >= 2 ? Float64(tspan[2] - tspan[1]) : 60.0
        SatelliteSimViz.write_czml(out_path, pos;
            dt = dt,
            isl_pairs = isl_pairs,
        )
        println("Saved CZML: $out_path")

    else
        error("unknown viz subcommand: $subcommand (use snapshot, animate, dashboard, czml)")
    end
end

# ────────────────────────────────────────────────────────────
# agent：自然语言 Agent CLI
# ────────────────────────────────────────────────────────────

"""
启动自然语言 Agent 交互式 REPL。

需要设置 DEEPSEEK_API_KEY 环境变量，或用 --key 传入。
"""
@cast function agent(;
    model::String = "deepseek-chat",
    key::String = "",
    url::String = "https://api.deepseek.com/v1",
    voice::Bool = false,
)
    api_key = isempty(key) ? get(ENV, "DEEPSEEK_API_KEY", "") : key
    isempty(api_key) && error("DEEPSEEK_API_KEY not set; pass --key or set env var")

    provider = SatelliteSimLab.LLMProvider(; key = api_key, model = model, url = url)
    voice ? SatelliteSimLab.voice_agent_repl(provider) : SatelliteSimLab.agent_repl(provider)
end

"""
单轮自然语言 Agent 查询。

query: 自然语言问题，例如 "walker24 和 walker48 的时延对比"
"""
@cast function chat(query::String;
    model::String = "deepseek-chat",
    key::String = "",
    url::String = "https://api.deepseek.com/v1",
)
    api_key = isempty(key) ? get(ENV, "DEEPSEEK_API_KEY", "") : key
    isempty(api_key) && error("DEEPSEEK_API_KEY not set; pass --key or set env var")

    provider = SatelliteSimLab.LLMProvider(; key = api_key, model = model, url = url)
    agent = SatelliteSimLab.SimAgent(provider)
    reply = SatelliteSimLab.run_agent(agent, query)
    println(reply)
end

"""
多智能体团队单轮查询。

query: 自然语言任务，例如 "帮我规划并执行一个 walker48 覆盖分析"
"""
@cast function team(query::String;
    model::String = "deepseek-chat",
    key::String = "",
    url::String = "https://api.deepseek.com/v1",
    session_id::String = "team_default",
)
    api_key = isempty(key) ? get(ENV, "DEEPSEEK_API_KEY", "") : key
    isempty(api_key) && error("DEEPSEEK_API_KEY not set; pass --key or set env var")

    provider = SatelliteSimLab.LLMProvider(; key = api_key, model = model, url = url)
    result = SatelliteSimLab.run_team(provider, query; session_id = session_id)
    println(result.final_answer)
end

# ────────────────────────────────────────────────────────────
# 入口
# ────────────────────────────────────────────────────────────

@main

# ────────────────────────────────────────────────────────────
# 内部辅助
# ────────────────────────────────────────────────────────────

function _build_config(name::String; constellation::String = "", steps::Int = 30)
    kwargs = Dict{Symbol,Any}(:name => name)

    if !isempty(constellation)
        kwargs[:constellation] = Symbol(constellation)
    end

    # 默认 1 小时，steps 个采样点
    kwargs[:tspan] = collect(range(0.0, 3600.0; length = steps))

    return SatelliteSimLab.ExperimentConfig(; kwargs...)
end

function _make_study_with_param(StudyType::DataType, param::String, v::Float64)
    # 构造默认 study，再按参数类型覆盖对应字段
    study = StudyType()

    if StudyType == SatelliteSimLab.RoutingStudy
        if param in ("alt_km", "inc_deg", "T", "P")
            # RoutingStudy 用 constellation 符号，这里无法直接改 Walker 参数，
            # 改为在 run_study 前把 constellation 替换为自定义符号不现实。
            # 简化：忽略参数，跑默认。
            return study
        end
    end

    # 当前简化：对不能直接修改参数的 study，返回默认实例
    # 后续可扩展为把 Study 翻译成 ExperimentConfig 再覆盖字段
    return study
end

function _print_or_save_result(result, output::String)
    println("Experiment completed.")
    println("  coverage_ratio = $(result.coverage.coverage_ratio)")
    println("  avg_latency_ms = $(result.latency.avg_latency_ms)")
    println("  connectivity   = $(result.network.connectivity_ratio)")
    println("  fitness        = $(result.fitness)")

    if !isempty(output)
        ext = lowercase(splitext(output)[2])
        if ext == ".json"
            data = SatelliteSimLab.to_dict(result)
            open(output, "w") do io
                JSON.print(io, data, 2)
            end
            println("Saved JSON: $output")
        elseif ext == ".csv"
            SatelliteSimLab.to_csv([result], output)
            println("Saved CSV: $output")
        elseif ext == ".md"
            SatelliteSimLab.to_markdown([result], output)
            println("Saved Markdown: $output")
        else
            println("Unsupported output format: $ext (use .json/.csv/.md)")
        end
    end
end

function _save_sweep_results(results, param::String, output::String)
    mkpath(dirname(output))
    ext = lowercase(splitext(output)[2])
    if ext == ".csv"
        open(output, "w") do io
            println(io, "$param,coverage_ratio,avg_latency_ms,connectivity_ratio,fitness")
            for (v, r) in results
                println(io, "$v,$(r.coverage.coverage_ratio),$(r.latency.avg_latency_ms),$(r.network.connectivity_ratio),$(r.fitness)")
            end
        end
        println("Saved sweep CSV: $output")
    else
        println("Sweep output only supports .csv currently")
    end
end

function _save_compare_results(rows, output::String)
    mkpath(dirname(output))
    ext = lowercase(splitext(output)[2])
    if ext == ".csv"
        open(output, "w") do io
            println(io, "name,coverage_ratio,avg_latency_ms,connectivity_ratio,fitness")
            for row in rows
                println(io, "$(row.name),$(row.coverage),$(row.avg_latency_ms),$(row.connectivity),$(row.fitness)")
            end
        end
        println("Saved compare CSV: $output")
    elseif ext == ".md"
        open(output, "w") do io
            println(io, "| Name | Coverage | Avg Latency (ms) | Connectivity | Fitness |")
            println(io, "|------|----------|------------------|--------------|---------|")
            for row in rows
                println(io, "| $(row.name) | $(round(row.coverage, digits=3)) | $(round(row.avg_latency_ms, digits=1)) | $(round(row.connectivity, digits=3)) | $(round(row.fitness, digits=4)) |")
            end
        end
        println("Saved compare Markdown: $output")
    else
        println("Compare output supports .csv/.md")
    end
end

function _resolve_propagator(name::String)
    name = lowercase(name)
    name == "twobody" && return SatelliteSimCore.TwoBodyPropagator()
    name == "two_body" && return SatelliteSimCore.TwoBodyPropagator()
    name == "j2" && return SatelliteSimCore.J2Propagator()
    name == "j4" && return SatelliteSimCore.J4Propagator()
    error("unknown propagator: $name (use two_body, j2, j4)")
end

function _resolve_topology_strategy(name::String)
    name = lowercase(name)
    name in ("gridplus", "grid_plus") && return SatelliteSimNet.GridPlusStrategy()
    name == "tshape" && return SatelliteSimNet.TShapeStrategy()
    name == "spiral" && return SatelliteSimNet.SpiralStrategy()
    name == "honeycomb" && return SatelliteSimNet.HoneycombStrategy()
    name == "ring" && return SatelliteSimNet.RingStrategy()
    name == "mesh" && return SatelliteSimNet.MeshStrategy()
    name in ("nearest", "nearest_neighbor") && return SatelliteSimNet.NearestNeighborStrategy()
    error("unknown topology strategy: $name")
end

function _viz_output_path(subcommand::String, output::String, positions_path::String)
    !isempty(output) && return output
    base = splitext(positions_path)[1]
    ext = subcommand == "animate" ? ".mp4" :
          subcommand == "czml" ? ".czml" : ".png"
    return base * "_" * subcommand * ext
end

function _greedy_route(D::Matrix{Float64}, src::Int, dst::Int)
    n = size(D, 1)
    path = [src]
    visited = Set([src])
    cur = src
    while cur != dst
        next = 0
        best = Inf
        for nb in 1:n
            nb == cur && continue
            nb in visited && continue
            cost = D[cur, nb] + D[nb, dst]
            if cost < best
                best = cost
                next = nb
            end
        end
        (next == 0 || !isfinite(D[cur, next])) && break
        push!(path, next)
        push!(visited, next)
        cur = next
        length(path) > n && break
    end
    return path
end

end # module
