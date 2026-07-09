# ===== AI Agent — ReAct 循环 + 工具执行桥接 =====
#
# 这是 AI 适配层的核心接线：
# 用户自然语言 → LLM 理解意图 → tool_call → lab 仿真引擎执行 → 结果返回 LLM → 自然语言解读
#
# ReAct 循环：Thought → Action → Observation → Thought → ... → Final Answer

using Printf
using Dates
using JSON

export SimAgent, run_agent, agent_repl, voice_agent_repl, execute_tool,
       SYSTEM_PROMPT_STABLE, VOICE_SYSTEM_PROMPT_STABLE, SYSTEM_PROMPT_DYNAMIC_BOUNDARY, system_prompt

# ─── Prompt 缓存边界（借鉴 Claude Code 的 SYSTEM_PROMPT_DYNAMIC_BOUNDARY）───
#
# 把 System Prompt 拆为「稳定前缀 + 动态后缀」：
#   - 稳定前缀字节级固定。
#   - 动态后缀每次会话/循环可变（会话目标、三层记忆 Layer 1），放在末尾。
#
# 收益说明（如实，非夸大）：
#   - DeepSeek 的 Context Caching 默认开启、自动复用重复前缀，无需应用层干预
#     （见 https://api-docs.deepseek.com/guides/kv_cache ）。故本拆分对 DeepSeek
#     不带来额外缓存收益——它本就会缓存稳定前缀。
#   - 本结构的真实价值是：① 给动态信息（会话目标/已扫描参数）一个正式位置，
#     不再散落在 user 消息；② 三层记忆的 Layer 1（memory_context）有注入点。
#   - 对需要显式标记 cache 段的 provider（如 OpenAI 的 cache_control），
#     稳定/动态分界仍是有意义的接入点（当前未对接，预留）。
# 该常量名是「架构约束的显式提醒」——想往稳定区塞动态内容时会撞到这里。

const SYSTEM_PROMPT_STABLE = """你是 SatelliteSim，一个 LEO 卫星星座网络仿真助手。

你可以帮用户：
1. 运行星座网络仿真（覆盖、时延、连通性、路由）
2. 扫描参数（高度、倾角、面数等对网络指标的影响）
3. 对比不同星座（Iridium/Starlink/OneWeb 等）
4. 列出可用的预设和配置

使用提供的工具完成用户请求。调用工具时把参数填满。
收到结果后用中文简洁解读关键数字。"""

const VOICE_SYSTEM_PROMPT_STABLE = """你是 SatelliteSim 的语音助手。

你优先用短句回答，每次尽量不超过 3 句。
如果用户在讨论方案，就先给结论和下一步，不要展开长篇原理。
如果用户在执行任务，就直接给出可执行动作或明确的确认。
不要输出代码块、长列表或多余的铺垫。
需要继续时，只问一个最关键的问题。"""

# 动态边界标记：稳定区与动态区的硬分界。
const SYSTEM_PROMPT_DYNAMIC_BOUNDARY = "\n\n--- 会话上下文（动态，不进缓存）---\n"

"""
    SimAgent

AI 仿真助手，封装 LLM Provider + 对话历史 + 工具执行。
"""
mutable struct SimAgent
    provider::AbstractLLMProvider
    messages::Vector{Dict{String,Any}}
    tools::Vector{Dict}
    max_iterations::Int
    reply_style::Symbol            # :standard | :voice
    # 动态后缀数据（进入 System Prompt 的动态区，支持 prompt cache）：
    session_goal::String              # 本次会话目标（一句话）
    scanned_params::Vector{String}    # 已扫描过的参数组合（避免重复扫描，内存态）
    memory::SessionMemory             # 三层会话记忆（落盘，跨会话）
end

