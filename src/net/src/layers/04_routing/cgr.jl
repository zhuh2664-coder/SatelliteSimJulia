#= cgr.jl — Contact Graph Routing (CGR) 迁移实现

本文件从旧版 legacy_layers/09_protocol/netsim/space/cgr.jl 与
contact_plan.jl 迁移而来，并接入 SatelliteSimNet 的多重分派路由接口。

设计原则：
- 保留原有 CGR API（cgr_route / cgr_multipath / cgr_eto / cgr_bia 等）
- 新增 CGRRouting <: AbstractRoutingAlgorithm，与 route() 接口集成
- 使用 DataStructures.MutableBinaryHeap 维持原算法复杂度
=#

using DataStructures
using Statistics

export CGRContact, CGRContactPlan, CGRRouting, CgrRouteTable, CgrContactQueue,
       TimeContact, ContactPlan,  # 兼容旧 API 的别名
       add_contact!, merge_plan!, rebuild_adjacency!,
       build_contact_plan_from_positions!, build_from_pos!,
       neighbors_at, active_contacts, contact_schedule, contact_stats,
       is_reachable_at, prune_contacts!, predict_contacts,
       cgr_route, cgr_multipath, cgr_eto, cgr_bia, cgr_shortest_path,
       cgr_lsa, partition_cgr, validate_path, route_compare,
       update_routes!, get_next_hop, fast_reroute!

const MAX_DELAY = 1e12
const DEFAULT_CGR_CAPACITY = 1e9
const LIGHT_SPEED_KM_S = 299792.458

"""
    CGRContact

单个接触（Contact）：描述从 `src` 到 `dst` 在一段时间内的可用链路。
"""
struct CGRContact
    src::UInt32
    dst::UInt32
    start_time::Float64
    end_time::Float64
    delay::Float64
    capacity::Float64
end

"旧版 `TimeContact` 别名，保持向后兼容。"
const TimeContact = CGRContact

"""
    CGRContactPlan

接触计划：一组按时间排序的 `CGRContact`，用于 CGR 路由。
"""
mutable struct CGRContactPlan
    name::String
    contacts::Vector{CGRContact}
    node_ids::Set{UInt32}
    adjacency::Dict{UInt32, Vector{UInt32}}  # node → neighbors (cached)
    last_update::Float64
end

CGRContactPlan(name::String="default") = CGRContactPlan(
    name, CGRContact[], Set{UInt32}(), Dict{UInt32,Vector{UInt32}}(), 0.0)

"旧版 `ContactPlan` 别名，保持向后兼容。"
const ContactPlan = CGRContactPlan

"""
    add_contact!(cp, src, dst, start, stop, delay, cap=1e9)

向接触计划添加一条有向接触。
"""
function add_contact!(cp::CGRContactPlan, src::UInt32, dst::UInt32,
                       start::Real, stop::Real, delay::Real,
                       cap::Real=DEFAULT_CGR_CAPACITY)
    push!(cp.contacts, CGRContact(src, dst, start, stop, delay, cap))
    push!(cp.node_ids, src, dst)
    return cp
end

"""
    merge_plan!(cp, other, t_now=time())

将另一个接触计划合并到 `cp` 中。
"""
function merge_plan!(cp::CGRContactPlan, other::CGRContactPlan, t_now::Real=time())
    for c in other.contacts
        add_contact!(cp, c.src, c.dst, c.start_time, c.end_time, c.delay, c.capacity)
    end
    cp.last_update = t_now
    return cp
end

"""
    rebuild_adjacency!(cp)

重建邻接缓存。
"""
function rebuild_adjacency!(cp::CGRContactPlan)
    empty!(cp.adjacency)
    for c in cp.contacts
        push!(get!(cp.adjacency, c.src, UInt32[]), c.dst)
    end
    for v in values(cp.adjacency)
        unique!(v)
    end
    return cp
end

