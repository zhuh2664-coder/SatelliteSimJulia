# ===== AI tool input vocabulary =====
#
# AI-facing 词表和解析函数。所有 LLM 工具应复用这里，避免 schema、list_available
# 和实际解析逻辑三处漂移。

export ai_constellation_names, ai_topology_terms, ai_propagator_terms,
       parse_ai_constellation, parse_ai_topology, parse_ai_propagator

ai_topology_terms() = ["balanced", "robust", "minimal", "adaptive"]
ai_propagator_terms() = ["fast", "balanced", "precise", "tle_based"]
ai_constellation_names() = list_constellations()

function parse_ai_constellation(s::AbstractString)::WalkerConstellationConfig
    s = strip(String(s))
    if startswith(lowercase(s), "walker")
        rest = strip(s[7:end])
        parts = split(rest, r"[/\s]+")
        isempty(parts) && error("walker 星座格式应为 'walker T/P/F'")
        T = parse(Int, parts[1])
        P = length(parts) > 1 ? parse(Int, parts[2]) : 6
        F = length(parts) > 2 ? parse(Int, parts[3]) : 1
        return WalkerConstellationConfig(T=T, P=P, F=F, alt_km=550.0, inc_deg=53.0)
    end

    try
        cfg = resolve_constellation(Symbol(s))
        cfg isa WalkerConstellationConfig || error("$s 不是 Walker 星座配置")
        return cfg
    catch e
        error("未知星座 '$s'。可用星座请调用 list_available(constellations)。原始错误: $(e)")
    end
end

function _ai_topology_intent(s::AbstractString)
    v = lowercase(strip(String(s)))
    v in ("balanced", "gridplus", "mesh", "tshape") && return BalancedTopo()
    v in ("robust", "high_robust") && return HighRobustTopo()
    v in ("minimal", "low_cost", "ring") && return LowCostTopo()
    v in ("adaptive", "nearest", "nearest_neighbor") && return BalancedTopo()
    error("未知拓扑词 '$s'。可用词: $(join(ai_topology_terms(), ", "))")
end

function parse_ai_topology(s::AbstractString, T::Int)::AbstractTopologyStrategy
    return resolve_topology(_ai_topology_intent(s), ResolutionContext(T=T))
end

function _ai_propagator_intent(s::AbstractString)
    v = lowercase(strip(String(s)))
    v in ("fast", "twobody", "two_body") && return SpeedFocus()
    v in ("balanced", "j2") && return BalancedProp()
    v in ("precise", "j4") && return PrecisionFocus()
    v in ("tle_based", "sgp4") && return TleBasedProp()
    error("未知传播器词 '$s'。可用词: $(join(ai_propagator_terms(), ", "))")
end

function parse_ai_propagator(s::AbstractString)::Union{AbstractKeplerianPropagator,Symbol}
    return resolve_propagator(_ai_propagator_intent(s), ResolutionContext())
end
