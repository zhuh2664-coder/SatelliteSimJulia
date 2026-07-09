using Test

using SatelliteSimCore
using SatelliteSimFoundation
using SatelliteSimLab
using SatelliteSimNet
using SatelliteSimTraffic

struct SingleCandidateStrategy <: AbstractTopologyStrategy
    edge::Tuple{Int,Int}
end

function SatelliteSimNet.generate_topology(
    strategy::SingleCandidateStrategy,
    ::Int,
    ::Int,
)::TopologyOutput
    return TopologyOutput(Tuple{Int,Int}[strategy.edge], Tuple{Int,Int}[], "SingleCandidate")
end

function _distance_km(positions::Array{Float64,3}, a::Int, b::Int, time_index::Int)::Float64
    return sqrt(sum((positions[a, time_index, k] - positions[b, time_index, k])^2 for k in 1:3))
end

function _subpoint_ground_station(
    id::Int,
    name::String,
    positions::Array{Float64,3},
    satellite_id::Int,
    time_index::Int,
)::GroundStation
    x = positions[satellite_id, time_index, 1]
    y = positions[satellite_id, time_index, 2]
    z = positions[satellite_id, time_index, 3]
    latitude_deg = atan(z, hypot(x, y)) * 180 / pi
    longitude_deg = atan(y, x) * 180 / pi
    return GroundStation(id, name, GeodeticPosition(latitude_deg, longitude_deg, 0.0))
end

@testset "SatelliteSimLab network traffic candidates" begin
    base_config = ExperimentConfig(
        name = "candidate-probe",
        constellation_params = Dict(
            :T => 6.0,
            :P => 3.0,
            :F => 1.0,
            :alt_km => 550.0,
            :inc_deg => 53.0,
        ),
        tspan = [0.0, 3000.0],
        topology_strategy = SingleCandidateStrategy((1, 4)),
        constraints = PhysicalConstraints(
            isl_max_range_km = 5000.0,
            isl_require_los = false,
            isl_max_capacity_mbps = 1000.0,
            gsl_min_elevation_deg = -90.0,
            gsl_max_range_km = 1.0e9,
            gsl_base_capacity_mbps = 1000.0,
        ),
        traffic = TrafficDemand[],
    )
    _, positions = propagate_constellation_positions(base_config)

    first_distance = _distance_km(positions, 1, 4, 1)
    last_distance = _distance_km(positions, 1, 4, 2)
    @test first_distance < last_distance

    constraints = PhysicalConstraints(
        isl_max_range_km = (first_distance + last_distance) / 2,
        isl_require_los = false,
        isl_max_capacity_mbps = 1000.0,
        gsl_min_elevation_deg = -90.0,
        gsl_max_range_km = 1.0e9,
        gsl_base_capacity_mbps = 1000.0,
    )
    demand = TrafficDemand(
        id = 1,
        source_ground_id = 1,
        destination_ground_id = 2,
        start_elapsed_s = 0,
        end_elapsed_s = 3001,
        rate_mbps = 100.0,
    )
    config = ExperimentConfig(
        name = "traffic-candidates-use-full-topology",
        constellation_params = Dict(
            :T => 6.0,
            :P => 3.0,
            :F => 1.0,
            :alt_km => 550.0,
            :inc_deg => 53.0,
        ),
        tspan = [0.0, 3000.0],
        topology_strategy = SingleCandidateStrategy((1, 4)),
        routing_algorithm = DijkstraRouting(),
        constraints = constraints,
        traffic = TrafficDemand[demand],
        ground_stations = GroundStation[
            _subpoint_ground_station(1, "source", positions, 1, 1),
            _subpoint_ground_station(2, "destination", positions, 4, 1),
        ],
    )

    result = full_constellation_assessment(config)
    @test result.traffic_evaluation !== nothing

    assignments_t1 = SatelliteSimTraffic.traffic_assignments_at(result.traffic_evaluation, 1)
    @test length(assignments_t1) == 1
    @test assignments_t1[1].route.reachable
    @test assignments_t1[1].route.satellite_path == [1, 4]
    @test assignments_t1[1].carried_mbps == 100.0

    assignments_t2 = SatelliteSimTraffic.traffic_assignments_at(result.traffic_evaluation, 2)
    @test length(assignments_t2) == 1
    @test !assignments_t2[1].route.reachable
    @test assignments_t2[1].route.reason == :isl_unreachable
    @test assignments_t2[1].dropped_mbps == 100.0
end
