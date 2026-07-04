# ===== 链路类型参数 =====
abstract type LinkType end
struct ISL <: LinkType end    # 星间链路
struct GSL <: LinkType end    # 星地链路
struct GGL <: LinkType end    # 地面站间链路
struct GUL <: LinkType end    # 接入链路（地面站→用户）
struct USL <: LinkType end    # 用户直连链路
struct UUL <: LinkType end    # 用户间链路

# ===== 统一链路（静态） =====
struct Link{T<:LinkType}
    id::String
    source_id::String
    target_id::String
    max_bandwidth_forward::Float64
    max_bandwidth_reverse::Float64
    link_type::T
end

# ===== 统一链路状态（动态） =====
mutable struct LinkState
    link_id::String
    distance_km::Float64
    elevation_deg::Union{Float64, Nothing}
    latency_ms::Float64
    available_bandwidth_forward::Float64
    available_bandwidth_reverse::Float64
    azimuth_deg::Union{Float64, Nothing}      # 目标卫星的方位角
    terminal_id::Union{Int, Nothing}          # 使用哪个终端（1=前,2=后,3=左,4=右）
    duration_s::Union{Float64, Nothing}       # 预计持续时长
end

# ===== 便捷构造函数 =====
Link(id, src, dst, bw; typ=ISL()) = Link(id, src, dst, bw, bw, typ)
Link(id, src, dst, fwd, rev; typ=ISL()) = Link(id, src, dst, fwd, rev, typ)
LinkState(id; dist=0.0, el=nothing, lat=0.0, fwd=0.0, rev=0.0,
           azimuth=nothing, terminal=nothing, duration=nothing) =
    LinkState(id, dist, el, lat, fwd, rev, azimuth, terminal, duration)
