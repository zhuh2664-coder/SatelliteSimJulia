# ===== 结果导出 =====

export to_dict, to_csv, to_markdown,
       export_ns3_trace, export_stk_scenario

using Printf
using JSON

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

# ────────────────────────────────────────────────────────────
# Neutral ns-3 / STK exporters
# ────────────────────────────────────────────────────────────

function _csv_cell(value)
    text = value === nothing ? "" : string(value)
    if occursin(",", text) || occursin("\"", text) || occursin("\n", text)
        return "\"" * replace(text, "\"" => "\"\"") * "\""
    end
    return text
end

function _write_csv(path::AbstractString, header::Vector{String}, rows)
    mkpath(dirname(path))
    open(path, "w") do io
        println(io, join(header, ","))
        for row in rows
            println(io, join(_csv_cell.(row), ","))
        end
    end
    return path
end

function _write_json(path::AbstractString, payload)
    mkpath(dirname(path))
    open(path, "w") do io
        println(io, JSON.json(payload, 4))
    end
    return path
end

_node_id_sat(sat_id::Int)::Int = sat_id
_node_id_ground(n_sat::Int, ground_id::Int)::Int = n_sat + ground_id

function _ground_name(gs)
    name = getproperty(gs, :name)
    return name === nothing ? "ground_$(getproperty(gs, :id))" : String(name)
end

function _ground_lat_lon_alt(gs)
    pos = getproperty(gs, :position)
    return (
        getproperty(pos, :latitude_deg),
        getproperty(pos, :longitude_deg),
        getproperty(pos, :altitude_km),
    )
end

function _load_by_link_id(samples)
    loads = Dict{Int,Any}()
    for sample in samples
        if getproperty(sample, :link_type) == :isl
            link_id = getproperty(sample, :link_id)
            link_id === nothing || (loads[Int(link_id)] = sample)
        end
    end
    return loads
end

function _join_path_ids(path::Vector{Int})
    return isempty(path) ? "" : join(path, "|")
end

