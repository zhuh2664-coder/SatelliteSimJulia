# Contact Plan — DTN contact windows for LEO ISL

export Contact, ContactPlan, add_contact!, query_contacts, query_all_contacts
export build_contact_plan_from_pos!, merge_contacts!, contact_stats

"""
    Contact

One directed contact window: `src → dst` available in `[start_time, end_time)`.
"""
struct Contact
    src::UInt32
    dst::UInt32
    start_time::Float64
    end_time::Float64
    delay_s::Float64
    capacity_bps::Float64
end

"""
    ContactPlan

Collection of contacts used by Contact Graph Routing (CGR).
"""
mutable struct ContactPlan
    contacts::Vector{Contact}
    node_ids::Set{UInt32}
end

ContactPlan() = ContactPlan(Contact[], Set{UInt32}())

function add_contact!(
    plan::ContactPlan,
    src::Integer,
    dst::Integer,
    start_time::Real,
    end_time::Real,
    delay_s::Real,
    capacity_bps::Real=1e9,
)
    end_time > start_time || throw(ArgumentError("end_time must be > start_time"))
    delay_s >= 0 || throw(ArgumentError("delay_s must be non-negative"))
    c = Contact(UInt32(src), UInt32(dst), Float64(start_time), Float64(end_time),
                Float64(delay_s), Float64(capacity_bps))
    push!(plan.contacts, c)
    push!(plan.node_ids, c.src, c.dst)
    return c
end

"""Contacts from `src` to `dst` active at time `t`."""
function query_contacts(plan::ContactPlan, src::Integer, dst::Integer, t::Real)
    s, d, tt = UInt32(src), UInt32(dst), Float64(t)
    return [c for c in plan.contacts if c.src == s && c.dst == d && tt >= c.start_time && tt < c.end_time]
end

"""All outbound contacts from `src` active at time `t`."""
function query_all_contacts(plan::ContactPlan, src::Integer, t::Real)
    s, tt = UInt32(src), Float64(t)
    return [c for c in plan.contacts if c.src == s && tt >= c.start_time && tt < c.end_time]
end

"""
    merge_contacts!(plan; gap_tol=1e-9)

Merge consecutive identical (src,dst) contacts with matching delay/capacity
when the next starts within `gap_tol` of the previous end.
"""
function merge_contacts!(plan::ContactPlan; gap_tol::Float64=1e-9)
    isempty(plan.contacts) && return plan
    sorted = sort(plan.contacts, by=c -> (c.src, c.dst, c.start_time))
    merged = Contact[]
    cur = sorted[1]
    for i in 2:length(sorted)
        n = sorted[i]
        same = n.src == cur.src && n.dst == cur.dst &&
               abs(n.delay_s - cur.delay_s) < 1e-12 &&
               abs(n.capacity_bps - cur.capacity_bps) < 1e-6
        contiguous = n.start_time <= cur.end_time + gap_tol
        if same && contiguous
            cur = Contact(cur.src, cur.dst, cur.start_time, max(cur.end_time, n.end_time),
                          cur.delay_s, cur.capacity_bps)
        else
            push!(merged, cur)
            cur = n
        end
    end
    push!(merged, cur)
    plan.contacts = merged
    return plan
end

"""
    build_contact_plan_from_pos!(plan, pos, node_ids; max_dist_km, t_start, dt)

Build bidirectional contacts from an `N×T×3` ECEF position matrix (km).
Each time slice where distance < `max_dist_km` becomes a contact of length `dt`.
"""
function build_contact_plan_from_pos!(
    plan::ContactPlan,
    pos::AbstractArray{<:Real,3},
    node_ids::AbstractVector{<:Integer};
    max_dist_km::Real=5000.0,
    t_start::Real=0.0,
    dt::Real=1.0,
    capacity_bps::Real=1e9,
    c_km_s::Real=299792.458,
)
    n, T = size(pos, 1), size(pos, 2)
    length(node_ids) == n || throw(ArgumentError("node_ids length must match N"))
    ids = UInt32[UInt32(x) for x in node_ids]
    for t_idx in 1:T
        sim_t = Float64(t_start) + (t_idx - 1) * Float64(dt)
        for i in 1:n, j in (i + 1):n
            d = sqrt(sum(abs2, @view(pos[i, t_idx, :]) .- @view(pos[j, t_idx, :])))
            if d < max_dist_km
                delay = d / c_km_s
                add_contact!(plan, ids[i], ids[j], sim_t, sim_t + dt, delay, capacity_bps)
                add_contact!(plan, ids[j], ids[i], sim_t, sim_t + dt, delay, capacity_bps)
            end
        end
    end
    merge_contacts!(plan)
    return plan
end

function contact_stats(plan::ContactPlan)
    n = length(plan.contacts)
    n == 0 && return (n_contacts=0, n_nodes=0, mean_delay_ms=0.0, mean_duration_s=0.0)
    delays = [c.delay_s for c in plan.contacts]
    durs = [c.end_time - c.start_time for c in plan.contacts]
    return (
        n_contacts=n,
        n_nodes=length(plan.node_ids),
        mean_delay_ms=1000 * sum(delays) / n,
        mean_duration_s=sum(durs) / n,
    )
end
