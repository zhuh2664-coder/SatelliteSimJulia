#!/usr/bin/env julia

# Reconstruct real Starlink orbits from TLE/GP data using SGP4.
#
# This is a StarPerf-style data preparation script:
#   real TLE records -> launch metadata -> TLEOrbitElementSet -> SGP4 ECEF positions.

using Dates
using Downloads
using JSON
using Printf
using Serialization
using Statistics

using SatelliteSimFoundation
using SatelliteSimOrbit

const CELESTRAK_STARLINK_GP_JSON =
    "https://celestrak.org/NORAD/elements/gp.php?GROUP=starlink&FORMAT=json"
const CELESTRAK_SATCAT_CSV = "https://celestrak.org/pub/satcat.csv"

function parse_args(argv)
    args = Dict{String,String}()
    flags = Set{String}()
    i = 1
    while i <= length(argv)
        a = argv[i]
        if startswith(a, "--")
            key = a[3:end]
            if i < length(argv) && !startswith(argv[i + 1], "--")
                args[key] = argv[i + 1]
                i += 2
            else
                push!(flags, key)
                i += 1
            end
        else
            i += 1
        end
    end
    return args, flags
end

get_int(args, key, default) = parse(Int, get(args, key, string(default)))
get_string(args, key, default) = get(args, key, default)
has_flag(flags, key) = key in flags

function project_root()
    return normpath(joinpath(@__DIR__, ".."))
end

function maybe_download(url::AbstractString, path::AbstractString; force::Bool=false)
    if force || !isfile(path)
        mkpath(dirname(path))
        try
            Downloads.download(url, path)
        catch err
            if Sys.which("curl") === nothing
                rethrow(err)
            end
            run(`curl -L --fail --silent --show-error -A Mozilla/5.0 --output $path $url`)
        end
    end
    return path
end

function read_tle_text_file(path::AbstractString; default_name_prefix::AbstractString="SAT")
    isfile(path) || throw(ArgumentError("TLE file not found: $path"))
    lines = [strip(line) for line in readlines(path) if !isempty(strip(line))]
    records = SatelliteSimOrbit.TLERecordSpec[]
    i = 1
    fallback_id = 1
    while i <= length(lines)
        if startswith(lines[i], "1 ")
            name = "$(default_name_prefix)-$(fallback_id)"
            line1 = lines[i]
            line2 = i + 1 <= length(lines) ? lines[i + 1] : ""
            i += 2
            fallback_id += 1
        else
            name = lines[i]
            line1 = i + 1 <= length(lines) ? lines[i + 1] : ""
            line2 = i + 2 <= length(lines) ? lines[i + 2] : ""
            i += 3
        end
        startswith(line1, "1 ") || throw(ArgumentError("invalid TLE line 1 near record $(length(records) + 1): $line1"))
        startswith(line2, "2 ") || throw(ArgumentError("invalid TLE line 2 near record $(length(records) + 1): $line2"))
        push!(records, SatelliteSimOrbit.TLERecordSpec(name, line1, line2))
    end
    return records
end

function load_records(args, flags)
    root = project_root()
    source = get_string(args, "source", "celestrak-starlink")
    if has_flag(flags, "download-gp-json")
        json_path = get_string(
            args,
            "gp-json-path",
            joinpath(root, "data", "tle", "celestrak", "starlink_gp_latest.json"),
        )
        maybe_download(CELESTRAK_STARLINK_GP_JSON, json_path; force=true)
        src = SatelliteSimOrbit.StarPerfTLEJsonSource(
            "celestrak-starlink-json",
            json_path;
            verify_with_juliaspace = false,
        )
        return SatelliteSimOrbit.load_tle_records(src), "celestrak-starlink-json", json_path
    end

    registry = SatelliteSimOrbit.default_tle_source_registry(project_root=root)
    src = SatelliteSimOrbit.resolve_tle_source(registry, source)
    if src isa SatelliteSimOrbit.TLETextFileSource
        records = read_tle_text_file(src.path; default_name_prefix=src.default_name_prefix)
        return records, source, src.path
    end
    records = SatelliteSimOrbit.load_tle_records(src)
    return records, source, getfield(src, :path)
end

