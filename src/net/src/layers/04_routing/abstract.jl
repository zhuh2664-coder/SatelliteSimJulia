# ===== 路由 — 抽象类型 =====

using Graphs

export AbstractRoutingAlgorithm, RoutingInput, RoutingOutput, RoutingGraph,
       routing_graph_from_edges, route, batch_route, build_routing_graph

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
    # 单位继承自输入 RoutingGraph 的边权；Net 层不做 ms/s 转换。
    total_weight::Float64
    algorithm::String
end

abstract type AbstractRoutingAlgorithm end

function routing_graph_from_edges(
    n_nodes::Int,
    edges::Vector{Tuple{Int,Int}},
    weights::Vector{Float64};
    bidirectional::Bool=true,
)::RoutingGraph
    length(edges) == length(weights) ||
        throw(ArgumentError("edges and weights must have the same length"))

    adj = Dict{Int,Vector{Tuple{Int,Float64}}}()
    graph = SimpleDiGraph(n_nodes)

    for (idx, (src, dst)) in enumerate(edges)
        1 <= src <= n_nodes || throw(ArgumentError("edge source must be in 1:n_nodes"))
        1 <= dst <= n_nodes || throw(ArgumentError("edge destination must be in 1:n_nodes"))
        weight = weights[idx]

        add_edge!(graph, src, dst)
        push!(get!(adj, src, Tuple{Int,Float64}[]), (dst, weight))

        if bidirectional
            add_edge!(graph, dst, src)
            push!(get!(adj, dst, Tuple{Int,Float64}[]), (src, weight))
        end
    end

    return RoutingGraph(n_nodes, adj, string.(1:n_nodes), graph)
end

function route(alg::AbstractRoutingAlgorithm, input::RoutingInput)::RoutingOutput
    error("未实现的 route 方法: $(typeof(alg))")
end

function batch_route(alg::AbstractRoutingAlgorithm, graph::RoutingGraph, pairs::Vector{Tuple{Int,Int}})::Vector{RoutingOutput}
    return [route(alg, RoutingInput(graph, s, d)) for (s, d) in pairs]
end
