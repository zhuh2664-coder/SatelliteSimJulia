# ===== 指标注册表 =====
# 所有可用指标集中声明，product 层通过 list_metrics 发现。

export list_metrics, metric_type

# ── 指标类型 ──

abstract type MetricType end
struct LatencyMetric     <: MetricType end
struct CoverageMetric     <: MetricType end
struct ConnectivityMetric <: MetricType end
struct DiameterMetric     <: MetricType end
struct UtilizationMetric  <: MetricType end

# ── 内置指标 ──

const METRIC_REGISTRY = (
    latency = LatencyMetric(),
    coverage = CoverageMetric(),
    connectivity = ConnectivityMetric(),
    diameter = DiameterMetric(),
    utilization = UtilizationMetric(),
)

function metric_type(sym::Symbol)::MetricType
    haskey(METRIC_REGISTRY, sym) || error("unknown metric: $sym")
    return getproperty(METRIC_REGISTRY, sym)
end

list_metrics() = sort(collect(keys(METRIC_REGISTRY)))
