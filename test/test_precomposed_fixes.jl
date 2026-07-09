# ===== 预编排修复回归（C4/C1/C2/C6 相关）=====

using Test
using SatelliteSimLab
using SatelliteSimNet: build_routing_graph
using SatelliteSimCore: WalkerConstellationConfig, TwoBodyPropagator, J2Propagator,
    GroundStation, GeodeticPosition, LEO_DEFAULTS

@testset "precomposed fixes" begin

    @testset "默认 run_experiment 覆盖率不为 NaN" begin
        config = ExperimentConfig(;
            constellation = WalkerConstellationConfig(T=12, P=3, F=1, alt_km=550.0, inc_deg=53.0),
            tspan = [0.0, 60.0],
        )
        result = run_experiment(config)
        @test !isnan(result.coverage.coverage_ratio)
        @test result.coverage.total_users == 0
        @test result.coverage.coverage_ratio ≈ 0.0
    end

    @testset "地面端点解析为 ground ID 而非卫星索引" begin
        config = ExperimentConfig(;
            constellation = WalkerConstellationConfig(T=12, P=3, F=1, alt_km=550.0, inc_deg=53.0),
            ground_stations = [
                GroundStation(1, "A", GeodeticPosition(39.9, 116.4, 0.0)),
                GroundStation(2, "B", GeodeticPosition(31.2, 121.5, 0.0)),
            ],
        )
        pairs, use_ground = SatelliteSimLab._resolve_routing_endpoint_pairs(config, 12)
        @test use_ground
        @test pairs == [(1, 2)]
    end

    @testset "有接入映射时走卫星最短路径" begin
        demands = [TrafficDemand(
            id=1, source_ground_id=1, destination_ground_id=2,
            start_elapsed_s=0, end_elapsed_s=1, rate_mbps=100.0,
        )]
        D = fill(Inf, 4, 4)
        for i in 1:4; D[i, i] = 0.0; end
        D[1, 2] = D[2, 1] = 1.0
        D[3, 4] = D[4, 3] = 1.0
        D[1, 3] = D[3, 1] = 1.0
        D[2, 4] = D[4, 2] = 1.0
        D[1, 4] = D[4, 1] = 2.0
        available = [(1, 2), (3, 4), (1, 3), (2, 4)]
        access_map = Dict(
            1 => (sat_id=1, delay_ms=0.1),
            2 => (sat_id=4, delay_ms=0.2),
        )
        graph = build_routing_graph(4, available, [1.0, 1.0, 1.0, 1.0])
        loads = SatelliteSimLab._assign_demands_to_isls(
            demands, available, D, 4;
            access_map=access_map, routing_graph=graph,
        )
        @test sum(loads) > 0
    end

    @testset "流量降级不 clamp ground_id 到卫星索引" begin
        # 构造会触发 AON 降级（无 ground_stations 时 full bridge 返回 nothing）
        demands = [TrafficDemand(
            id=1, source_ground_id=99, destination_ground_id=100,
            start_elapsed_s=0, end_elapsed_s=1, rate_mbps=10.0,
        )]
        positions = rand(12, 2, 3) .* 1000 .+ 6000
        D = fill(Inf, 12, 12)
        for i in 1:12; D[i, i] = 0.0; end
        D[1, 2] = D[2, 1] = 1.0
        available = [(1, 2)]
        # 无 access_map：ground_id 99/100 超出范围，应跳过而非 clamp
        loads = SatelliteSimLab._assign_demands_to_isls(demands, available, D, 12)
        @test loads ≈ zeros(1)
    end
end
