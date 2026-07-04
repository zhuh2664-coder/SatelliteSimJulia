"""
    dra.jl — DRA (Directional Routing Algorithm) 方向路由

铱星(Iridium)实际使用的路由算法核心。
每颗卫星仅根据源-目的轨道面差和位置差决定转发方向。

方向编码 (2-bit):
  00 = 面内向前 (同一轨道面，sat_id+1)
  01 = 面内向后 (同一轨道面，sat_id-1)
  10 = 面间左转 (相邻轨道面左)
  11 = 面间右转 (相邻轨道面右)

路由信息在包头用 3-bit 携带：
  <DIR[1:0], MS/RS>
  DIR = 转发方向
  MS = Mesh Satellite (简单转发)
  RS = Router Satellite (需计算路由)
"""
const DIR_FWD  = UInt8(0b00)  # 面内向前
const DIR_BACK = UInt8(0b01)  # 面内向后
const DIR_LEFT = UInt8(0b10)  # 面间左转
const DIR_RIGHT= UInt8(0b11)  # 面间右转

const MS = UInt8(0)  # Mesh Satellite
const RS = UInt8(1)  # Router Satellite

struct DraHeader
    dir::UInt8       # 2-bit: 转发方向
    node_type::UInt8 # 1-bit: MS=0, RS=1
end

"""
    DraState — 卫星的 DRA 路由状态

每颗卫星维护：
- 自己的轨道位置 (plane, position)
- 星座拓扑参数 (总面数, 面内星数)
- 可选：邻居状态 (链路可用性)
"""
mutable struct DraState
    my_plane::Int
    my_pos::Int
    total_planes::Int
    sats_per_plane::Int
    neighbor_up::Dict{Int, Bool}  # neighbor_id → 是否可用
end

function DraState(plane::Int, pos::Int, n_planes::Int, n_per_plane::Int)
    state = DraState(plane, pos, n_planes, n_per_plane, Dict{Int,Bool}())
    # 初始化 4 个邻居
    state.neighbor_up = Dict(
        0 => true,  # forward
        1 => true,  # backward
        2 => true,  # left
        3 => true,  # right
    )
    return state
end

"""
    dra_route(state, dst_plane, dst_pos) → (dir, node_type)

DRA 核心路由决策：给定目的轨道位置，返回转发方向。
"""
function dra_route(state::DraState, dst_plane::Int, dst_pos::Int)
    d_plane = dst_plane - state.my_plane
    d_pos = dst_pos - state.my_pos

    # 考虑环绕
    if abs(d_plane) > state.total_planes ÷ 2
        d_plane = -sign(d_plane) * (state.total_planes - abs(d_plane))
    end
    if abs(d_pos) > state.sats_per_plane ÷ 2
        d_pos = -sign(d_pos) * (state.sats_per_plane - abs(d_pos))
    end

    # DRA 决策逻辑
    if d_pos != 0
        # 优先面内到达同一位置
        dir = d_pos > 0 ? DIR_FWD : DIR_BACK
    elseif d_plane != 0
        # 面间移动
        dir = d_plane > 0 ? DIR_RIGHT : DIR_LEFT
    else
        # 已到达
        return (nothing, MS)
    end

    # 检查链路是否可用
    dir_int = Int(dir)
    if get(state.neighbor_up, dir_int, true)
        return (dir, MS)  # 直接转发
    else
        # 链路故障 → 升级为 RS，重新计算
        return (dir, RS)
    end
end

"""
    dra_reroute(state, failed_dir) → new_dir

DRA 快速重路由：某方向链路故障时选择替代方向。
"""
function dra_reroute(state::DraState, failed_dir::UInt8)
    # 替代路径：先经过相邻轨道面再绕行
    alternatives = [
        [DIR_LEFT, DIR_RIGHT],   # if forward fails
        [DIR_RIGHT, DIR_LEFT],   # if backward fails
        [DIR_FWD, DIR_BACK],     # if left fails
        [DIR_FWD, DIR_BACK],     # if right fails
    ]
    for alt in alternatives[Int(failed_dir) + 1]
        if get(state.neighbor_up, Int(alt), true)
            return alt
        end
    end
    return nothing  # 无可用替代路径
end