"""
    build_contact_plan_from_positions!(cp, pos, node_ids; max_dist=5000.0, t_start=0.0, dt=1.0)

从 N×T×3 位置矩阵构建 ISL 接触计划。
"""
function build_contact_plan_from_positions!(cp::CGRContactPlan,
                                            pos::AbstractArray{<:Real,3},
                                            node_ids::Vector{UInt32};
                                            max_dist::Real=5000.0,
                                            t_start::Real=0.0,
                                            dt::Real=1.0)
    n, T = size(pos, 1), size(pos, 2)
    size(pos, 3) == 3 || throw(ArgumentError("pos must have xyz size 3"))
    length(node_ids) == n || throw(ArgumentError("node_ids length must match pos satellite dimension"))
    dt > 0 || throw(ArgumentError("dt must be positive"))
    max_dist >= 0 || throw(ArgumentError("max_dist must be non-negative"))
    for t_idx in 1:T
        sim_time = t_start + (t_idx - 1) * dt
        for i in 1:n, j in (i+1):n
            d = sqrt(sum((pos[i, t_idx, :] .- pos[j, t_idx, :]).^2))
            if d < max_dist
                delay = d / LIGHT_SPEED_KM_S
                add_contact!(cp, node_ids[i], node_ids[j], sim_time, sim_time + dt, delay)
                add_contact!(cp, node_ids[j], node_ids[i], sim_time, sim_time + dt, delay)
            end
        end
    end
    rebuild_adjacency!(cp)
    return cp
end

"旧版函数名别名。"
const build_from_pos! = build_contact_plan_from_positions!

# ═══════════════════════════════════════════════════════
# Contact 查询
# ═══════════════════════════════════════════════════════

"""
    neighbors_at(cp, node, t)

返回节点 `node` 在时刻 `t` 的所有邻居及其对应接触。
"""
function neighbors_at(cp::CGRContactPlan, node::UInt32, t::Real)
    result = Tuple{UInt32, CGRContact}[]
    for c in cp.contacts
        if c.src == node && t >= c.start_time && t < c.end_time
            push!(result, (c.dst, c))
        end
    end
    return result
end

"""
    active_contacts(cp, t)

返回时刻 `t` 所有活跃的接触。
"""
function active_contacts(cp::CGRContactPlan, t::Real)
    filter(c -> t >= c.start_time && t < c.end_time, cp.contacts)
end

"""
    contact_schedule(cp, node)

返回节点 `node` 的接触时间表。
"""
function contact_schedule(cp::CGRContactPlan, node::UInt32)
    sched = Tuple{Float64,Float64}[]
    for c in cp.contacts
        if c.src == node || c.dst == node
            push!(sched, (c.start_time, c.end_time))
        end
    end
    unique!(sched)
    sort!(sched, by=x->x[1])
    return sched
end

"""
    contact_stats(cp)

返回接触计划统计信息：
(contact 数量, 平均延迟, 平均持续时间, 节点数, 唯一链路数, 平均容量)
"""
function contact_stats(cp::CGRContactPlan)
    n = length(cp.contacts)
    n == 0 && return (0, 0.0, 0.0, 0, 0, 0.0)
    delays = [c.delay for c in cp.contacts]
    caps = [c.capacity for c in cp.contacts]
    durations = [c.end_time - c.start_time for c in cp.contacts]
    unique_links = length(unique([(c.src, c.dst) for c in cp.contacts]))
    return (
        n, mean(delays), mean(durations),
        length(cp.node_ids), unique_links, mean(caps)
    )
end

"""
    is_reachable_at(cp, src, dst, t)

判断在时刻 `t` 是否存在从 `src` 到 `dst` 的直接接触。
"""
function is_reachable_at(cp::CGRContactPlan, src::UInt32, dst::UInt32, t::Real)::Bool
    for c in cp.contacts
        if c.src == src && c.dst == dst && t >= c.start_time && t < c.end_time
            return true
        end
    end
    return false
end

