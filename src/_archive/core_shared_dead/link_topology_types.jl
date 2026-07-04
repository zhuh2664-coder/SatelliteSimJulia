# ── Lightweight link topology contracts shared by link and topology layers ─────

struct LinkEndpoint
    satellite_id::Int                       # Satellite.id
end

LinkEndpoint(satellite::Satellite) = LinkEndpoint(satellite.id)

endpoint_satellite_id(endpoint::LinkEndpoint)::Int = endpoint.satellite_id
endpoint_global_id(endpoint::LinkEndpoint)::Int = endpoint.satellite_id

struct SatelliteLink{T<:Real}
    id::Int
    endpoint_a::LinkEndpoint
    endpoint_b::LinkEndpoint
    link_type::AbstractLinkType
    state::AbstractLinkState
    delay_s::T
    capacity_mbps::T

    function SatelliteLink{T}(;
        id::Int,
        endpoint_a::LinkEndpoint,
        endpoint_b::LinkEndpoint,
        link_type::AbstractLinkType = InterSatelliteLink(),
        state::AbstractLinkState = LinkAvailable(),
        delay_s::Real = 0,
        capacity_mbps::Real = Inf,
    ) where {T<:Real}
        id > 0 || throw(ArgumentError("link id must be positive"))
        endpoint_global_id(endpoint_a) != endpoint_global_id(endpoint_b) ||
            throw(ArgumentError("link endpoints must be different satellites"))
        delay_s >= 0 || throw(ArgumentError("delay_s must be non-negative"))
        capacity_mbps >= 0 || throw(ArgumentError("capacity_mbps must be non-negative"))
        return new{T}(
            id,
            endpoint_a,
            endpoint_b,
            link_type,
            state,
            T(delay_s),
            T(capacity_mbps),
        )
    end

    function SatelliteLink(;
        id::Int,
        endpoint_a::LinkEndpoint,
        endpoint_b::LinkEndpoint,
        link_type::AbstractLinkType = InterSatelliteLink(),
        state::AbstractLinkState = LinkAvailable(),
        delay_s::Real = 0,
        capacity_mbps::Real = Inf,
    )
        T = promote_type(typeof(delay_s), typeof(capacity_mbps))
        return SatelliteLink{T}(;
            id,
            endpoint_a,
            endpoint_b,
            link_type,
            state,
            delay_s,
            capacity_mbps,
        )
    end
end

struct ConstellationTopology
    constellation_name::String
    links::Vector{<:SatelliteLink}
    link_ids_by_satellite::Dict{Int,Vector{Int}}

    function ConstellationTopology(constellation_name::String, links::Vector{<:SatelliteLink})
        link_ids_by_satellite = Dict{Int,Vector{Int}}()
        for link in links
            for endpoint in (link.endpoint_a, link.endpoint_b)
                satellite_id = endpoint_global_id(endpoint)
                push!(get!(link_ids_by_satellite, satellite_id, Int[]), link.id)
            end
        end
        return new(constellation_name, links, link_ids_by_satellite)
    end
end

topology_links(topology::ConstellationTopology) = topology.links
link_count(topology::ConstellationTopology)::Int = length(topology.links)
