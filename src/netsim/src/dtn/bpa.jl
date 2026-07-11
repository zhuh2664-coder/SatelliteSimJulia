# Bundle Protocol Agent — store-and-forward over ContactPlan + CGR

export DtnNode, DtnSimResult, simulate_dtn_forward

"""
    DtnNode

One DTN node with local EID, bundle store, and stats.
"""
mutable struct DtnNode
    id::UInt32
    eid::BundleEID
    store::BundleStore
    created::Int
    forwarded::Int
    delivered::Int
    expired::Int
    deferred::Int
end

function DtnNode(id::Integer; service::AbstractString="bpa")
    eid = BundleEID("dtn", "$(Int(id))/$service")
    return DtnNode(UInt32(id), eid, BundleStore(), 0, 0, 0, 0, 0)
end

struct DtnSimResult
    delivered::Bool
    delivery_time::Float64
    path::Vector{UInt32}
    hops::Int
    created::Int
    forwarded::Int
    deferred::Int
    expired::Int
end

"""
    simulate_dtn_forward(plan, src, dst, payload; t0=0.0, lifetime=3600.0)

Store-and-forward a single Bundle using CGR at each hop.
If the next contact is not yet open, the bundle waits (custody) until it is.
"""
function simulate_dtn_forward(
    plan::ContactPlan,
    src::Integer,
    dst::Integer,
    payload::Vector{UInt8};
    t0::Real=0.0,
    lifetime::Float64=3600.0,
    max_events::Int=10_000,
)
    s, d = UInt32(src), UInt32(dst)
    nodes = Dict{UInt32,DtnNode}()
    for nid in plan.node_ids
        nodes[nid] = DtnNode(nid)
    end
    haskey(nodes, s) || (nodes[s] = DtnNode(s))
    haskey(nodes, d) || (nodes[d] = DtnNode(d))

    b = Bundle(nodes[s].eid, nodes[d].eid, payload; lifetime=lifetime, creation_time=Float64(t0))
    nodes[s].created += 1

    t = Float64(t0)
    cur = s
    path = UInt32[s]
    hops = 0
    deferred = 0
    events = 0

    if s == d
        nodes[d].delivered += 1
        return DtnSimResult(true, t, path, 0, 1, 0, 0, 0)
    end

    while cur != d && events < max_events
        events += 1
        if is_expired(b, t)
            nodes[cur].expired += 1
            return DtnSimResult(false, t, path, hops, nodes[s].created,
                               sum(n.forwarded for n in values(nodes)),
                               deferred, nodes[cur].expired)
        end

        route = cgr_route(plan, cur, d, t)
        if !route.reachable || length(route.path) < 2
            # wait for any future outbound contact from cur
            future = [c for c in plan.contacts if c.src == cur && c.start_time > t]
            isempty(future) && return DtnSimResult(
                false, t, path, hops, nodes[s].created,
                sum(n.forwarded for n in values(nodes)), deferred, 0,
            )
            wait_t = minimum(c.start_time for c in future) - t
            t += wait_t
            deferred += 1
            nodes[cur].deferred += 1
            continue
        end

        next_hop = route.path[2]
        # find the contact used (or earliest usable) cur → next_hop
        cands = [c for c in plan.contacts if c.src == cur && c.dst == next_hop && c.end_time > t]
        isempty(cands) && return DtnSimResult(
            false, t, path, hops, nodes[s].created,
            sum(n.forwarded for n in values(nodes)), deferred, 0,
        )
        sort!(cands, by=c -> c.start_time)
        c = cands[1]
        if t < c.start_time
            deferred += 1
            nodes[cur].deferred += 1
            t = c.start_time
        end
        # transmit + propagate
        t = t + c.delay_s
        store_bundle!(nodes[cur].store, b; now=t)  # custody snapshot
        take_bundle!(nodes[cur].store)
        nodes[cur].forwarded += 1
        hops += 1
        cur = next_hop
        push!(path, cur)
        b.hop_count += 1
        b.custodian = nodes[cur].eid
    end

    delivered = cur == d
    delivered && (nodes[d].delivered += 1)
    return DtnSimResult(
        delivered,
        t,
        path,
        hops,
        nodes[s].created,
        sum(n.forwarded for n in values(nodes)),
        deferred,
        sum(n.expired for n in values(nodes)),
    )
end
