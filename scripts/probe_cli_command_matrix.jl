#!/usr/bin/env julia

using JLD2
using JSON
using SatelliteSimLab
using Test

const ROOT = normpath(joinpath(@__DIR__, ".."))
const BIN = joinpath(ROOT, "bin", "satnet.jl")

function run_cli(args::Vector{String}; ok::Bool = true)
    output_path = tempname()
    cmd = addenv(`julia --project=$ROOT $BIN $args`,
        "JULIA_NUM_THREADS" => get(ENV, "SATSIM_CLI_CHILD_THREADS", "1"),
    )

    proc = open(output_path, "w") do io
        Base.run(pipeline(ignorestatus(cmd), stdout = io, stderr = io))
    end
    output = read(output_path, String)
    rm(output_path; force = true)

    if ok
        @test Base.success(proc)
    else
        @test !Base.success(proc)
    end
    return output
end

@testset "CLI command matrix through bin/satnet.jl" begin
    mktempdir() do dir
        positions_path = joinpath(dir, "positions.jld2")
        topology_path = joinpath(dir, "topology.json")
        route_path = joinpath(dir, "route.json")
        czml_path = joinpath(dir, "orbit.czml")

        out = run_cli(["list", "studies"])
        @test occursin("Available studies", out)
        @test occursin("routing", out)

        out = run_cli(["list", "constellations"])
        @test occursin("Available constellations", out)
        @test occursin("walker24", out)

        out = run_cli(["describe", "routing"])
        @test occursin("RoutingStudy", out)

        out = run_cli([
            "topology",
            "--strategy", "gridplus",
            "--T", "6",
            "--P", "3",
            "--output", topology_path,
        ])
        @test occursin("Topology:", out)
        @test isfile(topology_path)
        topology = JSON.parsefile(topology_path)
        @test topology["strategy"] == "gridplus"
        @test topology["T"] == 6

        out = run_cli([
            "propagate",
            "--T", "6",
            "--P", "3",
            "--F", "1",
            "--duration", "60",
            "--steps", "2",
            "--output", positions_path,
        ])
        @test occursin("Propagation complete", out)
        @test isfile(positions_path)
        jldopen(positions_path, "r") do data
            @test size(data["positions"]) == (6, 2, 3)
            @test data["T"] == 6
            @test data["P"] == 3
        end

        out = run_cli([
            "route",
            "--positions", positions_path,
            "--src", "1",
            "--dst", "2",
            "--strategy", "gridplus",
            "--output", route_path,
        ])
        @test occursin("Routing from sat 1 to sat 2", out)
        @test isfile(route_path)
        route = JSON.parsefile(route_path)
        @test route["src"] == 1
        @test route["dst"] == 2
        @test haskey(route, "reachable")

        out = run_cli(["viz", "czml", positions_path, "--output", czml_path])
        @test occursin("Saved CZML", out)
        @test isfile(czml_path)
        packets = JSON.parsefile(czml_path)
        @test packets[1]["id"] == "document"

        out = run_cli(["ai-eval"])
        @test JSON.parse(out)["pass_rate"] == 1.0

        session_id = "probe_cli_command_matrix_$(rand(UInt))"
        mem = SatelliteSimLab.SessionMemory(session_id = session_id)
        session_dir = dirname(mem.transcript_path)
        try
            SatelliteSimLab.record_ledger_event!(mem, Dict{String,Any}(
                "event_type" => "tool_call",
                "tool" => "list_available",
                "args" => Dict("what" => "propagators"),
                "status" => "succeeded",
            ))
            team = SatelliteSimLab.AgentTeam(
                SatelliteSimLab.MockProvider(SatelliteSimLab.AssistantMessage[]);
                session_id = session_id,
            )
            state = SatelliteSimLab.TeamState(
                "req",
                SatelliteSimLab.TeamMessage[],
                Dict{String,Any}(),
                "",
                0,
                :completed,
            )
            SatelliteSimLab.save_team_graph_checkpoint!(team, state)

            out = run_cli(["ai-trace", session_id])
            @test occursin("tool_call", out)

            out = run_cli(["ai-replay", session_id])
            @test JSON.parse(out)["dry_run"] == true

            out = run_cli(["ai-checkpoint", session_id])
            @test JSON.parse(out)["status"] == "completed"
        finally
            isdir(session_dir) && rm(session_dir; recursive = true, force = true)
        end
    end
end

println("CLI COMMAND MATRIX: ALL PASS")