"""
    SimAgent(provider; session_goal, scanned_params, session_id)

构造 AI 仿真助手。System Prompt 由稳定前缀 + 动态后缀自动拼装（见 `system_prompt`）。
`session_id` 决定三层记忆的落盘目录（data/sessions/<session_id>/），同 id 跨会话恢复。

```julia
agent = SimAgent(LLMProvider())
reply = run_agent(agent, "帮我跑一个 Iridium 星座的覆盖分析")
```
"""
function SimAgent(provider::AbstractLLMProvider;
                  session_goal::String = "",
                  scanned_params::Vector{String} = String[],
                  session_id::String = DEFAULT_SESSION_ID,
                  reply_style::Symbol = :standard,
                  permission_policy = nothing)
    # 注册默认 hooks（幂等）：截断、schema 校验、资源守卫、ledger 审计、权限/HITL。
    ensure_default_hooks!()
    isdefined(@__MODULE__, :register_default_schema_validation!) && register_default_schema_validation!()
    isdefined(@__MODULE__, :register_default_tool_guards!) && register_default_tool_guards!()
    isdefined(@__MODULE__, :register_default_ledger_hooks!) && register_default_ledger_hooks!()
    isdefined(@__MODULE__, :register_default_tool_permissions!) && register_default_tool_permissions!()
    sp = system_prompt_stable(reply_style) * SYSTEM_PROMPT_DYNAMIC_BOUNDARY
    # 首次构建时动态区可能为空（无 session_goal），仍拼上以保持稳定前缀字节不变。
    messages = [Dict{String,Any}("role" => "system", "content" => sp)]
    tools = build_tool_schemas()
    mem = SessionMemory(session_id = session_id)
    max_iterations = reply_style === :voice ? 6 : 10
    agent = SimAgent(provider, messages, tools, max_iterations, reply_style, session_goal, copy(scanned_params), mem)
    if permission_policy !== nothing && isdefined(@__MODULE__, :_set_tool_permission_policy!)
        _set_tool_permission_policy!(agent, permission_policy)
    end
    return agent
end

system_prompt_stable(reply_style::Symbol) =
    reply_style === :voice ? VOICE_SYSTEM_PROMPT_STABLE : SYSTEM_PROMPT_STABLE

"""
    system_prompt_dynamic(agent) -> String

构建 System Prompt 的动态后缀。承载每次会话可变的信息：
当前时间、本次会话目标、三层记忆的 Layer 1（已记录实验摘要）。

Layer 1（memory.index）落盘跨会话恢复，替代原纯内存的 scanned_params。
"""
function system_prompt_dynamic(agent::SimAgent)
    io = IOBuffer()
    println(io, "当前时间: ", Dates.format(now(), "yyyy-mm-dd HH:MM"))
    if !isempty(agent.session_goal)
        println(io, "本次会话目标: ", agent.session_goal)
    end
    # 优先用三层记忆 Layer 1（落盘、跨会话）；为空时回退内存态 scanned_params
    ctx = memory_context(agent.memory)
    if isempty(ctx) && !isempty(agent.scanned_params)
        n = length(agent.scanned_params)
        shown = join(agent.scanned_params[max(1, n - 9):n], ", ")
        ctx = "已扫描参数组合: " * shown * (n > 10 ? "（最近10条，共$n条）" : "")
    end
    isempty(ctx) || println(io, ctx)
    return String(take!(io))
end

"""
    system_prompt(agent) -> String

拼装完整 System Prompt = 稳定前缀 + 动态边界 + 动态后缀。
"""
system_prompt(agent::SimAgent) =
    system_prompt_stable(agent.reply_style) * SYSTEM_PROMPT_DYNAMIC_BOUNDARY * system_prompt_dynamic(agent)

"""
    run_agent(agent, user_input) -> String

运行一次 ReAct 循环。返回最终回复文本。
"""
function run_agent(agent::SimAgent, user_input::String)
    push!(agent.messages, Dict("role" => "user", "content" => user_input))

    # 刷新 System Prompt 的动态后缀（稳定前缀字节不变，动态区承载三层记忆 Layer 1）。
    # 让「已记录实验摘要」等动态信息反映给 LLM。
    agent.messages[1]["content"] = system_prompt(agent)

    for iteration in 1:agent.max_iterations
        # 调 LLM 前钩子（可阻断或审计 messages）
        pre_llm_ctx = PreLLMCtx(agent.messages, agent)
        proceed, _ = run_hooks!(:pre_llm, pre_llm_ctx)
        proceed || return "（被 pre_llm 钩子阻断）"

        msg = chat(agent.provider, agent.messages, agent.tools)

        # 调 LLM 后钩子（可替换 AssistantMessage；默认无注册，保持旧行为）
        post_llm_ctx = PostLLMCtx(msg, agent)
        _, transformed_msg = run_hooks!(:post_llm, post_llm_ctx)
        transformed_msg isa AssistantMessage && (msg = transformed_msg)

        # 记录助手消息（显式 Dict{String,Any} 避免 tool_calls 类型冲突）
        assistant_dict = Dict{String,Any}("role" => "assistant", "content" => msg.content)
        if !isempty(msg.tool_calls)
            assistant_dict["tool_calls"] = [
                Dict("id" => tc.id, "type" => "function",
                     "function" => Dict("name" => tc.name, "arguments" => JSON.json(tc.args)))
                for tc in msg.tool_calls
            ]
        end
        push!(agent.messages, assistant_dict)

        # 如果没有 tool_call，返回最终回复
        if isempty(msg.tool_calls)
            return msg.content
        end

        # 执行每个 tool_call
        for tc in msg.tool_calls
            @printf("[Agent] 执行工具: %s(%s)\n", tc.name, JSON.json(tc.args))
            # execute_tool 内部走 pre/post 钩子（含默认截断）
            result_str = execute_tool(tc.name, tc.args, agent)

            @printf("[Agent] 结果: %s\n", result_str[1:min(200, end)])

            # 记录到三层记忆（Layer 1 摘要 + Layer 3 transcript 落盘）
            _record_scanned!(agent, tc.name, tc.args, result_str)

            # 把结果作为 tool 消息返回给 LLM
            push!(agent.messages, Dict(
                "role" => "tool",
                "tool_call_id" => tc.id,
                "content" => result_str,
            ))
        end
    end

    return "（达到最大迭代次数 $(agent.max_iterations)，请缩小请求范围）"