"""
    prune_contacts!(cp, dst)

剪枝：移除无法到达目标 `dst` 的接触。
"""
function prune_contacts!(cp::CGRContactPlan, dst::UInt32)
    reachable = Set{UInt32}([dst])
    changed = true
    while changed
        changed = false
        for c in cp.contacts
            if c.dst in reachable && !(c.src in reachable)
                push!(reachable, c.src)
                changed = true
            end
        end
    end
    filter!(c -> c.src in reachable, cp.contacts)
    rebuild_adjacency!(cp)
    return length(cp.contacts)
end

"""
    predict_contacts(cp, t_future; window=10.0, t_now=time(), period=5400.0)

基于当前活跃接触和轨道周期预测未来接触。
"""
function predict_contacts(cp::CGRContactPlan, t_future::Real;
                           window::Real=10.0, t_now::Real=time(),
                           period::Real=5400.0)
    predicted = CGRContact[]
    for c in cp.contacts
        if c.start_time <= t_now && c.end_time > t_now
            offset = mod(t_future - c.start_time, period)
            if offset < (c.end_time - c.start_time)
                push!(predicted, CGRContact(
                    c.src, c.dst, t_future, t_future + window,
                    c.delay, c.capacity))
            end
        end
    end
    return predicted
end

# ═══════════════════════════════════════════════════════
# CGR 路由核心
# ═══════════════════════════════════════════════════════

"""
    CgrContactQueue

按开始时间排序的 contact 队列，支持 cursor 跳过已过期接触。
"""
mutable struct CgrContactQueue
    node::UInt32
    contacts::Vector{CGRContact}
    cursor::Int
end

function CgrContactQueue(node::UInt32, contacts::Vector{CGRContact})
    sorted = sort(filter(c -> c.src == node, contacts), by=c -> c.start_time)
    return CgrContactQueue(node, sorted, 1)
end

function current(cq::CgrContactQueue, t::Real)::Union{CGRContact,Nothing}
    while cq.cursor <= length(cq.contacts)
        c = cq.contacts[cq.cursor]
        if c.end_time <= t
            cq.cursor += 1
            continue
        end
        if c.start_time <= t && t < c.end_time
            return c
        end
        return nothing
    end
    return nothing
end

function next_start(cq::CgrContactQueue, t::Real)::Float64
    for i in cq.cursor:length(cq.contacts)
        c = cq.contacts[i]
        if c.start_time >= t
            return c.start_time
        end
    end
    return Inf
end

function active(cq::CgrContactQueue, t::Real)::Vector{CGRContact}
    result = CGRContact[]
    for i in cq.cursor:length(cq.contacts)
        c = cq.contacts[i]
        if t >= c.start_time && t < c.end_time
            push!(result, c)
        elseif c.start_time > t
            break
        end
    end
    return result
end

"""
    cgr_route(cp, src, dst, t_start; bundle_size=0.0)

CGR 单路径路由：在接触计划 `cp` 上，从 `src` 到 `dst`、起始时刻 `t_start`
计算一条延迟最小的路径。

返回：`(path::Vector{UInt32}, delay::Float64, arrival::Float64)`
"""
function cgr_route(cp::CGRContactPlan, src::UInt32, dst::UInt32, t_start::Real;
                    bundle_size::Real=0.0)
    isempty(cp.contacts) && return (UInt32[], Inf, Inf)

    INF = MAX_DELAY
    si, di = Int(src), Int(dst)
    n = max(maximum(Int.(cp.node_ids)), max(si, di))

    # dist[u] = earliest known arrival offset at node u relative to t_start
    dist = fill(INF, n)
    prev = zeros(Int, n)
    dist[si] = 0.0

    # priority queue ordered by arrival offset
    pq = DataStructures.MutableBinaryHeap{Tuple{Float64,Int}}(
        Base.Order.ForwardOrdering(), [(0.0, si)])
    finalized = falses(n)

    cap_log = Dict{Tuple{UInt32,UInt32,Float64,Float64}, Float64}()

    while !DataStructures.isempty(pq)
        prio, u = DataStructures.pop!(pq)
        # skip stale entries
        prio > dist[u] + 1e-9 && continue
        finalized[u] && continue
        finalized[u] = true

        arrival_at_u = t_start + dist[u]
        u == di && break

        for c in cp.contacts
            c.src != UInt32(u) && continue
            c.end_time <= arrival_at_u && continue  # contact already over

            departure = max(arrival_at_u, c.start_time)
            departure >= c.end_time && continue

            # capacity check
            cap_key = (c.src, c.dst, c.start_time, c.end_time)
            used_bits = get(cap_log, cap_key, 0.0)
            total_bits_available = c.capacity * (c.end_time - c.start_time)
            if bundle_size > 0 && used_bits + bundle_size * 8.0 > total_bits_available
                continue
            end

            tx_time = bundle_size > 0 ? bundle_size * 8.0 / max(c.capacity, 1.0) : 0.0
            arrival_at_v = departure + c.delay + tx_time
            nd = arrival_at_v - t_start
            vi = Int(c.dst)
            if nd < dist[vi] - 1e-9
                dist[vi] = nd
                prev[vi] = u
                DataStructures.push!(pq, (nd, vi))
                cap_log[cap_key] = used_bits + bundle_size * 8.0
            end
        end
    end

    best_delay = dist[di]
    best_delay >= INF && return (UInt32[], Inf, Inf)

    path = UInt32[UInt32(dst)]
    cur = di
    while cur != si
        nxt = prev[cur]
        (nxt == 0 || nxt == cur) && break
        pushfirst!(path, UInt32(nxt))
        cur = nxt
    end
    return (path, best_delay, t_start + best_delay)
