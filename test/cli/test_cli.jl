# ===== CLI 单元测试 =====

using SatelliteSimJulia
using SatelliteSimLab
using JLD2
using JSON
using Test

CLI = SatelliteSimJulia.SimCLI
const RUN_VIZ_RENDER = get(ENV, "SATSIM_RUN_VIZ", "0") == "1"

function capture_stdout(f)
    old = stdout
    rd, wr = redirect_stdout()
    try
        f()
    finally
        redirect_stdout(old)
        close(wr)
    end
    return String(read(rd))
end

@testset "List commands" begin
    out = capture_stdout() do
        CLI.command_main(["list", "studies"])
    end
    @test occursin("routing", out)
    @test occursin("coverage", out)

    out2 = capture_stdout() do
        CLI.command_main(["list", "constellations"])
    end
    @test occursin("iridium", out2)
    @test occursin("walker24", out2)
end

@testset "Describe command" begin
    out = capture_stdout() do
        CLI.command_main(["describe", "routing"])
    end
    @test occursin("RoutingStudy", out)
end

@testset "Propagate command creates JLD2" begin
    tmp = tempname() * ".jld2"
    try
        CLI.command_main([
            "propagate",
            "--T", "12",
            "--P", "3",
            "--alt", "550",
            "--inc", "53",
            "--duration", "120",
            "--steps", "3",
            "--output", tmp,
        ])
        @test isfile(tmp)
        data = jldopen(tmp, "r")
        @test size(data["positions"]) == (12, 3, 3)
        @test data["T"] == 12
        close(data)
    finally
        isfile(tmp) && rm(tmp; force = true)
    end
end

@testset "Topology command" begin
    out = capture_stdout() do
        CLI.command_main(["topology", "--strategy", "gridplus", "--T", "24", "--P", "6"])
    end
    @test occursin("Grid+", out)
    @test occursin("static links", out)
end

@testset "Viz snapshot command" begin
    if RUN_VIZ_RENDER
        tmp_pos = tempname() * ".jld2"
        tmp_png = tempname() * ".png"
        try
            # 构造最小位置文件
            jldsave(tmp_pos; positions = zeros(Float64, 2, 2, 3), T = 2, P = 1)
            CLI.command_main(["viz", "snapshot", tmp_pos, "--output", tmp_png])
            @test isfile(tmp_png)
            @test filesize(tmp_png) > 100
        finally
            isfile(tmp_pos) && rm(tmp_pos; force = true)
            isfile(tmp_png) && rm(tmp_png; force = true)
        end
    else
        @info "CLI Viz snapshot rendering skipped; set SATSIM_RUN_VIZ=1 to enable"
        @test hasmethod(CLI.viz, Tuple{String,String})
    end
end

@testset "Viz CZML command" begin
    tmp_pos = tempname() * ".jld2"
    tmp_czml = tempname() * ".czml"
    try
        pos = zeros(Float64, 2, 2, 3)
        pos[1, 1, :] .= 7000.0, 0.0, 0.0
        pos[2, 1, :] .= 0.0, 7000.0, 0.0
        jldsave(tmp_pos; positions = pos, T = 2, P = 1, tspan = [0.0, 60.0])
        CLI.command_main(["viz", "czml", tmp_pos, "--output", tmp_czml])
        @test isfile(tmp_czml)
        packets = JSON.parsefile(tmp_czml)
        @test packets[1]["id"] == "document"
        @test packets[2]["position"]["referenceFrame"] == "FIXED"
    finally
        isfile(tmp_pos) && rm(tmp_pos; force = true)
        isfile(tmp_czml) && rm(tmp_czml; force = true)
    end
end

@testset "AI orchestration CLI commands" begin
    session_id = "test_cli_ai_$(rand(UInt))"
    mem = SatelliteSimLab.SessionMemory(session_id = session_id)
    session_dir = dirname(mem.transcript_path)
    try
        SatelliteSimLab.record_ledger_event!(mem, Dict{String,Any}(
            "event_type" => "tool_call",
            "tool" => "list_available",
            "args" => Dict("what" => "propagators"),
            "status" => "succeeded",
        ))
        state = SatelliteSimLab.TeamState("req", SatelliteSimLab.TeamMessage[], Dict{String,Any}(), "", 0, :completed)
        team = SatelliteSimLab.AgentTeam(SatelliteSimLab.MockProvider(SatelliteSimLab.AssistantMessage[]); session_id = session_id)
        SatelliteSimLab.save_team_graph_checkpoint!(team, state)

        out_eval = capture_stdout() do
            CLI.command_main(["ai-eval"])
        end
        @test JSON.parse(out_eval)["pass_rate"] == 1.0

        out_trace = capture_stdout() do
            CLI.command_main(["ai-trace", session_id])
        end
        @test occursin("tool_call", out_trace)

        out_replay_plan = capture_stdout() do
            CLI.command_main(["ai-trace", session_id, "--mode", "replay_plan"])
        end
        replay_plan = JSON.parse(out_replay_plan)
        @test replay_plan[1]["tool"] == "list_available"

        out_replay = capture_stdout() do
            CLI.command_main(["ai-replay", session_id])
        end
        @test JSON.parse(out_replay)["dry_run"] == true

        out_checkpoint = capture_stdout() do
            CLI.command_main(["ai-checkpoint", session_id])
        end
        @test JSON.parse(out_checkpoint)["status"] == "completed"

        withenv("DEEPSEEK_API_KEY" => nothing) do
            for command in (["chat", "ping"], ["teamgraph", "ping"])
                err = nothing
                try
                    CLI.command_main(command)
                catch e
                    err = e
                end
                @test err !== nothing
                @test occursin("DEEPSEEK_API_KEY not set", sprint(showerror, err))
            end
        end
    finally
        isdir(session_dir) && rm(session_dir; recursive = true, force = true)
        SatelliteSimLab.clear_hooks!()
    end
end
