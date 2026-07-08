using Test
using JSON
using SatelliteSimLab

@testset "AI tool validation and permissions" begin
    @testset "runtime schema validation" begin
        SatelliteSimLab.clear_hooks!()
        session_id = "test_tool_validation_$(rand(UInt))"
        mem = SatelliteSimLab.SessionMemory(session_id = session_id)
        session_dir = dirname(mem.transcript_path)

        try
            agent = SatelliteSimLab.SimAgent(SatelliteSimLab.LLMProvider(; key = "dummy"); session_id = session_id)

            missing = SatelliteSimLab.validate_tool_args("run_simulation", Dict{String,Any}())
            @test !missing.ok
            @test any(occursin("constellation", e) for e in missing.errors)

            bad_enum = SatelliteSimLab.validate_tool_args(
                "list_available",
                Dict{String,Any}("what" => "everything"),
            )
            @test !bad_enum.ok
            @test any(occursin("one of", e) for e in bad_enum.errors)

            bad_type = SatelliteSimLab.validate_tool_args(
                "scan_parameter",
                Dict{String,Any}("param" => "alt_km", "values" => "550"),
            )
            @test !bad_type.ok
            @test any(occursin("expected type array", e) for e in bad_type.errors)

            out = SatelliteSimLab.execute_tool("list_available", Dict{String,Any}("what" => "everything"), agent)
            @test occursin("schema validation failed", out)
            @test occursin("被 pre_tool 钩子阻断", out)

            lines = readlines(SatelliteSimLab.ledger_path(agent.memory))
            @test any(occursin("\"status\":\"blocked\"", line) && occursin("schema validation failed", line) for line in lines)

            old_path = JSON.parse(SatelliteSimLab.execute_tool("list_available", Dict{String,Any}("what" => "everything")))
            @test occursin("schema validation failed", old_path["error"])
        finally
            isdir(session_dir) && rm(session_dir; recursive = true, force = true)
            SatelliteSimLab.clear_hooks!()
        end
    end

    @testset "deny and HITL approval" begin
        SatelliteSimLab.clear_hooks!()
        session_id = "test_tool_permissions_$(rand(UInt))"
        mem = SatelliteSimLab.SessionMemory(session_id = session_id)
        session_dir = dirname(mem.transcript_path)

        try
            deny_policy = SatelliteSimLab.ToolPermissionPolicy(
                rules = Dict("list_available" => :deny),
            )
            denied_agent = SatelliteSimLab.SimAgent(
                SatelliteSimLab.LLMProvider(; key = "dummy");
                session_id = session_id * "_deny",
                permission_policy = deny_policy,
            )
            denied = SatelliteSimLab.execute_tool("list_available", Dict{String,Any}("what" => "all"), denied_agent)
            @test occursin("permission denied", denied)

            ask_policy = SatelliteSimLab.ToolPermissionPolicy(
                rules = Dict("list_available" => :ask),
            )
            ask_agent = SatelliteSimLab.SimAgent(
                SatelliteSimLab.LLMProvider(; key = "dummy");
                session_id = session_id * "_ask",
                permission_policy = ask_policy,
            )
            args = Dict{String,Any}("what" => "propagators")
            first = SatelliteSimLab.execute_tool("list_available", args, ask_agent)
            @test occursin("human approval required", first)

            @test SatelliteSimLab.approve_tool_call!(ask_agent, "list_available", args)
            second = JSON.parse(SatelliteSimLab.execute_tool("list_available", args, ask_agent))
            @test second["propagators"] == ["fast", "balanced", "precise", "tle_based"]

            lines = readlines(SatelliteSimLab.ledger_path(ask_agent.memory))
            @test any(occursin("tool_permission", line) && occursin("\"decision\":\"ask\"", line) for line in lines)
            @test any(occursin("tool_permission", line) && occursin("\"decision\":\"approved\"", line) for line in lines)
        finally
            isdir(session_dir) && rm(session_dir; recursive = true, force = true)
            isdir(session_dir * "_deny") && rm(session_dir * "_deny"; recursive = true, force = true)
            isdir(session_dir * "_ask") && rm(session_dir * "_ask"; recursive = true, force = true)
            SatelliteSimLab.clear_hooks!()
        end
    end
end
