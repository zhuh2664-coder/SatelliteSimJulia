# Contact Graph Routing (CGR) — time-aware shortest path on a ContactPlan

export CgrRoute, cgr_route, cgr_earliest_arrival

"""
    CgrRoute

Result of a CGR search.
"""
struct CgrRoute
    path::Vector{UInt32}
    arrival_time::Float64
    total_delay_s::Float64
    contacts::Vector{Contact}
    reachable::Bool
end

"""
    cgr_route(plan, src, dst, t0; deadline=Inf) -> CgrRoute

Contact Graph Routing: find a path from `src` to `dst` starting at time `t0`.

At each node the algorithm waits for the next usable contact (if needed),
then traverses it. Edge cost is waiting + propagation delay.
"""
function cgr_route(
    plan::ContactPlan,
    src::Integer,
    dst::Integer,
    t0::Real;
    deadline::Real=Inf,
)
    s, d = UInt32(src), UInt32(dst)
    s == d && return CgrRoute([s], Float64(t0), 0.0, Contact[], true)

    # Group contacts by source for O(k) neighbor scans
    by_src = Dict{UInt32,Vector{Contact}}()
    for c in plan.contacts
        push!(get!(by_src, c.src, Contact[]), c)
    end
    for v in values(by_src)
        sort!(v, by=c -> c.start_time)
    end

    # Dijkstra on (node) with arrival-time as distance
    best_arr = Dict{UInt32,Float64}(s => Float64(t0))
    prev_node = Dict{UInt32,UInt32}()
    prev_contact = Dict{UInt32,Contact}()
    visited = Set{UInt32}()

    while true
        # pick unvisited node with earliest arrival
        u = nothing
        best = Inf
        for (n, arr) in best_arr
            if !(n in visited) && arr < best
                u = n
                best = arr
            end
        end
        u === nothing && break
        u == d && break
        best > deadline && break
        push!(visited, u)

        for c in get(by_src, u, Contact[])
            # contact must not have already ended before we arrive
            c.end_time <= best && continue
            depart = max(best, c.start_time)
            arrive = depart + c.delay_s
            arrive > deadline && continue
            # must finish transmission within contact window (zero-size bundle approx)
            depart >= c.end_time && continue
            if arrive < get(best_arr, c.dst, Inf)
                best_arr[c.dst] = arrive
                prev_node[c.dst] = u
                prev_contact[c.dst] = c
            end
        end
    end

    if !haskey(best_arr, d)
        return CgrRoute(UInt32[], Inf, Inf, Contact[], false)
    end

    # reconstruct
    path = UInt32[d]
    contacts = Contact[]
    cur = d
    while cur != s
        haskey(prev_node, cur) || return CgrRoute(UInt32[], Inf, Inf, Contact[], false)
        pushfirst!(contacts, prev_contact[cur])
        cur = prev_node[cur]
        pushfirst!(path, cur)
    end
    arr = best_arr[d]
    return CgrRoute(path, arr, arr - Float64(t0), contacts, true)
end

"""Earliest arrival time, or `Inf` if unreachable."""
function cgr_earliest_arrival(plan::ContactPlan, src::Integer, dst::Integer, t0::Real)
    r = cgr_route(plan, src, dst, t0)
    return r.reachable ? r.arrival_time : Inf
end
