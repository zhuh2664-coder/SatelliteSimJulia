#!/usr/bin/env julia

# Lightweight Julia dispatch/type-inference probe.
#
# This is a report script, not a hard failing test suite. Some dynamic dispatch is
# acceptable in orchestration/configuration code; the goal is to make it visible.

using InteractiveUtils
using Test

using SatelliteSimOrbit
using SatelliteSimNet
using SatelliteSimTraffic
using SatelliteSimOpt

const CHECKS = NamedTuple[]

mutable struct ProbeSummary
    pass::Int
    warn::Int
    fail::Int
end

ProbeSummary() = ProbeSummary(0, 0, 0)

function type_label(x)
    return sprint(show, MIME"text/plain"(), x)
end

function concrete_return_type(thunk)
    types = Base.return_types(thunk, Tuple{})
    if length(types) == 1 && Base.isconcretetype(only(types))
        return true, only(types), types
    end
    return false, Union{types...}, types
end

function probe(summary::ProbeSummary, name::String, thunk; expect_inferred::Bool=true, note::String="")
    stable, inferred_type, all_types = concrete_return_type(thunk)
    status = stable ? "PASS" : (expect_inferred ? "WARN" : "INFO")
    try
        value = @inferred thunk()
        value_type = typeof(value)
        if !stable && expect_inferred
            summary.warn += 1
        elseif stable
            summary.pass += 1
        else
            summary.pass += 1
        end
        println("[$status] $name")
        println("       inferred: $(type_label(inferred_type))")
        println("       value:    $(type_label(value_type))")
        !isempty(note) && println("       note:     $note")
        if length(all_types) > 1
            println("       returns:  $(join(type_label.(all_types), ", "))")
        end
    catch err
        if err isa ErrorException && occursin("return type", sprint(showerror, err))
            summary.warn += 1
            println("[WARN] $name")
            println("       inferred: $(type_label(inferred_type))")
            println("       error:    $(sprint(showerror, err))")
            !isempty(note) && println("       note:     $note")
        else
            summary.fail += 1
            println("[FAIL] $name")
            println("       error:    $(typeof(err)): $(sprint(showerror, err))")
            !isempty(note) && println("       note:     $note")
        end
    end
end

function probe_method(summary::ProbeSummary, name::String, f, argtypes::Type; expect_concrete::Bool=true, note::String="")
    types = Base.return_types(f, argtypes)
    stable = length(types) == 1 && Base.isconcretetype(only(types))
    status = stable ? "PASS" : (expect_concrete ? "WARN" : "INFO")
    if stable || !expect_concrete
        summary.pass += 1
    else
        summary.warn += 1
    end
    println("[$status] $name")
    println("       method return_types: $(isempty(types) ? "<none>" : join(type_label.(types), ", "))")
    !isempty(note) && println("       note:     $note")
end

function probe_field(summary::ProbeSummary, name::String, parent::Type, field::Symbol; expect_concrete::Bool=true, note::String="")
    ftype = fieldtype(parent, field)
    concrete = Base.isconcretetype(ftype)
    dynamic_function = ftype === Function
    status = concrete && !dynamic_function ? "PASS" : (expect_concrete ? "WARN" : "INFO")
    if status == "WARN"
        summary.warn += 1
    else
        summary.pass += 1
    end
    println("[$status] $name")
    println("       field type: $(type_label(ftype))")
    !isempty(note) && println("       note:     $note")
end

