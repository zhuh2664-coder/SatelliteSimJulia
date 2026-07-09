# ============================================================
# 协议层：WebSocket 文本帧（JSON）的 5 类消息
# ============================================================
#
# 信封格式：每条消息都有 `type` 字段，分发依据。
#
#   请求：    {type, ...payload}
#   响应：    {type = "<req>_response", ok, ...payload}
#   帧推流：  {type = "frame", session_id, t, positions, isl_pairs, isl_avail}
#   错误：    {type = "error", message}
#
# 5 个 endpoint：
#   list_constellations   →  list_constellations_response
#   describe_constellation →  describe_constellation_response
#   start_simulation      →  start_simulation_response（之后开始推 frame）
#   stop_simulation       →  stop_simulation_response
#   (frame 由服务端主动推)
#
# 字段约定：
#   positions   展平的 Float64 数组 [x1,y1,z1, x2,y2,z2, ...]，单位 km，ECEF
#   isl_pairs   候选 ISL 边 [[i,j], ...]，1-based 卫星索引
#   isl_avail   与 isl_pairs 等长的 Bool 数组，本帧是否可用
#   t           当前帧距 epoch 秒数
# ============================================================

using JSON3
using StructTypes

# ── 请求消息 ────────────────────────────────────────────────

abstract type Request end

Base.@kwdef struct ListConstellationsReq <: Request
    type::String = "list_constellations"
end

Base.@kwdef struct DescribeConstellationReq <: Request
    type::String = "describe_constellation"
    name::String
end

Base.@kwdef struct GroundStationSpec
    id::String
    name::String
    lat_deg::Float64
    lon_deg::Float64
    alt_km::Float64 = 0.0
end

Base.@kwdef struct WalkerSpec
    T::Int
    P::Int
    F::Int
    alt_km::Float64
    inc_deg::Float64
end

Base.@kwdef struct StartSimulationReq <: Request
    type::String = "start_simulation"
    name::String                      # catalog 符号；custom Walker 时作为显示名
    walker::Union{Nothing,WalkerSpec} = nothing
    tspan::Vector{Float64} = [0.0, 600.0]
    step_s::Float64 = 10.0
    propagator::String = "j2"         # "two_body" | "j2" | "j4"
    fps::Float64 = 10.0               # 推流目标帧率
    ground_stations::Vector{GroundStationSpec} = GroundStationSpec[]
    include_gsl::Bool = true
    include_coverage::Bool = true
end

Base.@kwdef struct StopSimulationReq <: Request
    type::String = "stop_simulation"
    session_id::String
end

Base.@kwdef struct AITraceReq <: Request
    type::String = "ai_trace"
    session_id::String
    mode::String = "timeline"          # "timeline" | "replay_plan"
end

Base.@kwdef struct AICheckpointReq <: Request
    type::String = "ai_checkpoint"
    session_id::String
end

# ── 响应消息 ────────────────────────────────────────────────

Base.@kwdef struct ListConstellationsResp
    type::String = "list_constellations_response"
    ok::Bool = true
    names::Vector{String}
end

Base.@kwdef struct DescribeConstellationResp
    type::String = "describe_constellation_response"
    ok::Bool = true
    name::String
    T::Int
    P::Int
    F::Int
    alt_km::Float64
    inc_deg::Float64
end

Base.@kwdef struct StartSimulationResp
    type::String = "start_simulation_response"
    ok::Bool = true
    session_id::String
    n_sat::Int
    n_time::Int
    fps::Float64
    step_s::Float64
    tspan::Vector{Float64}
    n_ground_stations::Int = 0
    gsl_enabled::Bool = false
    coverage_enabled::Bool = false
    constellation::Dict{String,Any} = Dict{String,Any}()
    shells::Vector{Dict{String,Any}} = Dict{String,Any}[]
end

Base.@kwdef struct StopSimulationResp
    type::String = "stop_simulation_response"
    ok::Bool = true
    session_id::String
end

Base.@kwdef struct AITraceResp
    type::String = "ai_trace_response"
    ok::Bool = true
    session_id::String
    mode::String
    items::Vector{String}
end

Base.@kwdef struct AICheckpointResp
    type::String = "ai_checkpoint_response"
    ok::Bool = true
    session_id::String
    summary_json::String
end

Base.@kwdef struct ErrorResponse
    type::String = "error"
    message::String
end

# ── 推流帧（动态构造，不在 StructTypes 注册，用 JSON3.write 手写） ──
#   见 streamer.jl 的 frame_payload

