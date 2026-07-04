# ===== 流量模型目录 =====

export list_traffic

"""
    TrafficInfo

流量模型元信息。
"""
struct TrafficInfo
    id::Symbol
    name::String
    description::String
    default_params::Dict{Symbol,Any}
    suitable_for::Vector{Symbol}
end

const TRAFFIC_CATALOG = Dict{Symbol,TrafficInfo}(
    :uniform => TrafficInfo(
        :uniform, "均匀流量", "所有用户流量相同",
        Dict(:demand_mbps => 50.0), [:coverage, :latency, :baseline],
    ),
    :hotspot => TrafficInfo(
        :hotspot, "热点流量", "20% 节点产生 80% 流量",
        Dict(:hotspot_ratio => 0.2, :peak_demand => 200.0, :base_demand => 10.0),
        [:capacity, :congestion, :load_balance],
    ),
    :video => TrafficInfo(
        :video, "视频流量", "视频业务流量模型（大下行）",
        Dict(:downlink_mean => 50.0, :uplink_mean => 5.0),
        [:capacity, :qos, :utilization],
    ),
    :iot => TrafficInfo(
        :iot, "IoT 流量", "物联网流量模型（小包、低频）",
        Dict(:packet_size_kb => 1.0, :interval_s => 300.0),
        [:coverage, :scalability],
    ),
)

list_traffic() = sort(collect(keys(TRAFFIC_CATALOG)), by = id -> TRAFFIC_CATALOG[id].name)

function describe_traffic(id::Symbol)
    haskey(TRAFFIC_CATALOG, id) || return "unknown traffic: $id"
    t = TRAFFIC_CATALOG[id]
    params = join(["$(k)=$(v)" for (k, v) in t.default_params], ", ")
    suitable = join(string.(t.suitable_for), ", ")
    return "$(t.name) — $(t.description) | 默认: [$params] | 适用: $suitable"
end

function filter_traffic_by_goal(goal::Symbol)
    results = Pair{Symbol,String}[]
    for (id, t) in TRAFFIC_CATALOG
        if goal in t.suitable_for
            push!(results, id => t.name)
        end
    end
    return results
end
