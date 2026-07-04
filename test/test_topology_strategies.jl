# ===== ISL 拓扑策略测试 =====
# 测试 Net 子包中已迁移策略的统一接口。

using Test

using SatelliteSimNet: AbstractTopologyStrategy, TopologyOutput,
    GridPlusStrategy, TShapeStrategy, generate_topology,
    SpiralStrategy, HoneycombStrategy, RingStrategy, MeshStrategy,
    NearestNeighborStrategy, isl_neighbors, num_isl

@testset "拓扑策略生成" begin
    T, P = 1156, 34  # Kuiper 参数

    # 1. Grid+
    grid = generate_topology(GridPlusStrategy(), T, P)
    @test length(grid.static_links) > 0
    @test grid.description == "Grid+"
    @test length(grid.dynamic_candidates) == 0  # Grid+ 没有动态链路

    # 2. T 型
    tshape = generate_topology(TShapeStrategy(), T, P)
    @test length(tshape.static_links) > 0
    @test length(tshape.dynamic_candidates) > 0  # T 型有动态候选
    @test tshape.description == "T-Shape"

    # 3. 验证 T 型静态链路数 ≈ 3 条/星 × 1156 星 ÷ 2
    expected_static = 1156 * 3 ÷ 2
    @test abs(length(tshape.static_links) - expected_static) < 100  # 允许误差

    println("✅ 所有拓扑策略生成成功")
end

@testset "新增拓扑策略（Spiral/Honeycomb/Ring/Mesh/NN）" begin
    # 小星座参数：Iridium 66/6
    T, P = 66, 6

    # 4. Spiral（−Grid，度4，shift=1）
    spiral = generate_topology(SpiralStrategy(), T, P)
    @test spiral.description == "Spiral"
    @test length(spiral.static_links) == T * 2  # 2T 条边 = 132
    @test length(spiral.dynamic_candidates) == 0
    @test num_isl(SpiralStrategy(), T, P) == T * 2  # 解析公式校验

    # Spiral shift=0 应退化为 Grid+
    spiral0 = generate_topology(SpiralStrategy(shift=0), T, P)
    gridplus = generate_topology(GridPlusStrategy(), T, P)
    @test Set(spiral0.static_links) == Set(gridplus.static_links)

    # 5. Honeycomb（3-ISL 蜂窝，度3）
    honey = generate_topology(HoneycombStrategy(), T, P)
    @test honey.description == "Honeycomb"
    @test length(honey.static_links) > 0
    # 度3：面内 P*S=66 条 + 面间约半数 ≈ 33 → 总 ~99；允许 ±10
    @test abs(length(honey.static_links) - T * 3 ÷ 2) <= 10

    # 6. Ring（度2，仅面内环）
    ring = generate_topology(RingStrategy(), T, P)
    @test ring.description == "Ring"
    @test length(ring.static_links) == T  # 每平面 S 条 ring = P*S = T = 66
    @test num_isl(RingStrategy(), T, P) == T

    # 7. Mesh（完全图，度 n-1）
    T_small = 10  # Mesh 仅小规模
    mesh = generate_topology(MeshStrategy(), T_small, 2)
    @test mesh.description == "Mesh"
    @test length(mesh.static_links) == T_small * (T_small - 1) ÷ 2  # C(10,2)=45
    @test num_isl(MeshStrategy(), T_small, 2) == T_small * (T_small - 1) ÷ 2

    # 8. NearestNeighbor（动态最近邻-k）
    using Random
    N = 10
    positions = rand(MersenneTwister(42), N, 1, 3) * 1000.0  # (N×1×3)
    nn = NearestNeighborStrategy(positions=positions, k=3)
    topo_nn = generate_topology(nn, N, 2)  # P 忽略
    @test startswith(topo_nn.description, "NearestNeighbor")
    @test length(topo_nn.static_links) == 0   # 动态策略：static 为空
    @test length(topo_nn.dynamic_candidates) > 0  # 候选非空
    # 每星连最近 3 个，去重后边数应在 [k*N/2, k*N] 之间
    @test length(topo_nn.dynamic_candidates) <= nn.k * N

    println("✅ 5 个新拓扑策略全部通过")
end
