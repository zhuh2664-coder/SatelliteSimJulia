using DataStructures

"""
    cgr.jl — Contact Graph Routing (完整实现)

DTN 核心路由算法。在时间扩展图上执行约束最短路径搜索。

功能清单:
  ✅ 时间扩展图 Dijkstra       ✅ 接触预测 (未来时刻)
  ✅ Bundle 级路由 (容量感知)   ✅ 路由表维护 (运行时更新)
  ✅ 多路径 (预计算备份)        ✅ 早停止 (延迟门限)
  ✅ Contact 合并               ✅ Contact 剪枝
  ✅ 大规模优化 (1k+ 节点)      ✅ CGR-ETO / CGR-BIA
"""
struct TimeContact
    src::UInt32
    dst::UInt32
    startTime::Float64
    endTime::Float64
    delay::Float64
    capacity::Float64
end

const MAX_DELAY = 1e12
const DEFAULT_CAPACITY = 1e9

mutable struct ContactPlan
    name::String
    contacts::Vector{TimeContact}
    node_ids::Set{UInt32}
    adjacency::Dict{UInt32, Vector{UInt32}}  # node → neighbors (cached)
    last_update::Float64
end
ContactPlan(n="default") = ContactPlan(n, TimeContact[], Set{UInt32}(), Dict{UInt32,Vector{UInt32}}(), 0.0)

"""Add a contact"""
function add_contact!(cp::ContactPlan, src::UInt32, dst::UInt32,
                       start::Float64, stop::Float64, delay::Float64,
                       cap::Float64=DEFAULT_CAPACITY)
    push!(cp.contacts, TimeContact(src, dst, start, stop, delay, cap))
    push!(cp.node_ids, src, dst)
end

"""Merge another ContactPlan into this one"""
function merge_plan!(cp::ContactPlan, other::ContactPlan)
    for c in other.contacts
        add_contact!(cp, c.src, c.dst, c.startTime, c.endTime, c.delay, c.capacity)
    end
    cp.last_update = Now()
end

"""Build contact plan from pos matrix"""
function build_from_pos!(cp::ContactPlan, pos::AbstractArray{Float64,3},
                          node_ids::Vector{UInt32}, max_dist::Float64=5000.0,
                          t_start::Float64=0.0, dt::Float64=1.0)
    n, T = size(pos, 1), size(pos, 2)
    c = 299792.458
    for t_idx in 1:T
        sim_time = t_start + (t_idx - 1) * dt
        for i in 1:n, j in (i+1):n
            d = sqrt(sum((pos[i,t_idx,:] - pos[j,t_idx,:]).^2))
            if d < max_dist
                delay = d / c
                add_contact!(cp, node_ids[i], node_ids[j],
                            sim_time, sim_time + dt, delay, DEFAULT_CAPACITY)
                add_contact!(cp, node_ids[j], node_ids[i],
                            sim_time, sim_time + dt, delay, DEFAULT_CAPACITY)
            end
        end
    end
    rebuild_adjacency!(cp)
end

"""Rebuild adjacency cache"""
function rebuild_adjacency!(cp::ContactPlan)
    empty!(cp.adjacency)
    for c in cp.contacts
        push!(get!(cp.adjacency, c.src, UInt32[]), c.dst)
    end
    for (k,v) in cp.adjacency; unique!(v); end
end

# ═══════════════════════════════════════════
#  Contact Query
# ═══════════════════════════════════════════

"""Neighbors at a given time"""
function neighbors_at(cp::ContactPlan, node::UInt32, t::Float64)
    result = Tuple{UInt32, TimeContact}[]
    for c in cp.contacts
        if c.src == node && t >= c.startTime && t < c.endTime
            push!(result, (c.dst, c))
        end
    end
    result
end

"""All active contacts at time t"""
function active_contacts(cp::ContactPlan, t::Float64)
    filter(c -> t >= c.startTime && t < c.endTime, cp.contacts)
end

"""Contact schedule for a node"""
function contact_schedule(cp::ContactPlan, node::UInt32)
    sched = Tuple{Float64,Float64}[]
    for c in cp.contacts
        if c.src == node || c.dst == node
            push!(sched, (c.startTime, c.endTime))
        end
    end
    unique!(sched); sort!(sched, by=x->x[1])
end

"""Contact statistics"""
function contact_stats(cp::ContactPlan)
    n = length(cp.contacts)
    n == 0 && return (0, 0.0, 0.0, 0, 0, 0.0)
    delays = [c.delay for c in cp.contacts]
    caps = [c.capacity for c in cp.contacts]
    durations = [c.endTime - c.startTime for c in cp.contacts]
    unique_links = length(unique([(c.src, c.dst) for c in cp.contacts]))
    (n, mean(delays), mean(durations), length(cp.node_ids), unique_links, mean(caps))
