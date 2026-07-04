# ===== SatelliteServer：每颗卫星的服务器状态 =====
#
# 每颗卫星 = 一个 SatelliteServer 实例（在独立 worker 进程中运行）。
# 封装该星的：轨道根数、卫星 id、ISL 邻居、当前位置/速度。
#
# 设计原则：
#   - 轨道传播：每星独立，零跨星依赖（只需自己的根数 + tspan）
#   - ISL 评估：需邻居位置（通过协调进程广播获取）
#   - 本地状态：当前位置/速度，每步更新

export SatelliteServer, propagate_server, evaluate_local_isls, init_server

"""
    SatelliteServer

一颗卫星的服务器状态（在独立 worker 进程中运行）。

# 字段
- `sat_id::Int`: 卫星编号（1..T）
- `elements`: 该星的轨道根数（KeplerianElements）
- `isl_neighbors::Vector{Int}`: ISL 邻居卫星 id 列表（由拓扑策略决定）
- `current_position::Vector{Float64}`: 当前 ECEF 位置 [x,y,z]（km）
- `current_velocity::Vector{Float64}`: 当前 ECEF 速度（km/s，可选）
- `plane::Int`: 轨道面编号
- `slot::Int`: 面内槽位编号
"""
Base.@kwdef mutable struct SatelliteServer
    sat_id::Int
    elements::Any                    # KeplerianElements（避免跨进程类型依赖，用 Any）
    isl_neighbors::Vector{Int}
    current_position::Vector{Float64} = [0.0, 0.0, 0.0]
    current_velocity::Vector{Float64} = [0.0, 0.0, 0.0]
    plane::Int = 0
    slot::Int = 0
end

"""
    init_server(sat_id, elements, strategy, T, P) -> SatelliteServer

初始化一颗卫星的服务器。计算 ISL 邻居（本地，不需其他星位置）。
"""
function init_server(sat_id::Int, elements, strategy, T::Int, P::Int)
    S = div(T, P)
    neighbors = isl_neighbors(strategy, sat_id, T, P)
    plane = (sat_id - 1) ÷ S + 1
    slot = (sat_id - 1) % S + 1
    return SatelliteServer(sat_id=sat_id, elements=elements, isl_neighbors=neighbors,
                           plane=plane, slot=slot)
end

"""
    propagate_server(server::SatelliteServer, t_sec; propagator) -> Vector{Float64}

传播该星到 t_sec，更新 current_position。返回新位置（ECEF km）。
每星独立传播，零跨星依赖。
"""
function propagate_server(server::SatelliteServer, t_sec::Real; propagator=TwoBodyPropagator())
    # 用 propagate_to_ecef 传播单颗星到单个时刻
    elems = [server.elements]
    pos = propagate_to_ecef(elems, [0.0, Float64(t_sec)]; propagator=propagator)
    # pos 是 1×2×3，取第二个时刻（t_sec）
    server.current_position = [pos[1, 2, 1], pos[1, 2, 2], pos[1, 2, 3]]
    return server.current_position
end

"""
    evaluate_local_isls(server::SatelliteServer, neighbor_positions::Dict{Int,Vector{Float64}}, constraints) -> Vector{Tuple{Int,Bool,Float64}}

评估该星的所有本地 ISL 边。
返回 [(邻居id, 是否可用, 时延ms), ...]。

# 参数
- `neighbor_positions`: 邻居 id → 位置 的字典（由协调进程广播提供）
- `constraints`: 物理约束（距离/LOS 等）
"""
function evaluate_local_isls(server::SatelliteServer,
                             neighbor_positions::Dict{Int,Vector{Float64}},
                             constraints=LEO_DEFAULTS)
    results = Tuple{Int,Bool,Float64}[]
    pos_a = (server.current_position[1], server.current_position[2], server.current_position[3])

    for nb_id in server.isl_neighbors
        haskey(neighbor_positions, nb_id) || continue
        pos_b = neighbor_positions[nb_id]
        pos_b_t = (pos_b[1], pos_b[2], pos_b[3])

        # 用现有 evaluate_isl 评估（返回 tuple: (available, distance, los, delay_ms, details)）
        avail, _dist, _los, delay_ms, _details = evaluate_isl(pos_a, pos_b_t; constraints=constraints)
        push!(results, (nb_id, avail, delay_ms))
    end
    return results
end