"""
    export_ns3_trace(out_dir; positions, frames, demands, ground_stations, scenario_name, protocol)

Export a neutral CSV/JSON trace that can be consumed by an ns-3 scenario
generator without embedding ns-3 itself.

The exporter writes:

- `nodes.csv`: satellite and ground endpoint node table.
- `positions_tXXX.csv`: satellite ECEF positions per time slice.
- `links_tXXX.csv`: time-varying ISL link delay/capacity/load table.
- `routes_tXXX.csv`: per-demand route snapshots.
- `traffic.csv`: demand schedule.
- `scenario_manifest.json`: schema and provenance metadata.
"""
function export_ns3_trace(
    out_dir::AbstractString;
    positions::Array{Float64,3},
    frames::AbstractVector,
    demands::Vector{TrafficDemand}=TrafficDemand[],
    ground_stations::Vector{GroundStation}=GroundStation[],
    scenario_name::AbstractString="satellitesim_ns3_trace",
    protocol::AbstractString="udp",
)
    n_sat = size(positions, 1)
    n_time = size(positions, 2)
    length(frames) == n_time ||
        throw(ArgumentError("frames length must match positions time dimension"))

    mkpath(out_dir)

    node_rows = Vector{Vector{Any}}()
    for sat_id in 1:n_sat
        push!(node_rows, Any[
            _node_id_sat(sat_id), "satellite", sat_id, "sat_$sat_id",
            "", "", "", positions[sat_id, 1, 1], positions[sat_id, 1, 2], positions[sat_id, 1, 3],
        ])
    end
    for gs in ground_stations
        lat, lon, alt = _ground_lat_lon_alt(gs)
        ground_id = getproperty(gs, :id)
        push!(node_rows, Any[
            _node_id_ground(n_sat, ground_id), "ground", ground_id, _ground_name(gs),
            lat, lon, alt, "", "", "",
        ])
    end
    nodes_path = joinpath(out_dir, "nodes.csv")
    _write_csv(
        nodes_path,
        ["node_id", "node_type", "entity_id", "label", "lat_deg", "lon_deg", "alt_km", "x_km", "y_km", "z_km"],
        node_rows,
    )

    position_files = String[]
    link_files = String[]
    route_files = String[]

    for (idx, frame) in enumerate(frames)
        elapsed_s = Int(getproperty(frame, :elapsed_s))
        tag = lpad(string(idx), 3, "0")

        pos_rows = [
            Any[idx, elapsed_s, _node_id_sat(sat_id), sat_id,
                positions[sat_id, idx, 1], positions[sat_id, idx, 2], positions[sat_id, idx, 3]]
            for sat_id in 1:n_sat
        ]
        pos_path = joinpath(out_dir, "positions_t$(tag).csv")
        _write_csv(
            pos_path,
            ["time_index", "elapsed_s", "node_id", "satellite_id", "x_km", "y_km", "z_km"],
            pos_rows,
        )
        push!(position_files, basename(pos_path))

        available_isl = getproperty(frame, :available_isl)
        weights = getproperty(frame, :weights)
        load_by_id = _load_by_link_id(getproperty(frame, :link_loads))
        link_rows = Vector{Vector{Any}}()
        for (link_id, (src, dst)) in enumerate(available_isl)
            sample = get(load_by_id, link_id, nothing)
            load_mbps = sample === nothing ? 0.0 : getproperty(sample, :load_mbps)
            capacity_mbps = sample === nothing ? Inf : getproperty(sample, :capacity_mbps)
            utilization = sample === nothing ? 0.0 : getproperty(sample, :utilization)
            push!(link_rows, Any[
                idx, elapsed_s, link_id,
                _node_id_sat(Int(src)), _node_id_sat(Int(dst)), Int(src), Int(dst),
                weights[link_id], capacity_mbps, 0.0, "isl", load_mbps, utilization,
            ])
        end
        link_path = joinpath(out_dir, "links_t$(tag).csv")
        _write_csv(
            link_path,
            [
                "time_index", "elapsed_s", "link_id",
                "src_node_id", "dst_node_id", "src_satellite_id", "dst_satellite_id",
                "delay_ms", "capacity_mbps", "loss", "link_type", "load_mbps", "utilization",
            ],
            link_rows,
        )
        push!(link_files, basename(link_path))

        active_demands = getproperty(frame, :active_demands)
        routes = getproperty(frame, :routes)
        route_rows = Vector{Vector{Any}}()
        for (demand, route_output) in zip(active_demands, routes)
            path = getproperty(route_output, :path)
            total_weight = getproperty(route_output, :total_weight)
            reachable = !isempty(path) && isfinite(total_weight)
            push!(route_rows, Any[
                idx, elapsed_s, getproperty(demand, :id),
                getproperty(demand, :source_ground_id), getproperty(demand, :destination_ground_id),
                _node_id_ground(n_sat, getproperty(demand, :source_ground_id)),
                _node_id_ground(n_sat, getproperty(demand, :destination_ground_id)),
                getproperty(demand, :rate_mbps), reachable,
                reachable ? total_weight : "", getproperty(route_output, :algorithm),
                _join_path_ids(path),
            ])
        end
        route_path = joinpath(out_dir, "routes_t$(tag).csv")
        _write_csv(
            route_path,
            [
                "time_index", "elapsed_s", "demand_id",
                "source_ground_id", "destination_ground_id",
                "source_node_id", "destination_node_id",
                "rate_mbps", "reachable", "total_weight_ms", "algorithm", "path_satellite_ids",
            ],
            route_rows,
        )
        push!(route_files, basename(route_path))
    end

    traffic_rows = [
        Any[
            getproperty(demand, :id),
            getproperty(demand, :source_ground_id),
            getproperty(demand, :destination_ground_id),
            getproperty(demand, :start_elapsed_s),
            getproperty(demand, :end_elapsed_s),
            getproperty(demand, :rate_mbps),
            protocol,
        ]
        for demand in demands
    ]
    traffic_path = joinpath(out_dir, "traffic.csv")
    _write_csv(
        traffic_path,
        ["flow_id", "source_ground_id", "destination_ground_id", "start_s", "end_s", "rate_mbps", "protocol"],
        traffic_rows,
    )

    manifest = Dict{String,Any}(
        "schema" => "satellitesim_ns3_trace_v1",
        "scenario_name" => String(scenario_name),
        "satellite_count" => n_sat,
        "ground_node_count" => length(ground_stations),
        "demand_count" => length(demands),
        "time_step_count" => n_time,
        "units" => Dict(
            "position" => "km_ecef",
            "delay" => "ms",
            "capacity" => "Mbps",
            "traffic_rate" => "Mbps",
        ),
        "node_id_rule" => "satellites use 1..N; ground node id = N + ground_id",
        "files" => Dict(
            "nodes" => basename(nodes_path),
            "positions" => position_files,
            "links" => link_files,
            "routes" => route_files,
            "traffic" => basename(traffic_path),
        ),
        "limitations" => [
            "Neutral trace only; this exporter does not run ns-3.",
            "A downstream ns-3 script must map CSV rows to Node/NetDevice/Application objects.",
        ],
    )
    manifest_path = joinpath(out_dir, "scenario_manifest.json")
    _write_json(manifest_path, manifest)

    return Dict(
        "out_dir" => String(out_dir),
        "manifest" => manifest_path,
        "files" => manifest["files"],
        "satellite_count" => n_sat,
        "ground_node_count" => length(ground_stations),
        "demand_count" => length(demands),
        "time_step_count" => n_time,
    )
end