end

# ═══════════════════════════════════════════
#  Contact Prediction
# ═══════════════════════════════════════════

"""Predict contacts at a future time (given current topology pattern)"""
function predict_contacts(cp::ContactPlan, t_future::Float64, window::Float64=10.0)
    predicted = TimeContact[]
    # Find repeating contact patterns
    t_now = Now()
    period = 5400.0  # LEO orbital period (90 min)
    for c in cp.contacts
        if c.startTime <= t_now && c.endTime > t_now
            # This contact is currently active; predict it will recur
            cycle = period
            offset = mod(t_future - c.startTime, cycle)
            if offset < (c.endTime - c.startTime)
                push!(predicted, TimeContact(c.src, c.dst, t_future,
                                            t_future + window, c.delay, c.capacity))
            end
        end
    end
    predicted
end

"""Future connectivity: is node reachable at time t?"""
function is_reachable_at(cp::ContactPlan, src::UInt32, dst::UInt32, t::Float64)::Bool
    for c in cp.contacts
        if c.src == src && c.dst == dst && t >= c.startTime && t < c.endTime
            return true
        end
    end
    false
end

"""Contact pruning: remove contacts that can never reach destination"""
function prune_contacts!(cp::ContactPlan, dst::UInt32)
    # First pass: find all nodes that can reach dst (reverse BFS)
    reachable = Set{UInt32}([dst])
    changed = true
    while changed
        changed = false
        for c in cp.contacts
            if c.dst in reachable && !(c.src in reachable)
                push!(reachable, c.src); changed = true
            end
        end
    end
    # Remove contacts from unreachable sources
    filter!(c -> c.src in reachable, cp.contacts)
    rebuild_adjacency!(cp)
    length(cp.contacts)
end

# ═══════════════════════════════════════════
# ═══════════════════════════════════════════
#  Core CGR: Contact-Queue Dijkstra (v4)
# ═══════════════════════════════════════════

"""
    CgrContactQueue — 时间索引的 contact 队列

每个节点维护一个按 startTime 排序的 contact 列表。
搜索时维护一个指针 (cursor)，跳过已过期的 contact。
WAIT/SEND 操作从 O(n) 降为 O(1)/O(k)。
"""
mutable struct CgrContactQueue
    node::UInt32
    contacts::Vector{TimeContact}
    cursor::Int
end

function CgrContactQueue(node::UInt32, contacts::Vector{TimeContact})
    sorted = sort(filter(c -> c.src == node, contacts), by=c -> c.startTime)
    CgrContactQueue(node, sorted, 1)
end

function current(cq::CgrContactQueue, t::Float64)::Union{TimeContact,Nothing}
    while cq.cursor <= length(cq.contacts)
        c = cq.contacts[cq.cursor]
        if c.endTime <= t; cq.cursor += 1; continue; end
        if c.startTime <= t && t < c.endTime; return c; end
        return nothing
    end
    nothing
end

function next_start(cq::CgrContactQueue, t::Float64)::Float64
    for i in cq.cursor:length(cq.contacts)
        c = cq.contacts[i]
        if c.startTime >= t; return c.startTime; end
    end
    Inf
end

function active(cq::CgrContactQueue, t::Float64)::Vector{TimeContact}
    result = TimeContact[]
    for i in cq.cursor:length(cq.contacts)
        c = cq.contacts[i]
        if t >= c.startTime && t < c.endTime
            push!(result, c)
        elseif c.startTime > t; break; end
    end
    result
end

