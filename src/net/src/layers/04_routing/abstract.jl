# ===== 路由 — 抽象类型 =====

using Graphs

export AbstractRoutingAlgorithm, RoutingInput, RoutingOutput, RoutingGraph,
       route, batch_route

struct RoutingGraph
    n_nodes::Int
    adj::Dict{Int,Vector{Tuple{Int,Float64}}}
    node_labels::Vector{String}
    g::SimpleDiGraph
end

struct RoutingInput
    graph::RoutingGraph
    source::Int
    destination::Int
end

struct RoutingOutput
    path::Vector{Int}
    total_weight::Float64
    algorithm::String
end

abstract type AbstractRoutingAlgorithm end

function route(alg::AbstractRoutingAlgorithm, input::RoutingInput)::RoutingOutput
    error("未实现的 route 方法: $(typeof(alg))")
end

function batch_route(alg::AbstractRoutingAlgorithm, graph::RoutingGraph, pairs::Vector{Tuple{Int,Int}})::Vector{RoutingOutput}
    return [route(alg, RoutingInput(graph, s, d)) for (s, d) in pairs]
end