end

# ─── 工具执行桥接（钩子环绕）───

"""
    execute_tool(name, args, agent) -> String

执行 LLM 请求的工具，桥接到 lab 的仿真引擎。

钩子环绕（借鉴 Claude Code PreToolUse/PostToolUse）：
- pre_tool 钩子：执行前校验，任一返回 :block 则不执行（返回阻断提示）。
- post_tool 钩子：执行后转换结果（如截断、格式化、记录记忆），链式替换。

默认注册了 default_truncation_hook（结果截断到 4000 字符），等价于原写死逻辑。
"""
function execute_tool(name::String, args::AbstractDict, agent::SimAgent)
    # pre_tool 钩子（可阻断）
    pre_ctx = PreToolCtx(name, args, agent)
    proceed, reason = run_hooks!(:pre_tool, pre_ctx)
    if !proceed
        reason_str = reason === nothing ? "blocked by hook" : string(reason)
        isdefined(@__MODULE__, :record_tool_ledger!) &&
            record_tool_ledger!(agent, name, args; status = "blocked", reason = reason_str)
        return "（被 pre_tool 钩子阻断：$(reason_str)）"
    end

    # 工具分发
    result = try
        _dispatch_tool(name, args)
    catch e
        err = string(e)
        isdefined(@__MODULE__, :record_tool_ledger!) &&
            record_tool_ledger!(agent, name, args; status = "failed", error = err)
        Dict("error" => err)
    end
    result_str = result isa Dict ? JSON.json(result; allownan=true) : string(result)

    # post_tool 钩子（链式转换；默认含截断钩子 + ledger）
    post_ctx = PostToolCtx(name, args, result_str, agent)
    _, transformed = run_hooks!(:post_tool, post_ctx)
    return transformed === nothing ? result_str : transformed
end

# 向后兼容：无 agent 的旧签名（默认注册截断钩子，行为等价旧实现）。
function execute_tool(name::String, args::AbstractDict)
    result = try
        _dispatch_tool(name, args)
    catch e
        Dict("error" => string(e))
    end
    r = result isa Dict ? JSON.json(result; allownan=true) : string(result)
    # 复用截断钩子逻辑（字符安全）
    post_ctx = PostToolCtx(name, args, r, nothing)
    return default_truncation_hook(post_ctx, r)
end

# 实际工具分发（pre/post 钩子之外的核心逻辑）
function _dispatch_tool(name::String, args::AbstractDict)
    if isdefined(@__MODULE__, :execute_registered_tool)
        ensure_default_ai_tools!()
        registered = execute_registered_tool(name, args)
        registered === nothing || return registered
    end
    return Dict("error" => "未知工具: $name")
end