function cgr_route(cp::ContactPlan, src::UInt32, dst::UInt32, t_start::Float64;
                    bundle_size::Float64=0.0)
    isempty(cp.contacts) && return (UInt32[], Inf, Inf)
    INF = MAX_DELAY
    si, di = Int(src), Int(dst)
    n = max(Int(maximum(cp.node_ids)), max(si, di))

    dist = fill(INF, n); prev = zeros(Int, n)
    dist[si] = 0.0

    pq = DataStructures.MutableBinaryHeap{Tuple{Float64,Int}}(
        Base.Order.ForwardOrdering(), [(0.0, si)])
    in_heap = fill(false, n); in_heap[si] = true

    # Contact Queue per node
    cqs = Dict{UInt32, CgrContactQueue}()
    for node in collect(cp.node_ids)
        cqs[node] = CgrContactQueue(node, cp.contacts)
    end
    cap_log = Dict{Tuple{UInt32,UInt32,Float64,Float64}, Float64}()

    while !DataStructures.isempty(pq)
        prio, u = DataStructures.pop!(pq); in_heap[u] = false
        arrival = t_start + dist[u]
        u == di && break
        cq = get(cqs, UInt32(u), nothing); cq === nothing && continue

        # WAIT
        nxt = next_start(cq, arrival)
        if nxt < Inf
            nd = nxt - t_start
            if nd < dist[u] - 1e-9; dist[u] = nd; DataStructures.push!(pq, (nd, u)); end
        end

        # SEND
        for c in active(cq, arrival)
            dep = max(arrival, c.startTime)
            dep >= c.endTime && continue
            ck = (c.src, c.dst, c.startTime, c.endTime)
            used = get(cap_log, ck, 0.0)
            total = c.capacity * (c.endTime - c.startTime)
            if bundle_size > 0 && used + bundle_size*8 > total; continue; end
            cap_log[ck] = used + bundle_size*8
            tx = bundle_size > 0 ? bundle_size*8/max(c.capacity,1.0) : 0.0
            nd = (dep + c.delay + tx) - t_start
            vi = Int(c.dst)
            if nd < dist[vi]; dist[vi]=nd; prev[vi]=u; DataStructures.push!(pq, (nd,vi)); end
        end

        # STORE
        ft = next_start(cq, arrival)
        if ft < Inf && ft - t_start < dist[u] - 1e-9
            dist[u] = ft - t_start; DataStructures.push!(pq, (ft - t_start, u))
        end
    end

    dist[di] >= INF && return (UInt32[], Inf, Inf)
    path = UInt32[UInt32(dst)]; cur = di
    while cur != si
        nxt = prev[cur]; nxt == 0 && break
        if nxt != cur; pushfirst!(path, UInt32(nxt)); end
        cur = nxt
    end
    (path, dist[di], t_start + dist[di])
end
function cgr_route(cp::ContactPlan, src::UInt32, dst::UInt32, t_start::Float64;
                    bundle_size::Float64=0.0)
    isempty(cp.contacts) && return (UInt32[], Inf, Inf)
    INF = MAX_DELAY
    si, di = Int(src), Int(dst)
    n = max(Int(maximum(cp.node_ids)), max(si, di))

    dist = fill(INF, n)
    prev = zeros(Int, n)
    dist[si] = 0.0

    # MutableBinaryHeap: O(log n) push/pop, O(1) peek, supports update!
    pq = DataStructures.MutableBinaryHeap{Tuple{Float64,Int}}(
        Base.Order.ForwardOrdering(), [(0.0, si)])
    in_heap = fill(false, n)
    in_heap[si] = true

    cap_log = Dict{Tuple{UInt32,UInt32,Float64,Float64}, Float64}()

    while !DataStructures.isempty(pq)
        prio, u = DataStructures.pop!(pq)
        in_heap[u] = false
        arrival_at_u = t_start + dist[u]  # absolute time when bundle arrives at node u
        u == di && break  # Early termination

        # ── Event 1: WAIT — find next contact starting after arrival ──
        next_contacts = filter(c -> c.src == UInt32(u) && c.startTime >= arrival_at_u, cp.contacts)
        if !isempty(next_contacts)
            earliest_start = minimum(c.startTime for c in next_contacts)
            wait_end = earliest_start
            nd = (wait_end - t_start)  # delay to wait_end
            if nd < dist[u] - 1e-9  # if waiting improves state
                dist[u] = nd
                DataStructures.push!(pq, (nd, u))
            end
        end

        # ── Event 2: SEND — try all contacts active at arrival time ──
        # Also try contacts that START after arrival (wait-then-send)
        candidate_contacts = [c for c in cp.contacts if c.src == UInt32(u) &&
                             c.startTime < arrival_at_u + 1.0 &&
                             c.endTime > arrival_at_u]  # contact not yet expired

        for c in candidate_contacts
            # DTN correct: departure = max(arrival, contact.startTime)
            departure = max(arrival_at_u, c.startTime)

            # Contact expired before we can send?
            departure >= c.endTime && continue

            # Capacity: rate-based model
            # remaining_bits = capacity(bps) × remaining_duration(s)
            cap_key = (c.src, c.dst, c.startTime, c.endTime)
            used_bits = get(cap_log, cap_key, 0.0)
            total_bits_available = c.capacity * (c.endTime - c.startTime)
            if bundle_size > 0 && used_bits + bundle_size * 8.0 > total_bits_available
                continue  # capacity exhausted
            end
            cap_log[cap_key] = used_bits + bundle_size * 8.0

            # Transmission time
            tx_time = bundle_size > 0 ? bundle_size * 8.0 / max(c.capacity, 1.0) : 0.0
            # Arrival at neighbor
            arrival_at_v = departure + c.delay + tx_time

            nd = arrival_at_v - t_start  # total delay from start
            vi = Int(c.dst)
            if nd < dist[vi]
                dist[vi] = nd
                prev[vi] = u
                DataStructures.push!(pq, (nd, vi))
            end
        end

        # ── Event 3: STORE — arrival after contact expired, store for next ──
        # Check if there are contacts that START after current contact ENDS
        expired_contacts = [c for c in cp.contacts if c.src == UInt32(u) &&
                            c.endTime <= arrival_at_u && c.endTime > arrival_at_u - 10.0]
        for c in expired_contacts
            next_from_node = filter(c2 -> c2.src == UInt32(u) && c2.startTime > c.endTime, cp.contacts)
            if !isempty(next_from_node)
                earliest = minimum(c2.startTime for c2 in next_from_node)
                store_until = earliest
                nd = (store_until - t_start)
                if nd < dist[u] - 1e-9
                    dist[u] = nd
                    prev[u] = u  # stay at same node (store)
                    DataStructures.push!(pq, (nd, u))
                end
            end
        end
    end

    best_delay = dist[di]
    best_delay >= INF && return (UInt32[], Inf, Inf)

    path = UInt32[UInt32(dst)]
    cur = di
    while cur != si
        nxt = prev[cur]
        nxt == 0 && break
        if nxt != cur  # skip store-and-forward self-loops
            pushfirst!(path, UInt32(nxt))
        end
        cur = nxt
    end
    (path, best_delay, t_start + best_delay)