function run_orbit_probes(summary::ProbeSummary)
    println("\n== Orbit dispatch ==")
    probe(summary, "resolve_keplerian_propagator(Val(:two_body))", () -> begin
        SatelliteSimOrbit.resolve_keplerian_propagator(Val(:two_body))
    end)
    probe(summary, "resolve_keplerian_propagator(Val(:j2))", () -> begin
        SatelliteSimOrbit.resolve_keplerian_propagator(Val(:j2))
    end)
    probe(summary, "resolve_keplerian_propagator(:j4) constant call", () -> begin
        SatelliteSimOrbit.resolve_keplerian_propagator(:j4)
    end)
    probe_method(
        summary,
        "resolve_keplerian_propagator(::Symbol) by type only",
        SatelliteSimOrbit.resolve_keplerian_propagator,
        Tuple{Symbol};
        expect_concrete=false,
        note="Symbol is flexible at API boundaries; prefer Val or concrete propagator objects inside hot loops.",
    )
    probe(summary, "generate_walker_delta small design constellation", () -> begin
        SatelliteSimOrbit.generate_walker_delta(T=6, P=3, F=1, alt_km=550.0, inc_deg=53.0)
    end)
end

function run_net_probes(summary::ProbeSummary)
    println("\n== Net topology/routing ==")
    probe(summary, "generate_topology(GridPlusStrategy(), 24, 6)", () -> begin
        SatelliteSimNet.generate_topology(SatelliteSimNet.GridPlusStrategy(), 24, 6)
    end)
    probe(summary, "isl_neighbors(GridPlusStrategy(), 1, 24, 6)", () -> begin
        SatelliteSimNet.isl_neighbors(SatelliteSimNet.GridPlusStrategy(), 1, 24, 6)
    end)
    probe(summary, "num_isl(GridPlusStrategy(), 24, 6)", () -> begin
        SatelliteSimNet.num_isl(SatelliteSimNet.GridPlusStrategy(), 24, 6)
    end)
    probe(summary, "generate_topology(RingStrategy(), 24, 6)", () -> begin
        SatelliteSimNet.generate_topology(SatelliteSimNet.RingStrategy(), 24, 6)
    end)
    probe(summary, "build_adjacency small graph", () -> begin
        SatelliteSimNet.build_adjacency(3, [(1, 2), (2, 3)], [1.0, 2.0])
    end)
    probe(summary, "shortest_path_from_adjacency small graph", () -> begin
        A = SatelliteSimNet.build_adjacency(3, [(1, 2), (2, 3)], [1.0, 2.0])
        SatelliteSimNet.shortest_path_from_adjacency(A, 1, 3)
    end)
end

