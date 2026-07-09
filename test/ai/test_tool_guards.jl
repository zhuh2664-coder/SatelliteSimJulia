using Test
using SatelliteSimLab

@testset "AI tool guards" begin
    SatelliteSimLab.clear_hooks!()
    agent = SatelliteSimLab.SimAgent(SatelliteSimLab.LLMProvider(; key = "dummy");
                                    session_id = "test_tool_guards")

    ok, _ = SatelliteSimLab.guard_tool_call("list_available", Dict("what" => "all"))
    @test ok

    ok, reason = SatelliteSimLab.guard_tool_call("scan_parameter", Dict("values" => collect(1:21)))
    @test !ok
    @test occursin("max_scan_values", reason)

    out = SatelliteSimLab.execute_tool("run_simulation", Dict("constellation" => "walker 24/6/1", "steps" => 101), agent)
    @test occursin("被 pre_tool 钩子阻断", out)
    @test occursin("max_steps", out)

    ok, reason = SatelliteSimLab.guard_tool_call("compare_constellations", Dict("constellations" => string.(1:11)))
    @test !ok
    @test occursin("max_compare_constellations", reason)

    SatelliteSimLab.clear_hooks!()
    SatelliteSimLab.register_hook!(:pre_tool) do ctx
        return :block
    end
    out2 = SatelliteSimLab.execute_tool("list_available", Dict("what" => "all"), agent)
    @test occursin("blocked by hook", out2)

    SatelliteSimLab.clear_hooks!()
end