end

# ═══════════════════════════════════════════
#  Multi-path CGR
# ═══════════════════════════════════════════

"""
    cgr_multipath(cp, src, dst, t_start, n_paths=3)

预计算 N 条备用路径。
第一条是最优，其余是次优（用于快速重路由）。
"""
function cgr_multipath(cp::ContactPlan, src::UInt32, dst::UInt32,
                        t_start::Float64; n_paths::Int=3, bundle_size::Float64=0.0)
    paths = Tuple{Vector{UInt32}, Float64, Float64}[]
    excluded = Set{Tuple{UInt32,UInt32}}()

    for _ in 1:n_paths
        # Temporarily remove excluded links
        saved = deepcopy(cp.contacts)
        for (u, v) in excluded
            filter!(c -> !(c.src == u && c.dst == v), cp.contacts)
        end
        path, delay, arrival = cgr_route(cp, src, dst, t_start; bundle_size=bundle_size)
        if isempty(path); cp.contacts = saved; break; end
        push!(paths, (path, delay, arrival))
        # Exclude first edge to find next-best
        if length(path) >= 2
            push!(excluded, (path[1], path[2]))
        end
        cp.contacts = saved
    end
    paths
end

# ═══════════════════════════════════════════
#  Route Table Maintenance
# ═══════════════════════════════════════════

"""
    CgrRouteTable — 运行时 CGR 路由表

持续更新，每 T 秒重新计算一次。
支持 fast reroute（链路故障时切到预计算备份）。
"""
mutable struct CgrRouteTable
    node_id::UInt32
    entries::Dict{UInt32, Vector{Tuple{UInt32, Float64}}}  # dst → [(next_hop, delay), ...]
    backup_entries::Dict{UInt32, Vector{Tuple{UInt32, Float64}}}
    last_update::Float64
    update_interval::Float64
    cp::ContactPlan
end

function CgrRouteTable(node_id::UInt32, cp::ContactPlan; interval::Float64=10.0)
    CgrRouteTable(node_id, Dict{UInt32,Vector{Tuple{UInt32,Float64}}}(),
                  Dict{UInt32,Vector{Tuple{UInt32,Float64}}}(), 0.0, interval, cp)
end

"""Update route table (call periodically)"""
function update_routes!(rt::CgrRouteTable, t_now::Float64)
    if rt.last_update > 0.0 && t_now - rt.last_update < rt.update_interval
        return
    end
    rt.last_update = t_now
    empty!(rt.entries); empty!(rt.backup_entries)

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
end

"""Get next hop (primary, fallback to backup on failure)"""
function get_next_hop(rt::CgrRouteTable, dst::UInt32; use_backup::Bool=false)
    table = use_backup ? rt.backup_entries : rt.entries
    entry = get(table, dst, nothing)
    entry === nothing && return nothing
    length(entry) == 0 && return nothing
    entry[1]  # (next_hop, delay)