function run_traffic_probes(summary::ProbeSummary)
    println("\n== Traffic profiles ==")
    probe(summary, "rate_at(ConstantRate, Int)", () -> begin
        SatelliteSimTraffic.rate_at(SatelliteSimTraffic.ConstantRate(100.0), 60)
    end)
    probe(summary, "rate_at(SampledRate, Int)", () -> begin
        p = SatelliteSimTraffic.SampledRate([0, 60, 120], [10.0, 20.0, 10.0])
        SatelliteSimTraffic.rate_at(p, 30)
    end)
    probe(summary, "rate_at(FunctionalRate, Int)", () -> begin
        p = SatelliteSimTraffic.FunctionalRate(t -> 10.0 + 0.1 * t)
        SatelliteSimTraffic.rate_at(p, 30)
    end; expect_inferred=false,
        note="FunctionalRate stores func::Function, so this is intentionally dynamic unless parameterized later.")
    probe(summary, "rate_at(TimeVaryingDemand{ConstantRate field is abstract})", () -> begin
        d = SatelliteSimTraffic.TimeVaryingDemand(1, 1, 2, 0, 120, SatelliteSimTraffic.ConstantRate(50.0))
        SatelliteSimTraffic.rate_at(d, 60)
    end; expect_inferred=false,
        note="TimeVaryingDemand stores rate_profile::AbstractRateProfile; acceptable for orchestration, not ideal for hot loops.")
    probe_method(
        summary,
        "rate_at(::FunctionalRate, ::Int) method return",
        SatelliteSimTraffic.rate_at,
        Tuple{SatelliteSimTraffic.FunctionalRate, Int},
    )
    probe_method(
        summary,
        "rate_at(::TimeVaryingDemand, ::Int) method return",
        SatelliteSimTraffic.rate_at,
        Tuple{SatelliteSimTraffic.TimeVaryingDemand, Int},
    )
    probe_field(
        summary,
        "FunctionalRate.func field",
        SatelliteSimTraffic.FunctionalRate,
        :func;
        expect_concrete=false,
        note="Flexible user function hook. If this becomes a tight-loop bottleneck, parameterize as FunctionalRate{F}.",
    )
    probe_field(
        summary,
        "TimeVaryingDemand.rate_profile field",
        SatelliteSimTraffic.TimeVaryingDemand,
        :rate_profile;
        expect_concrete=false,
        note="Abstract interface field keeps construction simple. A parametric TimeVaryingDemand{P} would remove dynamic dispatch.",
    )
    probe(summary, "solar_power_w(UniformSolar, Int)", () -> begin
        SatelliteSimTraffic.solar_power_w(SatelliteSimTraffic.UniformSolar(800.0), 60)
    end)
    probe(summary, "solar_power_w(EclipseSolar, Int)", () -> begin
        SatelliteSimTraffic.solar_power_w(SatelliteSimTraffic.EclipseSolar(), 60)
    end)
    probe_method(
        summary,
        "_evolve_one_step(..., ::AbstractSolarProfile, ...)",
        SatelliteSimTraffic._evolve_one_step,
        Tuple{
            SatelliteSimTraffic.PowerState,
            Float64,
            SatelliteSimTraffic.AbstractSolarProfile,
            Float64,
            Float64,
            Float64,
            Float64,
        };
        expect_concrete=false,
        note="The return type is concrete; dispatch through AbstractSolarProfile is a strategy hook.",
    )
end

function run_opt_probes(summary::ProbeSummary)
    println("\n== Opt differentiable kernels ==")
    probe(summary, "soft_coverage(Float64, Float64)", () -> begin
        SatelliteSimOpt.soft_coverage(15.0, 10.0)
    end)
    probe(summary, "noisy_or_coverage(Vector{Float64})", () -> begin
        SatelliteSimOpt.noisy_or_coverage([0.1, 0.2, 0.3])
    end)
    probe(summary, "leaky_revisit(Float64, Float64, Float64)", () -> begin
        SatelliteSimOpt.leaky_revisit(10.0, 1.0, 0.25)
    end)
    probe(summary, "logsumexp_max(Vector{Float64})", () -> begin
        SatelliteSimOpt.logsumexp_max([1.0, 2.0, 3.0])
    end)
    probe(summary, "soft_route_loss(Vector{Float64})", () -> begin
        SatelliteSimOpt.soft_route_loss([0.0, 0.0, 0.0, 1000.0, 0.0, 0.0, 2000.0, 0.0, 0.0])
    end)
    probe(summary, "coverage_loss tiny Float64 arrays", () -> begin
        positions = zeros(Float64, 2, 2, 3)
        positions[1, :, 1] .= 7000.0
        positions[2, :, 2] .= 7000.0
        ground_pts = [6371.0 0.0 0.0; 0.0 6371.0 0.0]
        weights = [1.0, 1.0]
        SatelliteSimOpt.coverage_loss(positions, ground_pts, weights)
    end)
end

function main()
    println("SatelliteSimJulia Julia dispatch/type-inference probe")
    println("Julia threads: $(Threads.nthreads())")
    println("This script reports inference health; WARN does not automatically mean a bug.\n")

    summary = ProbeSummary()
    run_orbit_probes(summary)
    run_net_probes(summary)
    run_traffic_probes(summary)
    run_opt_probes(summary)

    println("\n== Summary ==")
    println("PASS/INFO: $(summary.pass)")
    println("WARN:      $(summary.warn)")
    println("FAIL:      $(summary.fail)")

    if summary.fail > 0
        exit(1)
    end
end

main()
