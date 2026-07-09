# ===== 实验持久化 =====

export ExperimentRecord, save_experiment, load_experiment, list_experiments

using Dates, JSON

const EXP_DIR = Ref(joinpath(@__DIR__, "..", "..", "..", "..", "data", "experiments"))

struct ExperimentRecord
    id::String
    timestamp::String
    config::Dict
    result::Dict
    notes::String
end

function ExperimentRecord(config::ExperimentConfig, result::ExperimentResult; notes::String="")
    ts = Dates.format(now(), "yyyy-mm-dd_HH:MM:SS")
    id  = "exp_$(ts)"
    c = config.constellation
    return ExperimentRecord(id, ts,
        Dict{Symbol,Any}(:name => config.name, :T => c.T, :P => c.P,
                         :alt_km => c.alt_km, :inc_deg => c.inc_deg),
        Dict{Symbol,Any}(:coverage     => result.coverage.coverage_ratio,
                         :avg_lat_ms   => result.latency.avg_latency_ms,
                         :max_lat_ms   => result.latency.max_latency_ms,
                         :diameter_ms  => result.network.diameter,
                         :connectivity => result.network.connectivity_ratio,
                         :avg_util     => result.utilization.avg_utilization,
                         :hop_count    => result.routing_metrics.avg_hop_count,
                         :success_rate => result.routing_metrics.success_rate,
                         :fitness      => result.fitness,
                         :duration_s   => result.duration_s),
        notes)
end

function save_experiment(record::ExperimentRecord)
    mkpath(EXP_DIR[])
    path = joinpath(EXP_DIR[], "$(record.id).json")
    open(path, "w") do io
        d = Dict(:id => record.id, :timestamp => record.timestamp,
            :config => record.config, :result => record.result, :notes => record.notes)
        # Replace NaN with null for JSON compatibility
        sanitize!(d)
        JSON.print(io, d)
    end
    return path
end

function load_experiment(id::String)
    path = joinpath(EXP_DIR[], "$id.json")
    isfile(path) || error("Experiment $id not found")
    d = JSON.parsefile(path)
    return ExperimentRecord(d["id"], d["timestamp"], d["config"], d["result"], get(d, "notes", ""))
end

function list_experiments()
    mkpath(EXP_DIR[])
    sort(filter(f -> endswith(f, ".json"), readdir(EXP_DIR[])), rev=true)
end

"""递归替换 NaN/Inf 为 nothing (JSON 兼容)"""
function sanitize!(d::Dict)
    for (k, v) in d
        if v isa Float64 && (isnan(v) || isinf(v))
            d[k] = nothing
        elseif v isa Dict
            sanitize!(v)
        end
    end
    return d
end
