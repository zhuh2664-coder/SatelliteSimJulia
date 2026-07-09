#!/usr/bin/env julia

# Enumerate the finite built-in experiment menu and run a lightweight execution
# probe. Arbitrary Walker/tspan/constraint/user inputs make the theoretical
# space unbounded; this script counts the built-in intent/cata­log style space.

using Printf
using Test

using SatelliteSimCore
using SatelliteSimLab
using SatelliteSimNet

const RUN_MODE = get(ENV, "SATSIM_EXPERIMENT_MATRIX_MODE", "smoke")
const FULL_CONSTRUCT = get(ENV, "SATSIM_EXPERIMENT_MATRIX_FULL_CONSTRUCT", "0") == "1"

named(name, value) = (name = Symbol(name), value = value)

function small_ground_stations()
    return [
        GroundStation(id = 1, name = "beijing", position = GeodeticPosition(39.9042, 116.4074, 0.0)),
        GroundStation(id = 2, name = "singapore", position = GeodeticPosition(1.3521, 103.8198, 0.0)),
        GroundStation(id = 3, name = "london", position = GeodeticPosition(51.5072, -0.1276, 0.0)),
        GroundStation(id = 4, name = "sydney", position = GeodeticPosition(-33.8688, 151.2093, 0.0)),
    ]
end

function small_users()
    return [
        GroundUser("beijing", 39.9042, 116.4074, 20.0, 100.0, "probe"),
        GroundUser("singapore", 1.3521, 103.8198, 20.0, 100.0, "probe"),
        GroundUser("london", 51.5072, -0.1276, 20.0, 100.0, "probe"),
        GroundUser("sydney", -33.8688, 151.2093, 20.0, 100.0, "probe"),
    ]
end

function dimensions()
    coverage = [
        named(:global, GlobalCoverage()),
        named(:polar, PolarCoverage()),
        named(:midlat, MidLatCoverage()),
    ]
    latency = [
        named(:low_latency, LowLatencyConst()),
        named(:mid_latency, MidLatencyConst()),
        named(:high_latency, HighLatencyConst()),
    ]
    scale = [
        named(:small, SmallScale()),
        named(:medium, MediumScale()),
        named(:large, LargeScale()),
    ]
    propagator = [
        named(:speed_focus, SpeedFocus()),
        named(:balanced, BalancedProp()),
        named(:precision_focus, PrecisionFocus()),
    ]
    time_horizon = [
        named(:snapshot, Snapshot()),
        named(:single_orbit, SingleOrbit()),
        named(:full_day, FullDay()),
    ]
    constraint = [
        named(:strict, StrictLink()),
        named(:balanced, BalancedLink()),
        named(:relaxed, RelaxedLink()),
    ]
    topology = [
        named(:low_latency, LowLatencyTopo()),
        named(:high_robust, HighRobustTopo()),
        named(:balanced, BalancedTopo()),
        named(:low_cost, LowCostTopo()),
    ]
    routing = [
        named(:shortest_path, ShortestPath()),
        named(:load_balanced, LoadBalanced()),
        named(:multipath, MultipathIntent()),
    ]
    traffic = [
        named(:uniform, UniformLoad()),
        named(:hotspot, HotspotLoad()),
        named(:video, VideoLoad()),
        named(:iot, IoTLoad()),
    ]
    return (; coverage, latency, scale, propagator, time_horizon, constraint, topology, routing, traffic)
end

function builtin_intent_count(dims)
    constellation = length(dims.coverage) * length(dims.latency) * length(dims.scale)
    return constellation *
        length(dims.propagator) *
        length(dims.time_horizon) *
        length(dims.constraint) *
        length(dims.topology) *
        length(dims.routing) *
        length(dims.traffic)
end

function build_config(label; coverage, latency, scale, propagator, time_horizon, constraint, topology, routing, traffic)
    return ExperimentConfig(
        name = string(label),
        constellation = ConstellationIntent(
            coverage = coverage,
            latency = latency,
            scale = scale,
        ),
        propagator = propagator,
        tspan = time_horizon,
        constraints = constraint,
        topology_strategy = topology,
        routing_algorithm = routing,
        traffic = traffic,
        ground_stations = small_ground_stations(),
        users = small_users(),
        ground_pairs = [(1, 2), (1, 3), (2, 4)],
        random_seed = 42,
    )
