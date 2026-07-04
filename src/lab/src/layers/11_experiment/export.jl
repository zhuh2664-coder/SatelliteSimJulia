# ===== 结果导出 =====

export to_dict, to_csv, to_markdown

using Printf

"""ExperimentResult → Dict"""
function to_dict(result::ExperimentResult)
    return Dict(
        :coverage     => result.coverage.coverage_ratio,
        :avg_lat_ms   => result.latency.avg_latency_ms,
        :max_lat_ms   => result.latency.max_latency_ms,
        :diameter_ms  => result.network.diameter,
        :connectivity => result.network.connectivity_ratio,
        :avg_util     => result.utilization.avg_utilization,
        :hop_count    => result.routing_metrics.avg_hop_count,
        :success_rate => result.routing_metrics.success_rate,
        :fitness      => result.fitness,
        :duration_s   => result.duration_s,
    )
end

"""多结果 → CSV"""
function to_csv(results::Vector{Pair{String,ExperimentResult}})
    hdr = "name,T,P,alt_km,inc_deg,coverage,latency_ms,diameter_ms,conn,hop,success,duration_s"
    lines = String[hdr]
    for (label, r) in results
        c = r.config.constellation
        push!(lines, join([
            label, c.T, c.P, round(c.alt_km, digits=1), round(c.inc_deg, digits=1),
            round(r.coverage.coverage_ratio, digits=3),
            round(r.latency.avg_latency_ms, digits=1),
            round(r.network.diameter, digits=1),
            round(r.network.connectivity_ratio, digits=3),
            round(r.routing_metrics.avg_hop_count, digits=1),
            round(r.routing_metrics.success_rate, digits=3),
            round(r.duration_s, digits=2),
        ], ","))
    end
    return join(lines, "\n")
end

"""多结果 → Markdown 对比表"""
function to_markdown(results::Vector{Pair{String,ExperimentResult}})
    rows = ["| Config | T | P | Alt(km) | Coverage | Lat(ms) | Diam(ms) | Conn | Hops | Time(s) |",
            "|--------|---|---|---------|----------|---------|----------|------|------|---------|"]
    for (label, r) in results
        c = r.config.constellation
        push!(rows, "| $label | $(c.T) | $(c.P) | $(round(c.alt_km,digits=1)) | " *
            "$(round(r.coverage.coverage_ratio,digits=3)) | $(round(r.latency.avg_latency_ms,digits=1)) | " *
            "$(round(r.network.diameter,digits=1)) | $(round(r.network.connectivity_ratio,digits=3)) | " *
            "$(round(r.routing_metrics.avg_hop_count,digits=1)) | $(round(r.duration_s,digits=2)) |")
    end
    return join(rows, "\n")
end