function _read_tle_records(path::AbstractString; max_sats::Int=typemax(Int))
    isfile(path) || throw(ArgumentError("TLE file not found: $path"))
    lines = [strip(line) for line in readlines(path) if !isempty(strip(line))]
    records = Vector{NTuple{3,String}}()
    i = 1
    fallback = 1
    while i <= length(lines) && length(records) < max_sats
        if startswith(lines[i], "1 ")
            i + 1 <= length(lines) || break
            push!(records, ("SAT-$fallback", lines[i], lines[i + 1]))
            i += 2
            fallback += 1
        else
            i + 2 <= length(lines) || break
            push!(records, (lines[i], lines[i + 1], lines[i + 2]))
            i += 3
        end
    end
    isempty(records) && throw(ArgumentError("no complete TLE records found in $path"))
    return records
end

"""
    export_stk_scenario(out_dir; tle_path, max_sats, ground_stations, access_requests, scenario_name)

Export a neutral STK handoff bundle without requiring STK or STK Engine on the
local machine.

The exporter writes:

- `satellites.tle`: selected TLE records.
- `facilities.csv`: ground facility coordinates.
- `access_requests.csv`: source/destination demand windows.
- `scenario_metadata.json`: schema and provenance metadata.
- `report_inputs.md`: a small human-readable import checklist.
"""
function export_stk_scenario(
    out_dir::AbstractString;
    tle_path::AbstractString,
    max_sats::Integer,
    ground_stations::Vector{GroundStation}=GroundStation[],
    access_requests::Vector{TrafficDemand}=TrafficDemand[],
    scenario_name::AbstractString="satellitesim_stk_scenario",
)
    max_sats > 0 || throw(ArgumentError("max_sats must be positive"))
    mkpath(out_dir)

    records = _read_tle_records(tle_path; max_sats=Int(max_sats))
    tle_out = joinpath(out_dir, "satellites.tle")
    open(tle_out, "w") do io
        for (name, line1, line2) in records
            println(io, name)
            println(io, line1)
            println(io, line2)
        end
    end

    facility_rows = Vector{Vector{Any}}()
    for gs in ground_stations
        lat, lon, alt = _ground_lat_lon_alt(gs)
        push!(facility_rows, Any[
            getproperty(gs, :id), _ground_name(gs), lat, lon, alt,
        ])
    end
    facilities_path = joinpath(out_dir, "facilities.csv")
    _write_csv(
        facilities_path,
        ["facility_id", "name", "lat_deg", "lon_deg", "alt_km"],
        facility_rows,
    )

    access_rows = [
        Any[
            getproperty(demand, :id),
            getproperty(demand, :source_ground_id),
            getproperty(demand, :destination_ground_id),
            getproperty(demand, :start_elapsed_s),
            getproperty(demand, :end_elapsed_s),
            getproperty(demand, :rate_mbps),
        ]
        for demand in access_requests
    ]
    access_path = joinpath(out_dir, "access_requests.csv")
    _write_csv(
        access_path,
        ["request_id", "source_facility_id", "destination_facility_id", "start_elapsed_s", "end_elapsed_s", "rate_mbps"],
        access_rows,
    )

    report_path = joinpath(out_dir, "report_inputs.md")
    open(report_path, "w") do io
        println(io, "# STK Import Bundle")
        println(io)
        println(io, "- Import `satellites.tle` as satellite objects.")
        println(io, "- Import `facilities.csv` as ground facilities.")
        println(io, "- Use `access_requests.csv` as the SatelliteSimJulia demand/access checklist.")
        println(io, "- `scenario_metadata.json` records units and provenance.")
    end

    manifest = Dict{String,Any}(
        "schema" => "satellitesim_stk_bundle_v1",
        "scenario_name" => String(scenario_name),
        "tle_source" => String(tle_path),
        "satellite_count" => length(records),
        "facility_count" => length(ground_stations),
        "access_request_count" => length(access_requests),
        "units" => Dict(
            "latitude" => "deg",
            "longitude" => "deg",
            "altitude" => "km",
            "traffic_rate" => "Mbps",
        ),
        "files" => Dict(
            "satellites_tle" => basename(tle_out),
            "facilities" => basename(facilities_path),
            "access_requests" => basename(access_path),
            "report_inputs" => basename(report_path),
        ),
        "limitations" => [
            "Neutral handoff bundle only; this exporter does not require or run STK.",
            "Access requests preserve traffic windows but do not create STK Access objects by themselves.",
        ],
    )
    metadata_path = joinpath(out_dir, "scenario_metadata.json")
    _write_json(metadata_path, manifest)

    return Dict(
        "out_dir" => String(out_dir),
        "metadata" => metadata_path,
        "files" => manifest["files"],
        "satellite_count" => length(records),
        "facility_count" => length(ground_stations),
        "access_request_count" => length(access_requests),
    )
end
