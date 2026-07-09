using Test
using JSON
using SatelliteSimLab

@testset "AI tool registry" begin
    SatelliteSimLab.ensure_default_ai_tools!()

    tools = SatelliteSimLab.registered_ai_tools()
    @test "run_simulation" in tools
    @test "scan_parameter" in tools
    @test "compare_constellations" in tools
    @test "list_available" in tools
    @test "list_goals" in tools

    spec = SatelliteSimLab.get_ai_tool("list_available")
    @test spec !== nothing
    schema = SatelliteSimLab.llm_tool_schema(spec)
    @test schema["name"] == "list_available"
    @test haskey(schema, "input_schema")

    schemas = SatelliteSimLab.build_tool_schemas()
    @test any(s["name"] == "describe_goal" for s in schemas)

    raw = SatelliteSimLab.execute_tool("list_available", Dict("what" => "all"))
    data = JSON.parse(raw)
    @test data["topologies"] == ["balanced", "robust", "minimal", "adaptive"]
    @test data["propagators"] == ["fast", "balanced", "precise", "tle_based"]

    bad = JSON.parse(SatelliteSimLab.execute_tool("run_simulation", Dict("constellation" => "not_a_constellation")))
    @test haskey(bad, "error")
end
