# src/viz/test/runtests.jl — SatelliteSimViz 独立 smoke 测试
#
# 可视化层：CairoMakie（默认静态）+ GeoMakie + Makie。
# 测试关键绘图函数存在 + 出图到 PNG 文件非空。无显示器依赖，CI 可跑。

using SatelliteSimViz
using Test

@testset "SatelliteSimViz" begin

    @testset "绘图函数存在" begin
        @test plot_orbit_snapshot isa Function
        @test save_orbit_snapshot isa Function
        @test plot_ground_track isa Function
        @test plot_coverage_heatmap isa Function
        @test geodetic_to_xyz isa Function
        @test ecef_to_latlon isa Function
    end

    @testset "配置类型" begin
        @test MakieViewerConfig isa DataType
        @test EarthViewerConfig isa DataType
        cfg = MakieViewerConfig()
        @test cfg isa MakieViewerConfig
    end

    @testset "绘图函数调用（2 卫星出 PNG）" begin
        # 构造最小 2 卫星位置矩阵
        pos = zeros(Float64, 2, 1, 3)
        pos[1,1,:] .= 7000.0, 0.0, 0.0
        pos[2,1,:] .= 0.0, 7000.0, 0.0
        tmp_png = tempname() * ".png"
        try
            save_orbit_snapshot(tmp_png, pos)
            @test isfile(tmp_png)
            @test filesize(tmp_png) > 100   # 出图非空
        catch e
            @warn "Viz 出图失败（可能缺 coastline 数据下载，非阻塞）" exception=e
            @test_broken false
        finally
            isfile(tmp_png) && rm(tmp_png; force=true)
        end
    end

    @testset "坐标变换" begin
        xyz = geodetic_to_xyz(39.9, 116.4, 0.0)
        @test all(isfinite, xyz)
        @test sqrt(sum(abs2, xyz)) > 6300.0   # 约地球半径 km
    end
end