end

"""
    cgr_multipath(cp, src, dst, t_start; n_paths=3, bundle_size=0.0)

预计算 N 条 CGR 备用路径。
"""
function cgr_multipath(cp::CGRContactPlan, src::UInt32, dst::UInt32,
                        t_start::Real; n_paths::Int=3, bundle_size::Real=0.0)
    paths = Tuple{Vector{UInt32}, Float64, Float64}[]
    excluded = Set{Tuple{UInt32,UInt32}}()

    for _ in 1:n_paths
        saved = deepcopy(cp.contacts)
        for (u, v) in excluded
            filter!(c -> !(c.src == u && c.dst == v), cp.contacts)
        end
        path, delay, arrival = cgr_route(cp, src, dst, t_start; bundle_size=bundle_size)
        if isempty(path)
            cp.contacts = saved
            break
        end
        push!(paths, (path, delay, arrival))
        if length(path) >= 2
            push!(excluded, (path[1], path[2]))
        end
        cp.contacts = saved
    end
    return paths
end

"""
    cgr_eto(cp, src, dst, t_start, deadline; bundle_size=0.0)

CGR with Early Termination Optimization：仅返回满足 deadline 的路径。
"""
function cgr_eto(cp::CGRContactPlan, src::UInt32, dst::UInt32, t_start::Real,
                  deadline::Real; bundle_size::Real=0.0)
    path, delay, arrival = cgr_route(cp, src, dst, t_start; bundle_size=bundle_size)
    if isempty(path) || delay > deadline
        return (UInt32[], Inf, Inf)
    end
    return (path, delay, arrival)
end

"""
    cgr_bia(cp, src, dst, t_start; lookahead=3600.0, bundle_size=0.0)

CGR-BIA (Best In Advance)：预计算未来一段时间内的最优路径序列。
"""
function cgr_bia(cp::CGRContactPlan, src::UInt32, dst::UInt32, t_start::Real;
                  lookahead::Real=3600.0, bundle_size::Real=0.0)
    results = Tuple{Vector{UInt32}, Float64, Float64, Float64}[]
    t = t_start
    max_paths = 100
    for _ in 1:max_paths
        t > t_start + lookahead && break
        path, delay, arrival = cgr_route(cp, src, dst, t; bundle_size=bundle_size)
        isempty(path) && break
        valid_until = t + 10.0
        if length(path) >= 2
            first_link = (path[1], path[2])
            for c in cp.contacts
                if c.src == first_link[1] && c.dst == first_link[2] && c.start_time <= t
                    valid_until = min(valid_until, c.end_time)
                end
            end
        end
        valid_until = max(valid_until, t + 1.0)
        push!(results, (path, t, valid_until, delay))
        t = valid_until
    end
    return results
