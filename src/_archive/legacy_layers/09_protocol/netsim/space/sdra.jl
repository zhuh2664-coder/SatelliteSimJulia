"""
    sdra.jl — SDRA (Semi-Distributed Routing Algorithm)

DRA 的改进版。每隔 K 跳设置一个 RS (Router Satellite)，
RS 负责计算后续路径，MS (Mesh Satellite) 只按 DRA 方向转发。

优势：比 DRA 更优的路径选择 + 比完整路由表更低的计算开销。
"""
const SDRA_K = 3  # 每隔 K 跳设置一个 RS

mutable struct SdraState
    my_plane::Int
    my_pos::Int
    total_planes::Int
    sats_per_plane::Int
    neighbor_up::Dict{Int, Bool}
    k::Int                    # RS 间隔
    hop_count::Int            # 当前包已跳数
    is_rs::Bool               # 是否是 Router Satellite
end

function SdraState(plane::Int, pos::Int, n_planes::Int, n_per_plane::Int; k=SDRA_K)
    # 判断是否是 RS：每隔 k 颗星一个
    is_rs = (pos % k == 0) || (pos == 1)

    state = SdraState(plane, pos, n_planes, n_per_plane,
                      Dict(0=>true, 1=>true, 2=>true, 3=>true),
                      k, 0, is_rs)
    return state
end

"""
    sdra_forward(state, packet)

SDRA 转发决策。

如果一个包从 MS 经过：
  → 按 DRA 方向转发
  → hop_count + 1
  → 如果 hop_count >= k → 升级为 RS 行为

如果一个包到达 RS：
  → 调用 DRA 或本地路由表重新计算最优路径
  → 重置 hop_count = 0
"""
function sdra_forward(sdra::SdraState, dst_plane::Int, dst_pos::Int,
                      current_hop::Int)
    # 检查是否需要重新路由
    if sdra.is_rs || current_hop >= sdra.k
        # RS 或已到重路由点：执行完整 DRA
        dir, _ = dra_route(
            DraState(sdra.my_plane, sdra.my_pos,
                     sdra.total_planes, sdra.sats_per_plane,
                     sdra.neighbor_up),
            dst_plane, dst_pos
        )
        return (dir, RS, 0)  # 重置跳数
    else
        # MS：简单转发
        dir, _ = dra_route(
            DraState(sdra.my_plane, sdra.my_pos,
                     sdra.total_planes, sdra.sats_per_plane,
                     sdra.neighbor_up),
            dst_plane, dst_pos
        )
        return (dir, MS, current_hop + 1)
    end
end
