# ===== 蓝队：检测器与告警 =====
#
# 消费仿真结果（ExperimentResult 或含同名字段的任何对象），
# 基于阈值偏离检测攻击导致的异常。
#
# 设计为 duck-typing：检测器不 import ExperimentResult（避免 Security→Lab 循环依赖），
# 而是约定消费以下字段（通过 _metric_value 提取）：
#   - network.connectivity_ratio
#   - latency.avg_latency_ms / p95_ms
#   - routing_metrics.success_rate
#   - coverage.coverage_ratio
#   - utilization.avg_utilization / max_utilization

export AbstractDetector, AnomalyThreshold,
       AbstractAlarm, Alarm,
       detect, extract_metric

"""
    AbstractDetector

蓝队检测器根类型。具体检测器实现 `detect(detector, result) -> Union{Alarm,Nothing}`。
"""
abstract type AbstractDetector end

"""
    AnomalyThreshold <: AbstractDetector

阈值异常检测器：当某指标偏离基线超过阈值时触发告警。

# 字段
- `metric::Symbol`：检测的指标路径（如 :connectivity_ratio, :avg_latency_ms）
- `baseline::Float64`：正常基线值
- `threshold::Float64`：偏离阈值（绝对值），超出则告警
- `direction::Symbol`：检测方向 :both/:above/:below
"""
struct AnomalyThreshold <: AbstractDetector
    metric::Symbol
    baseline::Float64
    threshold::Float64
    direction::Symbol

    function AnomalyThreshold(;
        metric::Symbol,
        baseline::Real,
        threshold::Real,
        direction::Symbol = :both,
    )
        threshold >= 0 || throw(ArgumentError("threshold must be non-negative"))
        direction in (:both, :above, :below) ||
            throw(ArgumentError("direction must be :both, :above, or :below"))
        return new(metric, Float64(baseline), Float64(threshold), direction)
    end
end

"""
    AbstractAlarm

告警根类型。
"""
abstract type AbstractAlarm end

"""
    Alarm

检测器触发的告警。

# 字段
- `detector::AbstractDetector`：触发的检测器
- `metric::Symbol`：异常指标
- `observed::Float64`：观测值
- `baseline::Float64`：基线值
- `deviation::Float64`：偏离量（observed - baseline）
- `severity::Symbol`：严重度 :info/:warn/:critical
"""
struct Alarm <: AbstractAlarm
    detector::AbstractDetector
    metric::Symbol
    observed::Float64
    baseline::Float64
    deviation::Float64
    severity::Symbol
end

"""
    extract_metric(result, path::Symbol) -> Union{Float64,Nothing}

从仿真结果中按指标路径提取数值。约定路径：
- :connectivity_ratio → result.network.connectivity_ratio
- :avg_latency_ms → result.latency.avg_latency_ms
- :p95_ms → result.latency.p95_ms
- :success_rate → result.routing_metrics.success_rate
- :coverage_ratio → result.coverage.coverage_ratio
- :avg_utilization → result.utilization.avg_utilization
- :max_utilization → result.utilization.max_utilization

未识别路径返回 nothing。
"""
function extract_metric(result, path::Symbol)::Union{Float64,Nothing}
    val = try
        if path === :connectivity_ratio
            result.network.connectivity_ratio
        elseif path === :avg_latency_ms
            result.latency.avg_latency_ms
        elseif path === :p95_ms
            result.latency.p95_ms
        elseif path === :success_rate
            result.routing_metrics.success_rate
        elseif path === :coverage_ratio
            result.coverage.coverage_ratio
        elseif path === :avg_utilization
            result.utilization.avg_utilization
        elseif path === :max_utilization
            result.utilization.max_utilization
        else
            return nothing
        end
    catch
        return nothing
    end
    return Float64(val)
end

"""
    detect(detector::AnomalyThreshold, result) -> Union{Alarm,Nothing}

阈值检测：观测值偏离基线超过阈值则返回 Alarm，否则 nothing。
"""
function detect(detector::AnomalyThreshold, result)::Union{Alarm,Nothing}
    observed = extract_metric(result, detector.metric)
    observed === nothing && return nothing

    deviation = observed - detector.baseline
    triggered = if detector.direction === :above
        deviation > detector.threshold
    elseif detector.direction === :below
        -deviation > detector.threshold
    else  # :both
        abs(deviation) > detector.threshold
    end

    triggered || return nothing

    # 严重度：偏离 2×阈值以上为 critical，1×为 warn
    severity = abs(deviation) > 2 * detector.threshold ? :critical : :warn
    return Alarm(detector, detector.metric, observed, detector.baseline, deviation, severity)
end

"""
    detect(detectors::Vector{<:AbstractDetector}, result) -> Vector{Alarm}

批量检测：对多个检测器逐一检测，返回所有触发的告警。
"""
function detect(detectors::Vector{<:AbstractDetector}, result)::Vector{Alarm}
    alarms = Alarm[]
    for d in detectors
        a = detect(d, result)
        a !== nothing && push!(alarms, a)
    end
    return alarms
end