end

"""
    cgr_shortest_path(plan, src, dst, t)

简化版 CGR：仅在时刻 `t` 的瞬时图上做 Dijkstra，返回路径或 `nothing`。
"""
function cgr_shortest_path(plan::CGRContactPlan, src::UInt32, dst::UInt32, t::Real)
    n_nodes = maximum(Int(c.src) for c in plan.contacts; init=0)
    n_nodes = max(n_nodes, maximum(Int(c.dst) for c in plan.contacts; init=0))
    n_nodes = max(n_nodes, Int(src), Int(dst))
    n_nodes == 0 && return nothing

    dist = fill(Inf, n_nodes)
    prev = fill(UInt32(0), n_nodes)
    visited = falses(n_nodes)
    dist[src] = 0.0

    for _ in 1:n_nodes
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

        for c in active_contacts(plan, t)
            Int(c.src) != u && continue
            v = Int(c.dst)
            if !visited[v] && dist[u] + c.delay < dist[v]
                dist[v] = dist[u] + c.delay
                prev[v] = UInt32(u)
            end
        end
    end

    prev[dst] == 0 && return nothing

    path = UInt32[]
    cur = dst
    while cur != 0
        pushfirst!(path, UInt32(cur))
        cur = prev[cur]
    end
    return path
end

# ═══════════════════════════════════════════════════════
# 路由表维护
# ═══════════════════════════════════════════════════════

"""
    CgrRouteTable

运行时 CGR 路由表，定期为每个目标计算主/备下一跳。
"""
mutable struct CgrRouteTable
    node_id::UInt32
    entries::Dict{UInt32, Vector{Tuple{UInt32, Float64}}}
    backup_entries::Dict{UInt32, Vector{Tuple{UInt32, Float64}}}
    last_update::Float64
    update_interval::Float64
    cp::CGRContactPlan
end

function CgrRouteTable(node_id::UInt32, cp::CGRContactPlan; interval::Real=10.0)
    return CgrRouteTable(
        node_id,
        Dict{UInt32,Vector{Tuple{UInt32,Float64}}}(),
        Dict{UInt32,Vector{Tuple{UInt32,Float64}}}(),
        0.0, interval, cp)
end

"""
    update_routes!(rt, t_now)

周期性更新路由表。
"""
function update_routes!(rt::CgrRouteTable, t_now::Real)
    if rt.last_update > 0.0 && t_now - rt.last_update < rt.update_interval
        return rt
    end
    rt.last_update = t_now
    empty!(rt.entries)
    empty!(rt.backup_entries)

    for dst in rt.cp.node_ids
        dst == rt.node_id && continue
        path, delay, _ = cgr_route(rt.cp, rt.node_id, dst, t_now)
        if length(path) >= 2
            rt.entries[dst] = [(path[2], delay)]
            paths = cgr_multipath(rt.cp, rt.node_id, dst, t_now; n_paths=2)
            if length(paths) >= 2
                bp, bd, _ = paths[2]
                if length(bp) >= 2
                    rt.backup_entries[dst] = [(bp[2], bd)]
                end
            end
        end
    end
    return rt
end

"""
    get_next_hop(rt, dst; use_backup=false)

查询到目标 `dst` 的下一跳。
"""
function get_next_hop(rt::CgrRouteTable, dst::UInt32; use_backup::Bool=false)
    table = use_backup ? rt.backup_entries : rt.entries
    entry = get(table, dst, nothing)
    entry === nothing && return nothing
    isempty(entry) && return nothing
    return entry[1]
end

"""
    fast_reroute!(rt, dst)

切换到备份路径。
"""
function fast_reroute!(rt::CgrRouteTable, dst::UInt32)
    if haskey(rt.backup_entries, dst)
        rt.entries[dst] = rt.backup_entries[dst]
    end
    return rt
end

# ═══════════════════════════════════════════════════════
# 辅助功能
# ═══════════════════════════════════════════════════════

