# ============================================================
# 会话管理：session_id → 预算位置数组 + 预生成 ISL 边集
# ============================================================
#
# 设计：
#   start_simulation 一次性算完整个 tspan 的 N×T×3 位置数组，
#   同时调 generate_topology 拿候选 ISL 边。
#   推流时只做单帧切片 + evaluate_isl_batch（轻量）。
#
# 数据流：
#   generate_walker_delta → propagate_to_ecef → positions[N,T,3]
#                                                + isl_candidate_edges
#   推流：positions[:, t, :] + evaluate_isl_batch → frame
#
# 全程裸数组路径，不碰 ConstellationEphemeris 强类型。
# ============================================================

using Random
using SatelliteSimCore
using SatelliteSimNet

# ── 会话状态 ────────────────────────────────────────────────

"""
会话：持有一个仿真会话的全部预算状态。

字段：
- `id::String`               会话唯一 ID
- `name::String`             catalog 星座名
- `positions::Array{Float64,3}` ECEF km，形状 (N, T, 3)
- `isl_edges::Vector{Tuple{Int,Int}}`  候选 ISL 边（1-based 卫星索引对）
- `step_s::Float64`          每帧间隔秒
- `tspan::Vector{Float64}`   仿真时间区间
- `constraints`              ISL 物理约束（LEO_DEFAULTS）
- `active::Ref{Bool}`        是否仍活跃（推流循环检查）
- `frame_index::Ref{Int}`    下一个要推的帧序号（1-based）
- `fps::Float64`             目标推流帧率
"""
mutable struct SimulationSession
    id::String
    name::String
    positions::Array{Float64,3}
    isl_edges::Vector{Tuple{Int,Int}}
    step_s::Float64
    tspan::Vector{Float64}
    constraints
    active::Base.RefValue{Bool}
    frame_index::Base.RefValue{Int}
    fps::Float64
end

# 全局会话表（沙盒场景：单服务实例，少量并发会话）
const SESSIONS = Dict{String,SimulationSession}()

# ── 生成时间网格 ────────────────────────────────────────────

"""
根据 tspan 和 step_s 生成时间向量（秒）。
返回 [tspan[1], tspan[1]+step, ..., ≤ tspan[2]]。
"""
function make_tspan(tspan::AbstractVector{<:Real}, step_s::Real)
    t0, t1 = Float64(tspan[1]), Float64(tspan[2])
    t0 < t1 || throw(ArgumentError("tspan[1] must be < tspan[2], got $tspan"))
    step_s > 0 || throw(ArgumentError("step_s must be > 0, got $step_s"))
    return collect(t0:step_s:t1)
end

# ── 启动会话：预算位置 + ISL 边集 ───────────────────────────

"""
    start_session(name; tspan, step_s, propagator, fps) -> SimulationSession

预算一个星座的完整仿真状态并存入 SESSIONS。

参数：
- `name`     catalog 星座符号字符串（如 "iridium"）
- `tspan`    时间区间 [t0, t1] 秒
- `step_s`   帧间隔秒
- `propagator`  传播器名 "two_body"/"j2"/"j4"
- `fps`      目标推流帧率

返回新建的 SimulationSession。
"""
function start_session(;
    name::AbstractString,
    tspan::AbstractVector{<:Real} = [0.0, 600.0],
    step_s::Real = 10.0,
    propagator::AbstractString = "j2",
    fps::Real = 10.0,
)
    # 1. 解析 catalog 配置
    sym = Symbol(name)
    config = resolve_constellation(sym)  # WalkerConstellationConfig 或 TLE

    # 当前只支持 Walker；TLE 需走 SGP4，后续接入
    config isa WalkerConstellationConfig ||
        throw(ArgumentError("only Walker constellations supported for now; got $(typeof(config))"))

    T, P, F = config.T, config.P, config.F
    alt_km, inc_deg = config.alt_km, config.inc_deg

    # 2. 生成轨道根数
    elems = generate_walker_delta(; T = T, P = P, F = F, alt_km = alt_km, inc_deg = inc_deg)

    # 3. 预算位置数组（一次性算完整个 tspan）
    ts = make_tspan(tspan, step_s)
    # propagate_to_ecef 接受 Symbol: :two_body | :j2 | :j4（内部 resolve_keplerian_propagator）
    positions = propagate_to_ecef(elems, ts; propagator = Symbol(propagator))

    # 4. 预生成 ISL 候选边（GridPlus 拓扑，固定）
    topo = generate_topology(GridPlusStrategy(), T, P)
    isl_edges = vcat(topo.static_links, topo.dynamic_candidates)

    # 5. 建会话
    session_id = randstring(8)
    session = SimulationSession(
        session_id,
        String(name),
        positions,
        isl_edges,
        Float64(step_s),
        Float64.(tspan),
        LEO_DEFAULTS,
        Ref(true),
        Ref(1),
        Float64(fps),
    )
    SESSIONS[session_id] = session
    return session
end

"""停止会话（标记为不活跃，推流循环会自行退出；从 SESSIONS 移除）。"""
function stop_session!(session_id::AbstractString)
    session = get(SESSIONS, session_id, nothing)
    session === nothing && return false
    session.active[] = false
    delete!(SESSIONS, session_id)
    return true
end

get_session(session_id::AbstractString) = get(SESSIONS, session_id, nothing)

n_satellites(s::SimulationSession) = size(s.positions, 1)
n_timesteps(s::SimulationSession) = size(s.positions, 2)
