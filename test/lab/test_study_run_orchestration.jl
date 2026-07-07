using Test
using JSON
using SatelliteSimCore
using SatelliteSimLab

function _study_run_ground_stations()
    return GroundStation[
        GroundStation(id = 1, name = "source", position = GeodeticPosition(0.0, 0.0, 0.0)),
        GroundStation(id = 2, name = "destination", position = GeodeticPosition(10.0, 20.0, 0.0)),
    ]
end

@testset "StudyPlan builds executable studies" begin
    for goal in SatelliteSimLab.list_goals()
        plan = SatelliteSimLab.create_plan(Dict{Symbol,Any}(:goal => goal))
        study = SatelliteSimLab.build_study(plan)
        @test study isa SatelliteSimLab.Study
    end
end

@testset "run_study accepts execution context" begin
    stations = _study_run_ground_stations()
    study = SatelliteSimLab.RoutingStudy(
        algorithms = [:shortest_path],
        constellation = :walker24,
        traffic = :uniform,
    )
    result = SatelliteSimLab.run_study(
        study;
        ground_stations = stations,
        ground_pairs = [(1, 2)],
        tspan = [0.0, 60.0],
    )

    @test result isa SatelliteSimLab.ExperimentResult
    @test length(result.config.ground_stations) == 2
    @test length(result.config.ground_pairs) == 1
    @test length(result.config.traffic_demands) == 1
end

@testset "expand_study produces deterministic routing cases" begin
    study = SatelliteSimLab.RoutingStudy(
        algorithms = [:shortest_path, :load_balanced],
        constellation = :walker24,
        traffic = :uniform,
    )
    cases = SatelliteSimLab.expand_study(study; tspan = [0.0, 60.0], max_cases = 2)

    @test length(cases) == 2
    @test [case.id for case in cases] == ["routing_shortest_path", "routing_load_balanced"]
    @test [case.axis for case in cases] == [:routing, :routing]
    @test cases[1].value == :shortest_path
    @test cases[2].value == :load_balanced
    @test typeof(cases[1].config.routing_algorithm) != typeof(cases[2].config.routing_algorithm)
end

@testset "run_study_plan returns auditable manifest" begin
    stations = _study_run_ground_stations()
    plan = SatelliteSimLab.create_plan(Dict{Symbol,Any}(
        :goal => :routing_comparison,
        :algorithms => [:shortest_path, :load_balanced],
        :constellation => :walker24,
        :traffic_intent => :uniform,
    ))
    run = SatelliteSimLab.run_study_plan(
        plan;
        ground_stations = stations,
        ground_pairs = [(1, 2)],
        tspan = [0.0, 60.0],
        max_cases = 2,
    )
    manifest = SatelliteSimLab.study_run_manifest(run)

    @test run isa SatelliteSimLab.StudyRunResult
    @test manifest["schema_version"] == "study_run/v1"
    @test manifest["study"] == "routing"
    @test manifest["case_count"] == 2
    @test length(manifest["cases"]) == 2
    @test all(haskey(case, "config") for case in manifest["cases"])
    @test all(haskey(case, "metrics") for case in manifest["cases"])
    @test haskey(manifest["artifacts"], "summary_csv")
    @test haskey(manifest["artifacts"], "summary_markdown")
    @test occursin("name,T,P", manifest["artifacts"]["summary_csv"])
    @test occursin("| Config |", manifest["artifacts"]["summary_markdown"])
end

@testset "AI run_study_plan tool returns manifest" begin
    SatelliteSimLab.ensure_default_ai_tools!()
    raw = SatelliteSimLab.execute_tool(
        "run_study_plan",
        Dict{String,Any}(
            "goal" => "routing_comparison",
            "answers" => Dict{String,Any}(
                "algorithms" => ["shortest_path", "load_balanced"],
                "constellation" => "walker24",
                "traffic_intent" => "uniform",
            ),
            "duration_s" => 60,
            "steps" => 2,
            "max_cases" => 2,
            "ground_stations" => Any[
                Dict("id" => 1, "name" => "source", "lat" => 0.0, "lon" => 0.0, "alt_km" => 0.0),
                Dict("id" => 2, "name" => "destination", "lat" => 10.0, "lon" => 20.0, "alt_km" => 0.0),
            ],
            "ground_pairs" => Any[Any[1, 2]],
        ),
    )
    data = JSON.parse(raw; allownan = true)

    @test !haskey(data, "error")
    @test data["summary_scope"] == "representative_first_successful_case"
    @test data["case_count"] == 2
    @test haskey(data, "manifest")
    @test data["manifest"]["schema_version"] == "study_run/v1"
    @test haskey(data, "coverage_ratio")
    @test haskey(data, "artifacts")
    @test occursin("name,T,P", data["artifacts"]["summary_csv"])
end
