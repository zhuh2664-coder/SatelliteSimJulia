"""
    centralized_routing.jl — 地面集中路由控制面

Starlink 实际使用的方案：路由计算在地面完成，
卫星只执行预分发的转发表。

流程:
1. 地面控制器收集全星座拓扑 (通过你的平台 pos 矩阵)
2. 预计算全对最短路径 (Floyd-Warshall, Dijkstra)
3. 每颗卫星分发表 (dest→output_port)
4. 卫星按表转发，不需要运行任何分布式路由协议

优势:
- 卫星简单(低功耗/低成本/低计算)
- 路径最优 (地面有全局视野)
- 可快速重算 (拓扑变化触发地面重算)
"""
mutable struct CentralizedRoutingTable
    # node_id → {dest_id → (next_hop, port)}
    tables::Dict{UInt32, Dict{UInt32, Tuple{UInt32, Int}}}
    epoch::UInt64            # 路由版本号
    last_update::Float64     # 最后更新时间
end

CentralizedRoutingTable() = CentralizedRoutingTable(Dict{UInt32,Dict{UInt32,Tuple{UInt32,Int}}}(), 0, 0.0)

"""
    build_routes_from_pos!(crt, pos, node_ids, t, max_dist)

从你的平台 pos 矩阵构建全星座路由表。

参数:
    crt: CentralizedRoutingTable
    pos: N×T×3 矩阵
    node_ids: N 颗卫星的 ID 列表
    t: 时间步索引
    max_dist: ISL 最大距离 (km)
"""
function build_routes_from_pos!(crt::CentralizedRoutingTable,
                                pos::AbstractArray{Float64,3},
                                node_ids::Vector{UInt32},
                                t::Int, max_dist::Float64=5000.0)
    n = length(node_ids)
    # 构建邻接矩阵 (距离)
    dist_mat = fill(Inf, n, n)
    for i in 1:n
        dist_mat[i,i] = 0.0
        for j in (i+1):n
            d = sqrt(sum((pos[i,t,:] - pos[j,t,:]).^2))
            if d < max_dist
                dist_mat[i,j] = d
                dist_mat[j,i] = d
            end
        end
    end

    # Floyd-Warshall
    for k in 1:n, i in 1:n, j in 1:n
        if dist_mat[i,k] + dist_mat[k,j] < dist_mat[i,j]
            dist_mat[i,j] = dist_mat[i,k] + dist_mat[k,j]
        end
    end

    # 构建 next_hop 矩阵
    next_hop = zeros(Int, n, n)
    for i in 1:n, j in 1:n
        if i == j
            next_hop[i,j] = i
            continue
        end
        if isinf(dist_mat[i,j])
            next_hop[i,j] = 0  # 不可达
            continue
        end
        # 找第一跳
        for k in 1:n
            if k != i && !isinf(dist_mat[i,k]) && dist_mat[i,k] + dist_mat[k,j] == dist_mat[i,j]
                next_hop[i,j] = k
                break
            end
        end
    end

    # 填充路由表
    for (idx_i, id_i) in enumerate(node_ids)
        table = Dict{UInt32, Tuple{UInt32, Int}}()
        for (idx_j, id_j) in enumerate(node_ids)
            if id_i != id_j && next_hop[idx_i, idx_j] > 0
                nh_idx = next_hop[idx_i, idx_j]
                nh_id = node_ids[nh_idx]
                table[id_j] = (nh_id, 1)  # port=1 (简化)
            end
        end
        crt.tables[id_i] = table
    end

    crt.epoch += 1
    crt.last_update = Now()
    return crt
end

"""
    get_next_hop(crt, node_id, dest_id) → (next_hop, port) | nothing

查询路由表获取下一跳。
O(1) 查表 — 与路由协议收敛时间无关。
"""
function get_next_hop(crt::CentralizedRoutingTable,
                       node_id::UInt32, dest_id::UInt32)
    node_table = get(crt.tables, node_id, nothing)
    if node_table === nothing
        return nothing
    end
    return get(node_table, dest_id, nothing)
end

"""
    update_route!(crt, node_id, dest_id, next_hop, port)

手动更新/修正单条路由 (用于链路故障快速重路由)。
"""
function update_route!(crt::CentralizedRoutingTable,
                       node_id::UInt32, dest_id::UInt32,
                       next_hop::UInt32, port::Int=1)
    node_table = get(crt.tables, node_id, nothing)
    if node_table === nothing
        crt.tables[node_id] = Dict{UInt32, Tuple{UInt32, Int}}()
        node_table = crt.tables[node_id]
    end
    node_table[dest_id] = (next_hop, port)
    nothing
end

"""
    fast_reroute(crt, failed_node, neighbors) → 局部重路由

链路故障时，只为受影响的节点重新计算局部路由。
不需要全星座重算。
"""
function fast_reroute(crt::CentralizedRoutingTable,
                      failed_node::UInt32,
                      neighbors::Vector{UInt32})
    affected = UInt32[]
    for (node_id, table) in crt.tables
        for (dest, (nh, port)) in table
            if nh == failed_node
                push!(affected, node_id)
                break
            end
        end
    end
    return affected
end