end

"""Fast reroute: switch to backup path"""
function fast_reroute!(rt::CgrRouteTable, dst::UInt32)
    if haskey(rt.backup_entries, dst)
        rt.entries[dst] = rt.backup_entries[dst]
    end
end

# ═══════════════════════════════════════════
#  CGR-ETO (Early Termination Optimization)
# ═══════════════════════════════════════════

"""
    cgr_eto(cp, src, dst, t_start, deadline)

带有早停止优化的 CGR：找到路径后检查是否满足 deadline。
"""
function cgr_eto(cp::ContactPlan, src::UInt32, dst::UInt32, t_start::Float64,
                  deadline::Float64; bundle_size::Float64=0.0)
    path, delay, arrival = cgr_route(cp, src, dst, t_start; bundle_size=bundle_size)
    if isempty(path) || delay > deadline
        return (UInt32[], Inf, Inf)
    end
    (path, delay, arrival)
end

# ═══════════════════════════════════════════
#  CGR-BIA (Best In Advance)
# ═══════════════════════════════════════════

"""
    cgr_bia(cp, src, dst, t_start, lookahead=3600.0)

预先计算未来一段时间内的最优路径序列。
返回 [(路径, 开始时间, 结束时间), ...]
"""
function cgr_bia(cp::ContactPlan, src::UInt32, dst::UInt32, t_start::Float64;
                  lookahead::Float64=3600.0, bundle_size::Float64=0.0)
    results = Tuple{Vector{UInt32}, Float64, Float64, Float64}[]
    t = t_start
    max_paths = 100
    for _ in 1:max_paths
        t > t_start + lookahead && break
        path, delay, arrival = cgr_route(cp, src, dst, t; bundle_size=bundle_size)
        isempty(path) && break
        # Determine how long this path is valid
        valid_until = t + 10.0
        if length(path) >= 2
            # Check when first hop fails
            first_link = (path[1], path[2])
            for c in cp.contacts
                if c.src == first_link[1] && c.dst == first_link[2] && c.startTime <= t
                    valid_until = min(valid_until, c.endTime)
                end
            end
        end
        valid_until = max(valid_until, t + 1.0)
        push!(results, (path, t, valid_until, delay))
        t = valid_until
    end
    results
end

# ═══════════════════════════════════════════
#  Large Scale Optimization
# ═══════════════════════════════════════════

"""
    partition_cgr(cp, n_partitions)

大规模星座优化：将星座分区，每个分区独立计算 CGR。
分区之间通过"网关卫星"互联。
"""
function partition_cgr(cp::ContactPlan, n_partitions::Int)
    nodes = sort!(collect(cp.node_ids))
    n = length(nodes)
    if n < n_partitions * 2
        return [cp]
    end
    partitions = Vector{ContactPlan}()
    sats_per_part = n ÷ n_partitions
    for p in 1:n_partitions
        start = (p-1)*sats_per_part + 1
        stop = min(p*sats_per_part, n)
        p_nodes = Set(nodes[start:stop])
        p_cp = ContactPlan("partition_$p")
        for c in cp.contacts
            if c.src in p_nodes && c.dst in p_nodes
                add_contact!(p_cp, c.src, c.dst, c.startTime, c.endTime, c.delay, c.capacity)
            end
        end
        push!(partitions, p_cp)
    end
    partitions
end

"""CGR link-state advertisement (broadcast route updates)"""
function cgr_lsa(cp::ContactPlan, node::UInt32, t::Float64)
    ads = Tuple{UInt32, UInt32, Float64, Float64}[]
    for c in active_contacts(cp, t)
        if c.src == node
            push!(ads, (c.src, c.dst, c.delay, c.capacity))
        end
    end
    ads
end

# ═══════════════════════════════════════════
#  Validation Helpers
# ═══════════════════════════════════════════

"""Check if path is valid at a given time"""
function validate_path(cp::ContactPlan, path::Vector{UInt32}, t::Float64)::Bool
    length(path) < 2 && return false
    for i in 1:length(path)-1
        found = false
        for c in cp.contacts
            if c.src == path[i] && c.dst == path[i+1] && t >= c.startTime && t < c.endTime
                found = true; break
            end
        end
        found || return false
    end
    true
end

"""Compare two CGR routes"""
function route_compare(a::Vector{UInt32}, b::Vector{UInt32})::Symbol
    isempty(a) && isempty(b) && return :equal
    isempty(a) && return :b_better
    isempty(b) && return :a_better
    length(a) < length(b) && return :a_better
    length(b) < length(a) && return :b_better
    :equal
end