function parse_tle_satnum(line1::AbstractString)
    return parse(Int, strip(line1[3:7]))
end

function parse_tle_designator(line1::AbstractString)
    raw = strip(line1[10:min(end, 17)])
    isempty(raw) && return ("", missing, missing, "")
    m = match(r"^(\d{2})(\d{3})([A-Z]+)$", raw)
    m === nothing && return (raw, missing, missing, "")
    yy = parse(Int, m.captures[1])
    year = yy >= 57 ? 1900 + yy : 2000 + yy
    launch_number = parse(Int, m.captures[2])
    piece = m.captures[3]
    object_id = @sprintf("%04d-%03d%s", year, launch_number, piece)
    return (object_id, year, launch_number, piece)
end

function tle_epoch(record)
    tle = SatelliteSimOrbit.satellite_toolbox_tle(
        SatelliteSimOrbit.TLEOrbitElementSet(record.name, record.line1, record.line2);
        verify_checksum = false,
    )
    return SatelliteSimOrbit.SatelliteToolbox.tle_epoch(DateTime, tle)
end

function parse_simple_csv(path::AbstractString)
    lines = readlines(path)
    isempty(lines) && return Dict{String,String}[]
    header = split(lines[1], ',')
    rows = Dict{String,String}[]
    for line in lines[2:end]
        isempty(strip(line)) && continue
        cols = split(line, ',')
        length(cols) < length(header) && continue
        push!(rows, Dict(header[i] => cols[i] for i in eachindex(header)))
    end
    return rows
end

function load_satcat(args, flags)
    root = project_root()
    satcat_path = get_string(args, "satcat-path", joinpath(root, "data", "tle", "celestrak", "satcat.csv"))
    if has_flag(flags, "download-satcat")
        maybe_download(CELESTRAK_SATCAT_CSV, satcat_path; force=true)
    end
    isfile(satcat_path) || return Dict{Int,Dict{String,String}}(), satcat_path, false
    rows = parse_simple_csv(satcat_path)
    by_norad = Dict{Int,Dict{String,String}}()
    for row in rows
        startswith(get(row, "OBJECT_NAME", ""), "STARLINK") || continue
        norad = tryparse(Int, get(row, "NORAD_CAT_ID", ""))
        norad === nothing && continue
        by_norad[norad] = row
    end
    return by_norad, satcat_path, true
end

function choose_epoch(records, mode::String)
    epochs = DateTime[tle_epoch(r) for r in records]
    if mode == "tle-min"
        return minimum(epochs)
    elseif mode == "tle-max"
        return maximum(epochs)
    elseif mode == "tle-median"
        vals = sort(Dates.value.(epochs))
        return DateTime(Dates.UTM(round(Int, vals[cld(length(vals), 2)])))
    else
        return DateTime(mode)
    end
end

function build_metadata(records, satcat_by_norad)
    out = Vector{Dict{String,Any}}(undef, length(records))
    for (i, r) in enumerate(records)
        norad = parse_tle_satnum(r.line1)
        object_id, launch_year, launch_number, launch_piece = parse_tle_designator(r.line1)
        satcat = get(satcat_by_norad, norad, Dict{String,String}())
        out[i] = Dict{String,Any}(
            "index" => i,
            "name" => strip(r.name),
            "norad_cat_id" => norad,
            "object_id" => object_id,
            "launch_year" => launch_year,
            "launch_number" => launch_number,
            "launch_piece" => launch_piece,
            "launch_group" => (ismissing(launch_year) || ismissing(launch_number)) ?
                "" : @sprintf("%04d-%03d", launch_year, launch_number),
            "launch_date" => get(satcat, "LAUNCH_DATE", ""),
            "launch_site" => get(satcat, "LAUNCH_SITE", ""),
            "ops_status_code" => get(satcat, "OPS_STATUS_CODE", ""),
            "decay_date" => get(satcat, "DECAY_DATE", ""),
        )
    end
    return out
end

function group_counts(metadata, key)
    counts = Dict{String,Int}()
    for row in metadata
        value = string(get(row, key, ""))
        isempty(value) && continue
        counts[value] = get(counts, value, 0) + 1
    end
    return sort(collect(counts), by=x -> (-x.second, x.first))