# 工具：运行仿真
function _tool_run_simulation(args::AbstractDict)
    constellation = get(args, "constellation", "walker 24/6/1")
    topo = get(args, "topology", "gridplus")
    prop = get(args, "propagator", "twobody")
    duration = get(args, "duration_s", 600)
    steps = get(args, "steps", 2)
    traffic = lowercase(strip(String(get(args, "traffic", "none"))))
    routing = lowercase(strip(String(get(args, "routing", "shortest_path"))))
    routing_algorithm = parse_ai_routing(routing)
    ground_stations = _parse_ai_ground_stations(get(args, "ground_stations", []))
    ground_pairs = _parse_ai_ground_pairs(get(args, "ground_pairs", []), ground_stations)
    traffic_arg = _ai_traffic_arg(args, traffic)

    # 解析传播器：tle_based 返回 :sgp4 标记，走独立 SGP4 路径
    propagator = parse_ai_propagator(prop)

    if propagator === :sgp4
        return _run_sgp4_simulation(args, constellation, topo, duration, steps)
    end

    # Keplerian 路径需要 Walker 星座参数；TLE 路径已在上方分流。
    cfg = parse_ai_constellation(constellation)
    T, P, F, alt, inc = cfg.T, cfg.P, cfg.F, cfg.alt_km, cfg.inc_deg

    # Keplerian 路径（二体/J2/J4）
    strategy = parse_ai_topology(topo, T)
    tspan = collect(range(0.0, Float64(duration); length=steps))
    config = ExperimentConfig(;
        name = "ai_simulation",
        constellation = WalkerConstellationConfig(T=T, P=P, F=F, alt_km=alt, inc_deg=inc),
        propagator = propagator,
        tspan = tspan,
        topology_strategy = strategy,
        routing_algorithm = routing_algorithm,
        traffic = traffic_arg,
        ground_stations = ground_stations,
        ground_pairs = ground_pairs,
    )
    result = run_experiment(config)
    traffic_evaluation = result.traffic_evaluation
    traffic_totals = _traffic_assignment_totals(traffic_evaluation)

    return Dict(
        "constellation" => constellation,
        "n_satellites" => T,
        "propagator" => prop,
        "routing" => routing,
        "routing_evaluation_scope" => traffic_evaluation === nothing ? "matrix_shortest_path_summary" : "traffic_aon_per_flow",
        "coverage_ratio" => round(result.coverage.coverage_ratio, digits=4),
        "avg_latency_ms" => round(result.latency.avg_latency_ms, digits=2),
        "max_latency_ms" => round(result.latency.max_latency_ms, digits=2),
        "connectivity_ratio" => round(result.network.connectivity_ratio, digits=4),
        "fitness" => round(result.fitness, digits=4),
        "duration_s" => round(result.duration_s, digits=3),
        "traffic_enabled" => traffic != "none" || !isempty(config.traffic_demands),
        "traffic_demands" => length(config.traffic_demands),
        "ground_stations" => length(config.ground_stations),
        "ground_pairs" => length(config.ground_pairs),
        "traffic_evaluation_ran" => traffic_evaluation !== nothing,
        "traffic_fallback" => traffic != "none" && traffic_evaluation === nothing,
        "traffic_time_steps" => traffic_evaluation === nothing ? 0 : length(traffic_evaluation.assignments_by_time),
        "traffic_assignments" => traffic_evaluation === nothing ? 0 : sum(length, traffic_evaluation.assignments_by_time),
        "offered_mbps" => round(traffic_totals.offered_mbps, digits=3),
        "carried_mbps" => round(traffic_totals.carried_mbps, digits=3),
        "dropped_mbps" => round(traffic_totals.dropped_mbps, digits=3),
    )
end

function _ai_traffic_arg(traffic::AbstractString)
    traffic == "none" && return TrafficDemand[]
    traffic == "uniform" && return :uniform
    traffic == "hotspot" && return :hotspot
    traffic == "video" && return :video
    traffic == "iot" && return :iot
    return TrafficDemand[]
end

function _ai_traffic_arg(args::AbstractDict, traffic::AbstractString)
    explicit = _parse_ai_traffic_demands(get(args, "traffic_demands", []))
    isempty(explicit) || return explicit
    return _ai_traffic_arg(traffic)
end

function _parse_ai_traffic_demands(raw)::Vector{TrafficDemand}
    raw isa AbstractVector || return TrafficDemand[]
    demands = TrafficDemand[]
    for (idx, item) in enumerate(raw)
        item isa AbstractDict || continue
        source = Int(get(item, "source_ground_id", get(item, :source_ground_id, 0)))
        destination = Int(get(item, "destination_ground_id", get(item, :destination_ground_id, 0)))
        source > 0 && destination > 0 && source != destination || continue
        start_s = Int(get(item, "start_elapsed_s", get(item, :start_elapsed_s, 0)))
        end_s = Int(get(item, "end_elapsed_s", get(item, :end_elapsed_s, 3600)))
        rate = Float64(get(item, "rate_mbps", get(item, :rate_mbps, 0.0)))
        id = Int(get(item, "id", get(item, :id, idx)))
        try
            push!(demands, TrafficDemand(;
                id = id,
                source_ground_id = source,
                destination_ground_id = destination,
                start_elapsed_s = start_s,
                end_elapsed_s = end_s,
                rate_mbps = rate,
            ))
        catch
            # Ignore malformed entries; schema/probe tests cover valid explicit demands.
        end
    end
    return demands
end

