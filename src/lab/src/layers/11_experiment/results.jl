# ===== Experiment results =====

export ExperimentResult

struct ExperimentResult
    config::ExperimentConfig
    coverage::CoverageResult
    latency::LatencyResult
    network::NetworkMetrics
    utilization::UtilizationResult
    routing_metrics::RoutingMetrics
    fitness::Float64
    duration_s::Float64
    traffic_evaluation::Any  # Union{Nothing, TrafficEvaluation}；nothing=未跑流量
end
