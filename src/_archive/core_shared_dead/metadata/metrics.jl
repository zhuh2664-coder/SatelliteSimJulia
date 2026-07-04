# ===== 指标元信息 =====
# 机器可读的指标描述：单位、优化方向、适用场景

export list_metric_metadata, describe_metric, filter_metrics_by_goal

"""
    MetricInfo

指标元信息。

# 字段
- `id::Symbol`: 唯一标识
- `name::String`: 显示名称
- `unit::String`: 单位
- `objective::Symbol`: 优化方向（:minimize | :maximize）
- `description::String`: 说明
- `category::Symbol`: 类别（:network, :coverage, :utilization, ...）
- `suitable_for::Vector{Symbol}`: 适用研究目标
"""
struct MetricInfo
    id::Symbol
    name::String
    unit::String
    objective::Symbol
    description::String
    category::Symbol
    suitable_for::Vector{Symbol}
end

const METRIC_METADATA = Dict{Symbol,MetricInfo}(
    :latency => MetricInfo(
        :latency, "延迟", "ms", :minimize,
        "端到端通信延迟", :network, [:latency, :cost],
    ),
    :coverage => MetricInfo(
        :coverage, "覆盖率", "%", :maximize,
        "用户被至少一颗卫星覆盖的比例", :coverage, [:coverage],
    ),
    :connectivity => MetricInfo(
        :connectivity, "连通率", "%", :maximize,
        "卫星网络中可通信节点对比例", :network, [:cost, :vulnerability],
    ),
    :diameter => MetricInfo(
        :diameter, "网络直径", "ms", :minimize,
        "所有最短路径的最大延迟", :network, [:latency, :cost],
    ),
    :utilization => MetricInfo(
        :utilization, "链路利用率", "%", :none,
        "链路带宽使用比例", :utilization, [:cost],
    ),
)

list_metric_metadata() = sort(collect(keys(METRIC_METADATA)),
    by = id -> METRIC_METADATA[id].name)

function describe_metric(id::Symbol)
    haskey(METRIC_METADATA, id) || return "unknown metric: $id"
    m = METRIC_METADATA[id]
    arrow = m.objective == :minimize ? "↓" :
            m.objective == :maximize ? "↑" : "—"
    return "$(m.name) ($(m.unit)) $arrow — $(m.description)"
end

function filter_metrics_by_goal(goal::Symbol)
    results = Pair{Symbol,String}[]
    for (id, m) in METRIC_METADATA
        if goal in m.suitable_for
            push!(results, id => "$(m.name) ($(m.unit))")
        end
    end
    return results
end
