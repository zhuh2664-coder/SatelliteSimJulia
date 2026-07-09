# ===== Viz 单元测试 =====

using SatelliteSimJulia
using Test

Viz = SatelliteSimJulia.SatelliteSimViz
# Makie 仅在 SatelliteSimViz 包内是显式依赖；顶层测试环境没有 Makie，
# 因此通过 Viz 模块的命名空间访问它。
const Makie = Viz.Makie
const RUN_VIZ_RENDER = get(ENV, "SATSIM_RUN_VIZ", "0") == "1"

# 最小 fixture：2 卫星、3 时间步
pos = zeros(Float64, 2, 3, 3)
pos[1, 1, :] .= 7000.0, 0.0, 0.0
pos[1, 2, :] .= 6000.0, 3500.0, 0.0
pos[1, 3, :] .= 3500.0, 6000.0, 0.0
pos[2, :, :] .= pos[1, :, :]

@testset "Coordinate conversions" begin
    lat, lon, alt = Viz.ecef_to_latlon(7000.0, 0.0, 0.0)
    @test abs(lat) < 1.0
    @test abs(lon) < 1.0
    @test alt ≈ 622.0 atol = 5.0

    x, y, z = Viz.latlon_to_xyz(lat, lon; alt_km = alt)
    @test x ≈ 7000.0 atol = 1.0
    @test y ≈ 0.0 atol = 1.0
    @test z ≈ 0.0 atol = 1.0
end

@testset "API functions return figures" begin
    if RUN_VIZ_RENDER
        fig = Viz.plot_orbit_snapshot(pos)
        @test fig isa Makie.Figure

        fig2 = Viz.plot_ground_track(pos)
        @test fig2 isa Makie.Figure

        fig3 = Viz.plot_coverage_heatmap(pos; grid_nlat = 10, grid_nlon = 20)
        @test fig3 isa Makie.Figure

        fig4 = Viz.plot_dashboard(pos)
        @test fig4 isa Makie.Figure
    else
        @info "Viz figure rendering skipped; set SATSIM_RUN_VIZ=1 to enable"
        @test hasmethod(Viz.plot_orbit_snapshot, Tuple{Array{Float64,3}})
        @test hasmethod(Viz.plot_ground_track, Tuple{Array{Float64,3}})
        @test hasmethod(Viz.plot_coverage_heatmap, Tuple{Array{Float64,3}})
        @test hasmethod(Viz.plot_dashboard, Tuple{Array{Float64,3}})
    end
end

@testset "Snapshot save produces file" begin
    if RUN_VIZ_RENDER
        tmp = tempname() * ".png"
        try
            Viz.save_orbit_snapshot(tmp, pos)
            @test isfile(tmp)
            @test filesize(tmp) > 100
        finally
            isfile(tmp) && rm(tmp; force = true)
        end
    else
        @info "Viz snapshot rendering skipped; set SATSIM_RUN_VIZ=1 to enable"
        @test hasmethod(Viz.save_orbit_snapshot, Tuple{AbstractString,Array{Float64,3}})
    end
end

@testset "Config structs" begin
    cfg = Viz.MakieViewerConfig()
    @test cfg.dark_theme == true
    @test cfg.show_beams == false
    @test cfg.beam_angle_deg == 30.0

    cfg2 = Viz.MakieViewerConfig(; show_beams = true, beam_angle_deg = 20.0)
    @test cfg2.show_beams == true
    @test cfg2.beam_angle_deg == 20.0
end

@testset "Earth texture" begin
    tex = Viz.generate_night_lights_texture(; width = 64, height = 32)
    @test size(tex) == (64, 32)
    @test eltype(tex) <: Makie.Colors.Colorant
    # 至少有陆地像素存在
    flat_vals = vec(tex)
    @test any(c -> Makie.Colors.red(c) > 0.02, flat_vals)
end

@testset "CZML export" begin
    using JSON

    pos2 = zeros(Float64, 2, 3, 3)
    pos2[1, 1, :] .= 7000.0, 0.0, 0.0
    pos2[1, 2, :] .= 6000.0, 3500.0, 0.0
    pos2[1, 3, :] .= 3500.0, 6000.0, 0.0
    pos2[2, :, :] .= pos2[1, :, :] .* 1.1

    # 无 ISL
    czml_str = Viz.to_czml(pos2; dt = 60.0)
    @test czml_str isa String
    @test length(czml_str) > 0
    packets = JSON.parse(czml_str)
    @test packets isa Vector
    @test length(packets) >= 3  # document + 2 satellites

    doc = packets[1]
    @test doc["id"] == "document"
    @test doc["version"] == "1.0"

    sat1 = packets[2]
    @test sat1["id"] == "satellite/1"
    @test haskey(sat1, "position")
    @test sat1["position"]["referenceFrame"] == "FIXED"
    @test sat1["position"]["interpolationDegree"] == 1
    @test sat1["position"]["cartesian"][1:4] == Any[0.0, 7.0e6, 0.0, 0.0]
    @test occursin("2000-01-01T12:02:00Z", doc["clock"]["interval"])

    # 带 ISL
    czml2 = Viz.to_czml(pos2; dt = 60.0, isl_pairs = [(1, 2)])
    packets2 = JSON.parse(czml2)
    @test length(packets2) >= 4  # document + 2 satellites + 1 ISL
    isl = packets2[4]
    @test isl["id"] == "isl/1"
    @test haskey(isl, "polyline")

    # write_czml
    tmp = tempname() * ".czml"
    try
        path = Viz.write_czml(tmp, pos2; dt = 60.0)
        @test isfile(tmp)
        @test filesize(tmp) > 100
        # 验证内容可解析
        parsed = JSON.parsefile(tmp)
        @test parsed isa Vector
        @test parsed[1]["id"] == "document"
    finally
        isfile(tmp) && rm(tmp; force = true)
    end
end