end

function construct_all(dims)
    total = 0
    failures = String[]
    for cv in dims.coverage, lv in dims.latency, sv in dims.scale,
        pv in dims.propagator, tv in dims.time_horizon, kv in dims.constraint,
        topv in dims.topology, rv in dims.routing, trv in dims.traffic

        total += 1
        label = "construct_$(cv.name)_$(lv.name)_$(sv.name)_$(pv.name)_$(tv.name)_$(kv.name)_$(topv.name)_$(rv.name)_$(trv.name)"
        try
            cfg = build_config(
                label;
                coverage = cv.value,
                latency = lv.value,
                scale = sv.value,
                propagator = pv.value,
                time_horizon = tv.value,
                constraint = kv.value,
                topology = topv.value,
                routing = rv.value,
                traffic = trv.value,
            )
            cfg isa ExperimentConfig || push!(failures, "$label => not ExperimentConfig")
        catch err
            push!(failures, "$label => $(typeof(err)): $(sprint(showerror, err))")
        end
    end
    return total, failures
end

function construct_probe(dims)
    cases = smoke_cases(dims)
    failures = String[]
    for (label, params) in cases
        try
            cfg = build_config(
                "construct_$label";
                coverage = params[:coverage],
                latency = params[:latency],
                scale = params[:scale],
                propagator = params[:propagator],
                time_horizon = params[:time_horizon],
                constraint = params[:constraint],
                topology = params[:topology],
                routing = params[:routing],
                traffic = params[:traffic],
            )
            cfg isa ExperimentConfig || push!(failures, "$label => not ExperimentConfig")
        catch err
            push!(failures, "$label => $(typeof(err)): $(sprint(showerror, err))")
        end
    end
    return length(cases), failures
end

function base_case()
    return Dict{Symbol,Any}(
        :coverage => GlobalCoverage(),
        :latency => LowLatencyConst(),
        :scale => SmallScale(),
        :propagator => SpeedFocus(),
        :time_horizon => Snapshot(),
        :constraint => BalancedLink(),
        :topology => BalancedTopo(),
        :routing => ShortestPath(),
        :traffic => UniformLoad(),
    )
end

function smoke_cases(dims)
    cases = Pair{String,Dict{Symbol,Any}}[]
    base = base_case()
    push!(cases, "baseline" => copy(base))

    for v in dims.coverage
        c = copy(base); c[:coverage] = v.value
        push!(cases, "coverage_$(v.name)" => c)
    end
    for v in dims.latency
        c = copy(base); c[:latency] = v.value
        push!(cases, "latency_$(v.name)" => c)
    end
    # Medium/large are construction-validated by default. Running them is opt-in
    # because they can create hundreds or thousands of satellites.
    if get(ENV, "SATSIM_EXPERIMENT_MATRIX_RUN_LARGE", "0") == "1"
        for v in dims.scale
            c = copy(base); c[:scale] = v.value
            push!(cases, "scale_$(v.name)" => c)
        end
    else
        c = copy(base); c[:scale] = SmallScale()
        push!(cases, "scale_small" => c)
    end
    for v in dims.propagator
        c = copy(base); c[:propagator] = v.value
        push!(cases, "propagator_$(v.name)" => c)
    end
    for v in dims.time_horizon
        c = copy(base); c[:time_horizon] = v.value
        push!(cases, "time_$(v.name)" => c)
    end
    for v in dims.constraint
        c = copy(base); c[:constraint] = v.value
        push!(cases, "constraint_$(v.name)" => c)
    end
    for v in dims.topology
        c = copy(base); c[:topology] = v.value
        push!(cases, "topology_$(v.name)" => c)
    end
    for v in dims.routing
        c = copy(base); c[:routing] = v.value
        push!(cases, "routing_$(v.name)" => c)
    end
    for v in dims.traffic
        c = copy(base); c[:traffic] = v.value
        push!(cases, "traffic_$(v.name)" => c)
    end

    # Remove duplicate labels created by baseline-equivalent values.
    seen = Set{String}()
    unique_cases = Pair{String,Dict{Symbol,Any}}[]
    for p in cases
        p.first in seen && continue
        push!(seen, p.first)
        push!(unique_cases, p)
    end
    return unique_cases