function _parse_ai_ground_stations(raw)::Vector{GroundStation}
    raw isa AbstractVector || return GroundStation[]
    stations = GroundStation[]
    for (idx, item) in enumerate(raw)
        item isa AbstractDict || continue
        lat = Float64(get(item, "lat", get(item, :lat, 0.0)))
        lon = Float64(get(item, "lon", get(item, :lon, 0.0)))
        alt_km = Float64(get(item, "alt_km", get(item, :alt_km, 0.0)))
        id = Int(get(item, "id", get(item, :id, idx)))
        name = String(get(item, "name", get(item, :name, "ground_$id")))
        push!(stations, GroundStation(id = id, name = name, position = GeodeticPosition(lat, lon, alt_km)))
    end
    return stations
end

function _parse_ai_ground_pairs(raw, ground_stations::Vector{GroundStation})::Vector{Tuple{Int,Int}}
    pairs = Tuple{Int,Int}[]
    if raw isa AbstractVector
        for item in raw
            item isa AbstractVector || continue
            length(item) == 2 || continue
            push!(pairs, (Int(item[1]), Int(item[2])))
        end
    end
    !isempty(pairs) && return pairs
    ids = [station.id for station in ground_stations]
    return [(ids[i], ids[j]) for i in eachindex(ids) for j in i+1:length(ids)]
end

function _traffic_assignment_totals(traffic_evaluation)
    traffic_evaluation === nothing && return (offered_mbps = 0.0, carried_mbps = 0.0, dropped_mbps = 0.0)
    offered = 0.0
    carried = 0.0
    dropped = 0.0
    for assignments in traffic_evaluation.assignments_by_time
        for assignment in assignments
            offered += assignment.offered_mbps
            carried += assignment.carried_mbps
            dropped += assignment.dropped_mbps
        end
    end
    return (offered_mbps = offered, carried_mbps = carried, dropped_mbps = dropped)
end

# SGP4 独立路径：catalog 优先取 TLE，无则要求工具参数传 tle。
# SGP4 需要真实 TLE + 历元时间网格，与 Keplerian 路径输入完全不同，故单独处理。
# 下游管线复用预编排工具（assess_routing/compute_latency/compute_network_metrics），
# 与 Keplerian 路径共享同一套指标计算（单一真相源）。
function _run_sgp4_simulation(args::AbstractDict, constellation::AbstractString,
                               topo::AbstractString, duration::Real, steps::Integer)
    traffic = lowercase(strip(String(get(args, "traffic", "none"))))
    routing = lowercase(strip(String(get(args, "routing", "shortest_path"))))
    routing_algorithm = parse_ai_routing(routing)
    ground_stations = _parse_ai_ground_stations(get(args, "ground_stations", []))
    ground_pairs = _parse_ai_ground_pairs(get(args, "ground_pairs", []), ground_stations)
    traffic_arg = _ai_traffic_arg(args, traffic)

    # 1. 取 TLE：catalog 优先（:starlink_tle / "<name>_tle"），否则参数 tle 兜底。
    #    限制卫星数（默认 24）：真实 TLE 文件可能含上万颗，全量跑不现实。
    max_sats = Int(get(args, "max_sats", 24))
    tle_elements = _resolve_tle(constellation, args; max_sats=max_sats)

    # 2. 构造历元时间网格（SGP4 需真实 epoch 算 GMST 旋转）
    #    SimulationTimeGrid(epoch, duration_s::Int, step_s::Int)
    duration_i = max(1, round(Int, duration))
    step_i = steps > 1 ? max(1, round(Int, duration_i / (steps - 1))) : duration_i
    epoch = default_starlink_simulation_epoch()
    tg = SimulationTimeGrid(epoch, duration_i, step_i)
    positions = propagate_to_ecef(tle_elements, tg)

    # 3. 下游管线复用：拓扑/ISL/路由/指标（positions 为裸数组 N×T×3 km）
    n = size(positions, 1)
    # P 对拓扑生成必需；TLE 星座无轨道面概念，按 n 估计 P（避免除零）
    P_est = max(1, isqrt(n))
    strategy = parse_ai_topology(topo, n)
    constraints = LEO_DEFAULTS   # 默认 LEO 物理约束（与 Keplerian 路径一致）
    D, available_isl, isl_results = assess_routing(positions, n, P_est, strategy, constraints)
    latency = compute_latency(D)
    network = compute_network_metrics(D)

    tspan = Float64.(timeslot_offsets(tg))
    traffic_config = ExperimentConfig(;
        name = "ai_sgp4_simulation",
        constellation = WalkerConstellationConfig(T=n, P=1, F=0, alt_km=550.0, inc_deg=53.0),
        tspan = tspan,
        constraints = constraints,
        topology_strategy = strategy,
        routing_algorithm = routing_algorithm,
        traffic = traffic_arg,
        ground_stations = ground_stations,
        ground_pairs = ground_pairs,
    )
    traffic_evaluation = if !isempty(traffic_config.traffic_demands)
        try
            _evaluate_traffic_full(traffic_config, positions, available_isl)
        catch
            nothing
        end
    else
        nothing
    end
    traffic_totals = _traffic_assignment_totals(traffic_evaluation)
    if traffic_evaluation !== nothing
        latency = _latency_from_traffic(traffic_evaluation)
        network = _network_from_traffic(traffic_evaluation)
    end

    return Dict(
        "constellation" => constellation,
        "n_satellites" => n,
        "propagator" => "tle_based",
        "routing" => routing,
        "routing_evaluation_scope" => traffic_evaluation === nothing ? "matrix_shortest_path_summary" : "traffic_aon_per_flow",
        "tle_source" => length(tle_elements),
        "coverage_ratio" => 0.0,   # SGP4 路径无 GSL 地面站输入，覆盖不适用
        "avg_latency_ms" => round(latency.avg_latency_ms, digits=2),
        "max_latency_ms" => round(latency.max_latency_ms, digits=2),
        "connectivity_ratio" => round(network.connectivity_ratio, digits=4),
        "duration_s" => round(Float64(duration), digits=3),
        "traffic_enabled" => traffic != "none" || !isempty(traffic_config.traffic_demands),
        "traffic_demands" => length(traffic_config.traffic_demands),
        "ground_stations" => length(traffic_config.ground_stations),
        "ground_pairs" => length(traffic_config.ground_pairs),
        "traffic_evaluation_ran" => traffic_evaluation !== nothing,
        "traffic_fallback" => traffic != "none" && traffic_evaluation === nothing,
        "traffic_time_steps" => traffic_evaluation === nothing ? 0 : length(traffic_evaluation.assignments_by_time),
        "traffic_assignments" => traffic_evaluation === nothing ? 0 : sum(length, traffic_evaluation.assignments_by_time),
        "offered_mbps" => round(traffic_totals.offered_mbps, digits=3),
        "carried_mbps" => round(traffic_totals.carried_mbps, digits=3),
        "dropped_mbps" => round(traffic_totals.dropped_mbps, digits=3),
    )