"""
    partition_cgr(cp, n_partitions)

大规模星座分区 CGR。
"""
function partition_cgr(cp::CGRContactPlan, n_partitions::Int)
    nodes = sort!(collect(cp.node_ids))
    n = length(nodes)
    if n < n_partitions * 2
        return [cp]
    end
    partitions = Vector{CGRContactPlan}()
    sats_per_part = n ÷ n_partitions
    for p in 1:n_partitions
        start_idx = (p - 1) * sats_per_part + 1
        stop_idx = min(p * sats_per_part, n)
        p_nodes = Set(nodes[start_idx:stop_idx])
        p_cp = CGRContactPlan("partition_$p")
        for c in cp.contacts
            if c.src in p_nodes && c.dst in p_nodes
                add_contact!(p_cp, c.src, c.dst, c.start_time, c.end_time, c.delay, c.capacity)
            end
        end
        push!(partitions, p_cp)
    end
    return partitions
end

"""
    cgr_lsa(cp, node, t)

CGR 链路状态通告：返回节点 `node` 在时刻 `t` 的活跃接触广告。
"""
function cgr_lsa(cp::CGRContactPlan, node::UInt32, t::Real)
    ads = Tuple{UInt32, UInt32, Float64, Float64}[]
    for c in active_contacts(cp, t)
        if c.src == node
            push!(ads, (c.src, c.dst, c.delay, c.capacity))
        end
    end
    return ads
end

"""
    validate_path(cp, path, t)

验证路径在时刻 `t` 是否有效。
"""
function validate_path(cp::CGRContactPlan, path::Vector{UInt32}, t::Real)::Bool
    length(path) < 2 && return false
    for i in 1:length(path)-1
        found = false
        for c in cp.contacts
            if c.src == path[i] && c.dst == path[i+1] &&
               t >= c.start_time && t < c.end_time
                found = true
                break
            end
        end
        found || return false
    end
    return true
end

"""
    route_compare(a, b)

比较两条路径的优劣。
"""
function route_compare(a::Vector{UInt32}, b::Vector{UInt32})::Symbol
    isempty(a) && isempty(b) && return :equal
    isempty(a) && return :b_better
    isempty(b) && return :a_better
    length(a) < length(b) && return :a_better
    length(b) < length(a) && return :b_better
    return :equal
end

# ═══════════════════════════════════════════════════════
# 与 AbstractRoutingAlgorithm 集成
# ═══════════════════════════════════════════════════════

"""
    CGRRouting <: AbstractRoutingAlgorithm

CGR 路由算法类型，用于 SatelliteSimNet 的多重分派接口。

由于 CGR 需要时间扩展的接触计划，无法直接复用静态 `RoutingGraph`，
因此提供专用的 `route` 方法：

    route(::CGRRouting, cp::CGRContactPlan, src, dst, t_start; bundle_size=0.0)
"""
struct CGRRouting <: AbstractRoutingAlgorithm end

"""
    route(::CGRRouting, cp, src, dst, t_start; bundle_size=0.0)

通过 CGR 在接触计划 `cp` 上计算路径，返回标准 `RoutingOutput`。
"""
function route(::CGRRouting, cp::CGRContactPlan, src::Int, dst::Int,
                t_start::Real; bundle_size::Real=0.0)::RoutingOutput
    path, delay, _ = cgr_route(cp, UInt32(src), UInt32(dst), t_start;
                                bundle_size=bundle_size)
    if isempty(path)
        return RoutingOutput(Int[], Inf, "CGR-unreachable")
    end
    return RoutingOutput(Int.(path), delay, "CGR")
end

function route(::CGRRouting, cp::CGRContactPlan, src::UInt32, dst::UInt32,
                t_start::Real; bundle_size::Real=0.0)::RoutingOutput
    path, delay, _ = cgr_route(cp, src, dst, t_start; bundle_size=bundle_size)
    if isempty(path)
        return RoutingOutput(Int[], Inf, "CGR-unreachable")
    end
    return RoutingOutput(Int.(path), delay, "CGR")
end