end

function run_case(label::String, params::Dict{Symbol,Any})
    cfg = build_config(
        label;
        coverage = params[:coverage],
        latency = params[:latency],
        scale = params[:scale],
        propagator = params[:propagator],
        time_horizon = params[:time_horizon],
        constraint = params[:constraint],
        topology = params[:topology],
        routing = params[:routing],
        traffic = params[:traffic],
    )
    result = run_experiment(cfg)
    return (
        label = label,
        satellites = cfg.constellation.T,
        timesteps = length(cfg.tspan),
        topology = string(typeof(cfg.topology_strategy).name.name),
        routing = string(typeof(cfg.routing_algorithm).name.name),
        traffic_demands = length(cfg.traffic_demands),
        coverage = result.coverage.coverage_ratio,
        avg_latency_ms = result.latency.avg_latency_ms,
        fitness = result.fitness,
    )
end

function run_smoke(dims)
    cases = smoke_cases(dims)
    passed = NamedTuple[]
    failures = String[]
    for (label, params) in cases
        try
            push!(passed, run_case(label, params))
            @printf("[PASS] %-30s T=%d steps=%d topo=%s route=%s demands=%d\n",
                passed[end].label,
                passed[end].satellites,
                passed[end].timesteps,
                passed[end].topology,
                passed[end].routing,
                passed[end].traffic_demands)
        catch err
            msg = "$label => $(typeof(err)): $(sprint(showerror, err))"
            push!(failures, msg)
            println("[FAIL] $msg")
        end
    end
    return passed, failures
end

function run_registered_experiment_smoke()
    try
        cfg = build_config(
            "dead_zone_scan_probe";
            coverage = GlobalCoverage(),
            latency = LowLatencyConst(),
            scale = SmallScale(),
            propagator = SpeedFocus(),
            time_horizon = Snapshot(),
            constraint = BalancedLink(),
            topology = BalancedTopo(),
            routing = ShortestPath(),
            traffic = UniformLoad(),
        )
        result = SatelliteSimLab.run(DeadZoneScan(altitudes = [550.0], spp = 2, inc_deg = 60.0), cfg)
        return true, "registered_experiments=$(registered_experiments()), dead_zone_keys=$(collect(keys(result)))"
    catch err
        return false, "$(typeof(err)): $(sprint(showerror, err))"
    end
end

function main()
    dims = dimensions()
    built_in_count = builtin_intent_count(dims)
    println("SatelliteSimJulia experiment matrix probe")
    println("mode: $RUN_MODE")
    println("finite built-in intent combinations: $built_in_count")
    println("note: arbitrary direct Walker/tspan/constraints/users make the theoretical space unbounded.")
    println()

    total, construct_failures = FULL_CONSTRUCT ? construct_all(dims) : construct_probe(dims)
    construct_label = FULL_CONSTRUCT ? "constructible configs" : "construct probe cases"
    println("$construct_label: $(total - length(construct_failures))/$total")
    !FULL_CONSTRUCT && println("full construction is counted mathematically; set SATSIM_EXPERIMENT_MATRIX_FULL_CONSTRUCT=1 to instantiate every config.")
    if !isempty(construct_failures)
        println("construction failures:")
        foreach(f -> println("  - $f"), construct_failures[1:min(end, 20)])
        length(construct_failures) > 20 && println("  ... $(length(construct_failures) - 20) more")
    end

    if RUN_MODE != "construct_only"
        println()
        println("execution smoke cases:")
        passed, run_failures = run_smoke(dims)
        println("executed smoke cases: $(length(passed))/$(length(passed) + length(run_failures))")
        if !isempty(run_failures)
            println("execution failures:")
            foreach(f -> println("  - $f"), run_failures)
        end

        ok, msg = run_registered_experiment_smoke()
        println()
        println("registered experiment smoke: $(ok ? "PASS" : "FAIL")")
        println("  $msg")

        (!isempty(construct_failures) || !isempty(run_failures) || !ok) && exit(1)
    elseif !isempty(construct_failures)
        exit(1)
    end
end

main()