end

# catalog 优先取 TLE：先查 :<name>_tle / :<name> 是否 TLEConstellationConfig，
# 否则读工具参数 tle（文件路径或 TLE 文本），最后回退报错。
# max_sats 限制加载的卫星数（catalog TLE 文件可能含上万颗）。
function _resolve_tle(constellation::AbstractString, args::AbstractDict; max_sats::Int=24)
    # catalog 优先
    for sym in (Symbol(constellation), Symbol("$(constellation)_tle"))
        try
            cfg = resolve_constellation(sym)
            if cfg isa TLEConstellationConfig && isfile(cfg.tle_path)
                return _load_tle_file(cfg.tle_path; max_sats=max_sats)
            end
        catch; end
    end
    # 参数兜底：tle 字段可为文件路径或 TLE 文本。
    # 含换行的内容按文本解析；isfile 对超长字符串会抛 ENAMETOOLONG，不能裸调。
    if haskey(args, "tle")
        tle = string(args["tle"])
        is_path = !occursin('\n', tle) && try
            isfile(tle)
        catch
            false
        end
        return is_path ? _load_tle_file(tle; max_sats=max_sats) :
                         _load_tle_lines(split(tle, '\n'); max_sats=max_sats)
    end
    return error("tle_based 传播器需要 TLE 数据：catalog 无 '$(constellation)_tle' 预设，且未传 tle 参数")
end

# 从 TLE 行列表构造 Vector{TLEOrbitElementSet}（3 行一组：名称+line1+line2）。
# max_sats 限制卫星数，避免对上万颗的真实 TLE 全量计算。
function _load_tle_lines(lines::AbstractVector{<:AbstractString}; max_sats::Int=typemax(Int))
    tles = TLEOrbitElementSet[]
    i = 1
    while i + 2 <= length(lines) && length(tles) < max_sats
        push!(tles, TLEOrbitElementSet(lines[i], lines[i+1], lines[i+2]))
        i += 3
    end
    isempty(tles) && error("TLE 解析失败：未找到完整的 3 行记录")
    return tles
end

_load_tle_file(path::AbstractString; max_sats::Int=typemax(Int)) =
    _load_tle_lines(readlines(path); max_sats=max_sats)