end

function orbital_bins(records)
    inclinations = Float64[]
    motions = Float64[]
    for r in records
        fields = split(r.line2)
        length(fields) >= 8 || continue
        push!(inclinations, parse(Float64, fields[3]))
        push!(motions, parse(Float64, fields[8]))
    end
    return Dict(
        "inclination_min_deg" => minimum(inclinations),
        "inclination_max_deg" => maximum(inclinations),
        "inclination_median_deg" => median(inclinations),
        "mean_motion_min_rev_day" => minimum(motions),
        "mean_motion_max_rev_day" => maximum(motions),
        "mean_motion_median_rev_day" => median(motions),
    )
end

function reconstruct(records, epoch::DateTime, duration_s::Int, step_s::Int)
    elements = [
        SatelliteSimOrbit.TLEOrbitElementSet(r.name, r.line1, r.line2)
        for r in records
    ]
    grid = SimulationTimeGrid(SimulationEpoch(epoch), duration_s, step_s)
    positions = SatelliteSimOrbit.propagate_to_ecef(elements, grid; verify_checksum=false)
    return positions, grid
end

function main(argv=ARGS)
    args, flags = parse_args(argv)
    max_sats = get_int(args, "max-sats", 256)
    duration_s = get_int(args, "duration-s", 600)
    step_s = get_int(args, "step-s", 60)
    epoch_mode = get_string(args, "epoch", "tle-median")
    outdir = get_string(args, "output-dir", joinpath(project_root(), "outputs", "starlink_real_orbits"))
    write_positions = has_flag(flags, "write-positions")

    records_all, source_id, source_path = load_records(args, flags)
    isempty(records_all) && error("no TLE records loaded")
    selected = max_sats == 0 ? records_all : records_all[1:min(max_sats, length(records_all))]
    satcat_by_norad, satcat_path, satcat_loaded = load_satcat(args, flags)
    epoch = choose_epoch(selected, epoch_mode)

    mkpath(outdir)
    positions, grid = reconstruct(selected, epoch, duration_s, step_s)
    metadata = build_metadata(selected, satcat_by_norad)

    positions_path = ""
    if write_positions
        positions_path = joinpath(outdir, "starlink_real_ecef_positions.jls")
        serialize(positions_path, positions)
    end

    summary = Dict{String,Any}(
        "source_id" => source_id,
        "source_path" => source_path,
        "records_available" => length(records_all),
        "satellites_reconstructed" => length(selected),
        "epoch_utc" => string(epoch),
        "duration_s" => duration_s,
        "step_s" => step_s,
        "time_count" => time_count(grid),
        "position_shape" => collect(size(positions)),
        "position_frame" => "ECEF",
        "position_unit" => "km",
        "satcat_path" => satcat_path,
        "satcat_loaded" => satcat_loaded,
        "satcat_starlink_rows" => length(satcat_by_norad),
        "launch_group_count" => length(group_counts(metadata, "launch_group")),
        "top_launch_groups" => [
            Dict("launch_group" => p.first, "count" => p.second)
            for p in group_counts(metadata, "launch_group")[1:min(end, 10)]
        ],
        "top_launch_dates" => [
            Dict("launch_date" => p.first, "count" => p.second)
            for p in group_counts(metadata, "launch_date")[1:min(end, 10)]
        ],
        "orbital_stats" => orbital_bins(selected),
        "positions_path" => positions_path,
        "sample_satellites" => metadata[1:min(end, 10)],
    )

    summary_path = joinpath(outdir, "starlink_real_orbits_summary.json")
    open(summary_path, "w") do io
        JSON.print(io, summary, 2)
    end

    println("Starlink real orbit reconstruction complete")
    println("source: $source_id")
    println("records available: $(length(records_all))")
    println("satellites reconstructed: $(length(selected))")
    println("epoch UTC: $epoch")
    println("positions shape: $(size(positions)) ECEF km")
    println("launch groups: $(summary["launch_group_count"])")
    println("satcat loaded: $satcat_loaded ($(length(satcat_by_norad)) Starlink rows)")
    println("summary: $summary_path")
    !isempty(positions_path) && println("positions: $positions_path")
end

main()