# ── StructTypes 注册：用 kwdef 构造，JSON3 能自动 round-trip ──

StructTypes.StructType(::Type{ListConstellationsReq}) = StructTypes.Struct()
StructTypes.StructType(::Type{DescribeConstellationReq}) = StructTypes.Struct()
StructTypes.StructType(::Type{GroundStationSpec}) = StructTypes.Struct()
StructTypes.StructType(::Type{WalkerSpec}) = StructTypes.Struct()
StructTypes.StructType(::Type{StartSimulationReq}) = StructTypes.Struct()
StructTypes.StructType(::Type{StopSimulationReq}) = StructTypes.Struct()
StructTypes.StructType(::Type{AITraceReq}) = StructTypes.Struct()
StructTypes.StructType(::Type{AICheckpointReq}) = StructTypes.Struct()

StructTypes.StructType(::Type{ListConstellationsResp}) = StructTypes.Struct()
StructTypes.StructType(::Type{DescribeConstellationResp}) = StructTypes.Struct()
StructTypes.StructType(::Type{StartSimulationResp}) = StructTypes.Struct()
StructTypes.StructType(::Type{StopSimulationResp}) = StructTypes.Struct()
StructTypes.StructType(::Type{AITraceResp}) = StructTypes.Struct()
StructTypes.StructType(::Type{AICheckpointResp}) = StructTypes.Struct()
StructTypes.StructType(::Type{ErrorResponse}) = StructTypes.Struct()

# ── 解析入口：按 type 字段分发到对应 Request 构造器 ──────────

function _parse_ground_station_specs(items)
    specs = GroundStationSpec[]
    for (idx, gs) in enumerate(items)
        id = haskey(gs, :id) ? String(gs.id) : string(idx)
        name = haskey(gs, :name) ? String(gs.name) : id
        alt_km = haskey(gs, :alt_km) ? Float64(gs.alt_km) : 0.0
        push!(specs, GroundStationSpec(
            id = id,
            name = name,
            lat_deg = Float64(gs.lat_deg),
            lon_deg = Float64(gs.lon_deg),
            alt_km = alt_km,
        ))
    end
    return specs
end

function _parse_walker_spec(w)
    return WalkerSpec(
        T = Int(w.T),
        P = Int(w.P),
        F = Int(w.F),
        alt_km = Float64(w.alt_km),
        inc_deg = Float64(w.inc_deg),
    )
end

"""
    parse_request(json_str) -> Request

按 `type` 字段把 JSON 字符串解析为具体请求类型。
未识别的 type 抛 ArgumentError。
"""
function parse_request(s::AbstractString)
    obj = JSON3.read(s)
    t = get(obj, :type, nothing)
    if t == "list_constellations"
        return ListConstellationsReq()
    elseif t == "describe_constellation"
        return DescribeConstellationReq(name = String(obj.name))
    elseif t == "start_simulation"
        # 可选字段做容错（客户端可能省略使用默认值）
        kwargs = Dict{Symbol,Any}(:name => haskey(obj, :name) ? String(obj.name) : "custom_walker")
        haskey(obj, :walker) && (kwargs[:walker] = _parse_walker_spec(obj.walker))
        haskey(obj, :tspan) && (kwargs[:tspan] = Float64.(obj.tspan))
        haskey(obj, :step_s) && (kwargs[:step_s] = Float64(obj.step_s))
        haskey(obj, :propagator) && (kwargs[:propagator] = String(obj.propagator))
        haskey(obj, :fps) && (kwargs[:fps] = Float64(obj.fps))
        haskey(obj, :ground_stations) && (kwargs[:ground_stations] = _parse_ground_station_specs(obj.ground_stations))
        haskey(obj, :include_gsl) && (kwargs[:include_gsl] = Bool(obj.include_gsl))
        haskey(obj, :include_coverage) && (kwargs[:include_coverage] = Bool(obj.include_coverage))
        return StartSimulationReq(; kwargs...)
    elseif t == "stop_simulation"
        return StopSimulationReq(session_id = String(obj.session_id))
    elseif t == "ai_trace"
        kwargs = Dict{Symbol,Any}(:session_id => String(obj.session_id))
        haskey(obj, :mode) && (kwargs[:mode] = String(obj.mode))
        return AITraceReq(; kwargs...)
    elseif t == "ai_checkpoint"
        return AICheckpointReq(session_id = String(obj.session_id))
    else
        throw(ArgumentError("unknown request type: $(repr(t))"))
    end
end