# 工具：参数扫描
function _tool_scan_parameter(args::AbstractDict)
    base = get(args, "base_constellation", "walker 24/6/1")
    param = get(args, "param", "alt_km")
    values = get(args, "values", [400, 550, 800, 1200])

    base_cfg = parse_ai_constellation(base)
    T, P, F, alt, inc = base_cfg.T, base_cfg.P, base_cfg.F, base_cfg.alt_km, base_cfg.inc_deg
    results = []

    for v in values
        try
            kw = Dict(:T => T, :P => P, :F => F, :alt_km => alt, :inc_deg => inc)
            if param == "alt_km"; kw[:alt_km] = Float64(v)
            elseif param == "inc_deg"; kw[:inc_deg] = Float64(v)
            elseif param == "P"; kw[:P] = Int(v); kw[:T] = T ÷ P * Int(v)
            elseif param == "T"; kw[:T] = Int(v)
            end
            cfg = ExperimentConfig(;
                name = "scan_$param=$v",
                constellation = WalkerConstellationConfig(; kw...),
                tspan = [0.0, 60.0],
            )
            r = run_experiment(cfg)
            push!(results, Dict(
                string(param) => v,
                "coverage" => round(r.coverage.coverage_ratio, digits=4),
                "avg_latency_ms" => round(r.latency.avg_latency_ms, digits=2),
                "connectivity" => round(r.network.connectivity_ratio, digits=4),
            ))
        catch e
            push!(results, Dict(string(param) => v, "error" => string(e)))
        end
    end

    return Dict("param" => param, "results" => results)
end

# 工具：星座对比
function _tool_compare_constellations(args::AbstractDict)
    names = get(args, "constellations", ["iridium", "starlink_gen1"])
    results = []

    for name in names
        try
            cfg = resolve_constellation(Symbol(name))
            T = cfg isa WalkerConstellationConfig ? cfg.T : 66
            P = cfg isa WalkerConstellationConfig ? cfg.P : 6
            F = cfg isa WalkerConstellationConfig ? cfg.F : 2
            alt = cfg isa WalkerConstellationConfig ? cfg.alt_km : 780.0
            inc = cfg isa WalkerConstellationConfig ? cfg.inc_deg : 86.4
            ec = ExperimentConfig(;
                name = name,
                constellation = WalkerConstellationConfig(T=T, P=P, F=F, alt_km=alt, inc_deg=inc),
                tspan = [0.0, 60.0],
            )
            r = run_experiment(ec)
            push!(results, Dict(
                "name" => name,
                "T" => T,
                "coverage" => round(r.coverage.coverage_ratio, digits=4),
                "avg_latency_ms" => round(r.latency.avg_latency_ms, digits=2),
                "connectivity" => round(r.network.connectivity_ratio, digits=4),
            ))
        catch e
            push!(results, Dict("name" => name, "error" => string(e)))
        end
    end

    return Dict("comparison" => results)
end

# 工具：列出可用资源
function _tool_list_available(args::AbstractDict)
    what = String(get(args, "what", "all"))
    result = Dict{String,Any}()
    if what in ("constellations", "all")
        result["constellations"] = ai_constellation_names()
    end
    if what in ("topologies", "all")
        result["topologies"] = ai_topology_terms()
    end
    if what in ("propagators", "all")
        result["propagators"] = ai_propagator_terms()
    end
    if what in ("routing", "all")
        result["routing"] = ai_routing_terms()
        result["routing_catalog"] = [
            Dict("id" => string(id), "description" => SatelliteSimCore.describe_routing(id))
            for id in SatelliteSimCore.list_routing()
        ]
        result["routing_note"] = "routing catalog 仅用于发现说明；执行时通过 Lab routing intent / ExperimentConfig 解析。"
    end
    if what in ("traffic", "all")
        result["traffic"] = ai_traffic_terms()
        result["traffic_catalog"] = [
            Dict("id" => string(id), "description" => SatelliteSimCore.describe_traffic(id))
            for id in SatelliteSimCore.list_traffic()
        ]
    end
    if what in ("intents", "all")
        result["intents"] = Dict(
            "routing" => ai_routing_terms(),
            "traffic" => ai_traffic_terms(),
            "topology" => ai_topology_terms(),
            "propagator" => ai_propagator_terms(),
        )
    end
    return result
end

# ─── 辅助解析函数 ───

# 记录工具调用到三层记忆（单一真相源：复用 memory.jl 的 record_result! + _summarize_entry）。
# 同时维护内存态 scanned_params（作为 prompt 动态区的回退，当 memory.index 为空时）。
function _record_scanned!(agent::SimAgent, tool::String, args::AbstractDict, result::AbstractString)
    # 三层记忆：Layer 3 transcript append + Layer 1 index 摘要（落盘）
    record_result!(agent.memory, tool, args, result)
    # 内存态回退（与 memory.index 内容一致，但常驻内存供 prompt 快速展示）
    summary = _summarize_entry(tool, args, result)
    summary === nothing || push!(agent.scanned_params, summary)
    return agent
