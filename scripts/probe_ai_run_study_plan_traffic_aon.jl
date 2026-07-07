#!/usr/bin/env julia

using JSON
using Test
using SatelliteSimLab

@testset "AI run_study_plan traffic AON bridge" begin
    SatelliteSimLab.ensure_default_ai_tools!()
    schema = SatelliteSimLab.get_ai_tool("run_study_plan").input_schema
    properties = schema["properties"]
    @test haskey(properties, "ground_stations")
    @test haskey(properties, "ground_pairs")

    raw = SatelliteSimLab.execute_tool(
        "run_study_plan",
        Dict{String,Any}(
            "goal" => "coverage_analysis",
            "answers" => Dict{String,Any}(
                "traffic_intent" => "uniform",
            ),
            "ground_stations" => [
                Dict{String,Any}("id" => 1, "name" => "beijing", "lat" => 39.9042, "lon" => 116.4074, "alt_km" => 0.0),
                Dict{String,Any}("id" => 2, "name" => "singapore", "lat" => 1.3521, "lon" => 103.8198, "alt_km" => 0.0),
            ],
            "ground_pairs" => [[1, 2]],
        ),
    )
    data = JSON.parse(raw; allownan = true)

    @test data["plan"]["goal"] == "coverage_analysis"
    @test data["traffic_demands"] == 1
    @test data["ground_stations"] == 2
    @test data["ground_pairs"] == 1
    @test data["traffic_evaluation_ran"] == true
    @test data["traffic_fallback"] == false
    @test data["traffic_time_steps"] > 0
    @test data["traffic_assignments"] > 0

    no_ground_raw = SatelliteSimLab.execute_tool(
        "run_study_plan",
        Dict{String,Any}(
            "goal" => "coverage_analysis",
            "answers" => Dict{String,Any}("traffic_intent" => "uniform"),
        ),
    )
    no_ground = JSON.parse(no_ground_raw; allownan = true)
    @test no_ground["traffic_demands"] == 0
    @test no_ground["ground_stations"] == 0
    @test no_ground["ground_pairs"] == 0
    @test no_ground["traffic_evaluation_ran"] == false
end

println("AI RUN STUDY PLAN TRAFFIC AON: ALL PASS")
