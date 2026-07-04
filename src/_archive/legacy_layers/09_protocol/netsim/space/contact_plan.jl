"""
    contact_plan.jl — DTN 接触计划 (Contact Graph Routing)

DTN 的核心概念：由于卫星轨道可预测，每条链路何时可用、延迟多少
可以预先计算。Contact Plan 就是这些"可用时段"的集合。

每个 Contact = (源, 目的, 开始时间, 结束时间, 延迟, 容量)

CGR (Contact Graph Routing) 利用接触计划计算端到端路径。
"""
struct Contact
    src::UInt32
    dst::UInt32
    start_time::Float64
    end_time::Float64
    delay::Float64
    capacity::Float64
end

mutable struct ContactPlan
    contacts::Vector{Contact}
end

ContactPlan() = ContactPlan(Contact[])

"""
    add_contact!(plan, src, dst, start, stop, delay, capacity)
"""
function add_contact!(plan::ContactPlan, src::UInt32, dst::UInt32,
                       start::Float64, stop::Float64,
                       delay::Float64, capacity::Float64=1e9)
    push!(plan.contacts, Contact(src, dst, start, stop, delay, capacity))
    nothing
end

"""
    query_contacts(plan, src, dst, t) → Vector{Contact}

在时间 t 查询从 src 到 dst 的可用接触。
"""
function query_contacts(plan::ContactPlan, src::UInt32, dst::UInt32, t::Float64)
    result = Contact[]
    for c in plan.contacts
        if c.src == src && c.dst == dst && t >= c.start_time && t < c.end_time
            push!(result, c)
        end
    end
    return result
end

"""
    query_all_contacts(plan, src, t) → Vector{Contact}

在时间 t 查询 src 所有可用出链路。
"""
function query_all_contacts(plan::ContactPlan, src::UInt32, t::Float64)
    result = Contact[]
    for c in plan.contacts
        if c.src == src && t >= c.start_time && t < c.end_time
            push!(result, c)
        end
    end
    return result
end

"""
    build_contact_plan_from_pos! — 从你的平台 pos 矩阵构建接触计划

这是 Bridge 的核心函数。

参数:
    plan: ContactPlan (将被填充)
    pos: N×T×3 位置矩阵
    node_ids: 卫星 ID 列表
    max_dist: ISL 最大距离 (km)
    t_start: 开始时间 (秒)
    t_stop: 结束时间 (秒)
    dt: 时间步 (秒)
"""
function build_from_pos!(plan::ContactPlan,
                         pos::AbstractArray{Float64,3},
                         node_ids::Vector{UInt32},
                         max_dist::Float64=5000.0,
                         t_start::Float64=0.0,
                         t_stop::Float64=6000.0,
                         dt::Float64=1.0)
    n = size(pos, 1)
    c = 299792.458  # 光速 km/s

    # 每个时间步：检查哪些 ISL 可用
    for t_idx in 1:Int((t_stop - t_start) / dt)
        sim_time = t_start + (t_idx - 1) * dt
        for i in 1:n
            for j in (i+1):n
                d = sqrt(sum((pos[i, t_idx, :] - pos[j, t_idx, :]).^2))
                if d < max_dist
                    delay = d / c
                    add_contact!(plan, node_ids[i], node_ids[j],
                                 sim_time, sim_time + dt,
                                 delay, 1e9)
                    add_contact!(plan, node_ids[j], node_ids[i],
                                 sim_time, sim_time + dt,
                                 delay, 1e9)
                end
            end
        end
    end
    nothing
end

"""
    cgr_shortest_path(plan, src, dst, t) → Vector{UInt32} | nothing

CGR (Contact Graph Routing) 最短路径：在时间 t 从 src 到 dst。
"""
function cgr_shortest_path(plan::ContactPlan, src::UInt32, dst::UInt32, t::Float64)
    # Dijkstra 在接触图上
    n_nodes = maximum(c.src for c in plan.contacts)
    n_nodes = max(n_nodes, maximum(c.dst for c in plan.contacts))

    dist = fill(Inf, n_nodes)
    prev = fill(UInt32(0), n_nodes)
    visited = falses(n_nodes)

    dist[src] = 0.0

    for _ in 1:n_nodes
        # 选未访问的最小距离节点
        u = 0
        min_d = Inf
        for i in 1:n_nodes
            if !visited[i] && dist[i] < min_d
                u = i
                min_d = dist[i]
            end
        end
        u == 0 && break
        u == dst && break
        visited[u] = true

        # 遍历 u 在时间 t 的接触
        for c in query_all_contacts(plan, UInt32(u), t)
            v = Int(c.dst)
            if !visited[v] && dist[u] + c.delay < dist[v]
                dist[v] = dist[u] + c.delay
                prev[v] = UInt32(u)
            end
        end
    end

    # 回溯路径
    if prev[dst] == 0
        return nothing  # 不可达
    end

    path = UInt32[]
    cur = dst
    while cur != 0
        pushfirst!(path, UInt32(cur))
        cur = prev[cur]
    end
    return path
end