end

function _parse_constellation(s::String)
    cfg = parse_ai_constellation(s)
    return cfg.T, cfg.P, cfg.F, cfg.alt_km, cfg.inc_deg
end

# ─── 意图符号 → 实现类型（统一桥接正式意图层，不再平行实现）───
#
# 历史：这里曾有一套与 intent.jl 不一致的拓扑/传播器词表（如 "robust"→Honeycomb，
# 而 intent 层 HighRobustTopo→GridPlus）。现已统一为：LLM schema 符号 → 意图类型 →
# resolve_topology/resolve_propagator。意图层是单一真相源（见 intent_resolution.jl）。
#
# 行为变更（已声明，非静默）：
#   - "robust"  从 HoneycombStrategy 改为 intent 层 HighRobustTopo→GridPlusStrategy
#   - "adaptive" 原映射 NearestNeighborStrategy，intent 层无对应意图，退化为 BalancedTopo
#   - "minimal" → intent 层 LowCostTopo→RingStrategy（与原 Ring 一致）
#   - "tle_based" 从假 TwoBodyPropagator 改为 :sgp4 标记，由 _tool_run_simulation 走真实 SGP4

# LLM schema 符号 → 拓扑意图类型（T 用于 LowLatencyTopo 的小星座分派）
function _topology_intent(s::AbstractString)
    s == "balanced"  && return BalancedTopo()
    s == "robust"    && return HighRobustTopo()
    s == "minimal"   && return LowCostTopo()
    s == "adaptive"  && return BalancedTopo()   # intent 层无最近邻意图，退化为均衡
    # 向后兼容旧实现符号
    s == "gridplus"  && return BalancedTopo()
    s == "tshape"    && return BalancedTopo()
    return BalancedTopo()
end

# LLM schema 符号 → 传播器意图类型
function _propagator_intent(s::AbstractString)
    s == "fast"      && return SpeedFocus()
    s == "balanced"  && return BalancedProp()
    s == "precise"   && return PrecisionFocus()
    s == "tle_based" && return TleBasedProp()
    # 向后兼容旧实现符号
    s == "twobody"   && return SpeedFocus()
    s == "j2"        && return BalancedProp()
    s == "j4"        && return PrecisionFocus()
    return SpeedFocus()
end

# 通过统一 AI 输入层解析拓扑/传播器；保留旧私有函数名以兼容内部调用。
_parse_topology(s::AbstractString, T::Int) = parse_ai_topology(s, T)
_parse_propagator(s::AbstractString) = parse_ai_propagator(s)

# ─── REPL 入口 ───

"""
    agent_repl(provider; greeting)

启动交互式 AI 仿真助手 REPL。

```julia
using SatelliteSimLab
agent_repl(LLMProvider())
```
"""
function agent_repl(provider::LLMProvider; greeting::Bool = true)
    agent = SimAgent(provider)
    greeting && println("""
    ╔══════════════════════════════════════╗
    ║   SatelliteSim AI 仿真助手           ║
    ║   输入自然语言描述你想做的仿真        ║
    ║   输入 /exit 退出                    ║
    ╚══════════════════════════════════════╝
    """)

    while true
        print("\n🛰️ > ")
        input = readline()
        isempty(input) && continue
        startswith(input, "/exit") && break
        startswith(input, "/clear") && (agent = SimAgent(provider); println("（已重置）"); continue)

        try
            reply = run_agent(agent, input)
            println("\n🤖 $reply")
        catch e
            println("\n❌ 错误: $e")
        end
    end
    println("再见！")
end

"""
    voice_agent_repl(provider; greeting)

语音友好的 REPL：默认用更短的回复风格，适合搭配 TTS / 语音桥。
"""
function voice_agent_repl(provider::LLMProvider; greeting::Bool = true)
    agent = SimAgent(provider; reply_style = :voice)
    greeting && println("""
    ╔══════════════════════════════════════╗
    ║   SatelliteSim 语音模式              ║
    ║   短句回复 / 适合 TTS                ║
    ║   输入 /exit 退出                    ║
    ╚══════════════════════════════════════╝
    """)

    while true
        print("\n🎙️ > ")
        input = readline()
        isempty(input) && continue
        startswith(input, "/exit") && break
        startswith(input, "/clear") && (agent = SimAgent(provider; reply_style = :voice); println("（已重置）"); continue)

        try
            reply = run_agent(agent, input)
            println("\n🤖 $reply")
        catch e
            println("\n❌ 错误: $e")
        end
    end
    println("再见！")
end
