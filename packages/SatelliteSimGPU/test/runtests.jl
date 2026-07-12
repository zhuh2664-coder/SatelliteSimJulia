using Test
using Random
using KernelAbstractions
using ChainRulesCore
using SatelliteToolbox
using SatelliteSimBackends
using SatelliteSimGPU

const GOLDEN_DIR = joinpath(@__DIR__, "..", "golden")
include(joinpath(GOLDEN_DIR, "golden_reference.jl"))

function random_ground_grid(n_lat, n_lon, T)
    lat_bounds = (-70.0, 70.0)
    lats = range(deg2rad(lat_bounds[1]), deg2rad(lat_bounds[2]); length=n_lat)
    lons = range(deg2rad(-180.0), deg2rad(180.0); length=n_lon + 1)[1:end-1]
    points = Matrix{T}(undef, n_lat * n_lon, 3)
    weights = Vector{T}(undef, n_lat * n_lon)
    index = 1
    for φ in lats, λ in lons
        cφ = cos(φ)
        points[index, 1] = T(6378.137 * cφ * cos(λ))
        points[index, 2] = T(6378.137 * cφ * sin(λ))
        points[index, 3] = T(6378.137 * sin(φ))
        weights[index] = T(cφ)
        index += 1
    end
    return points, weights
end

function random_positions(n_sat, n_times, T)
    positions = Array{T}(undef, n_sat, n_times, 3)
    for sat in 1:n_sat, time_index in 1:n_times
        direction = randn(T, 3)
        direction ./= sqrt(sum(abs2, direction))
        radius = T(6900.0 + 100.0 * rand())
        positions[sat, time_index, :] .= radius .* direction
    end
    return positions
end

@testset "coverage_loss_gpu CPU parity" begin
    backend = get_backend(Array{Float64}(undef, 0))
    for (n_sat, n_times, n_lat, n_lon) in (
        (24, 10, 5, 10),
        (66, 30, 10, 20),
        (132, 60, 20, 25),
    )
        Random.seed!(n_sat + n_times + n_lat + n_lon)
        positions = random_positions(n_sat, n_times, Float64)
        ground_pts, weights = random_ground_grid(n_lat, n_lon, Float64)

        reference = GoldenReference.coverage_loss(
            positions,
            ground_pts,
            weights;
            min_el=10.0,
            τ_cov=5.0,
            dt=1.0,
            τ_revisit=1.0,
            λ=0.1,
        )
        candidate = coverage_loss_gpu(
            positions,
            ground_pts,
            weights;
            min_el=10.0,
            τ_cov=5.0,
            dt=1.0,
            τ_revisit=1.0,
            λ=0.1,
        )

        @test isapprox(candidate, reference; rtol=1e-10, atol=1e-12)
        @info "coverage parity" n_sat n_times n_ground=length(weights) reference candidate relative_error=abs(candidate - reference) / max(abs(reference), eps())
    end
end

@testset "coverage_loss_gpu validation" begin
    positions = zeros(Float64, 2, 3, 3)
    ground_pts = zeros(Float64, 4, 3)
    weights = ones(Float64, 4)
    @test_throws ArgumentError coverage_loss_gpu(
        positions[:, :, 1:2], ground_pts, weights,
    )
    @test_throws MethodError coverage_loss_gpu(
        positions, ground_pts, ones(Float32, 4),
    )
end

include(joinpath(GOLDEN_DIR, "golden_gsl_reference.jl"))

function gsl_station_geometry(stations)
    n_stations = length(stations)
    ground_ecef = Matrix{Float64}(undef, n_stations, 3)
    ned_rotation = Array{Float64}(undef, n_stations, 3, 3)

    for (station_index, (lat, lon, alt)) in enumerate(stations)
        lat_rad = deg2rad(lat)
        lon_rad = deg2rad(lon)
        gs_m = SatelliteToolbox.geodetic_to_ecef(lat_rad, lon_rad, alt * 1000)
        for component in 1:3
            ground_ecef[station_index, component] = gs_m[component] / 1000
        end

        for column in 1:3
            delta_m = zeros(Float64, 3)
            delta_m[column] = 1.0
            ned_m = SatelliteToolbox.ecef_to_ned(
                gs_m .+ delta_m,
                lat_rad,
                lon_rad,
                alt * 1000;
                translate=true,
            )
            for row in 1:3
                ned_rotation[station_index, row, column] = ned_m[row]
            end
        end
    end

    return ground_ecef, ned_rotation
end

function golden_gsl_batch(positions, stations)
    n_satellites, n_times, _ = size(positions)
    n_stations = length(stations)
    available = Array{Bool}(undef, n_satellites, n_stations, n_times)
    distances = Array{Float64}(undef, n_satellites, n_stations, n_times)
    elevations = Array{Float64}(undef, n_satellites, n_stations, n_times)
    delays = Array{Float64}(undef, n_satellites, n_stations, n_times)

    for time_index in 1:n_times
        pos_matrix = @view positions[:, time_index, :]
        avail_t, dist_t, elev_t, delay_t =
            GoldenGSLReference.evaluate_gsl_batch(pos_matrix, stations)
        available[:, :, time_index] .= avail_t
        distances[:, :, time_index] .= dist_t
        elevations[:, :, time_index] .= elev_t
        delays[:, :, time_index] .= delay_t
    end

    return available, distances, elevations, delays
end

function random_gsl_stations(n_stations)
    stations = Vector{NTuple{3,Float64}}(undef, n_stations)
    for station_index in 1:n_stations
        lat = -70.0 + 140.0 * (station_index - 1) / max(n_stations - 1, 1)
        lon = mod(37.0 * station_index + 13.0, 360.0) - 180.0
        alt = 0.2 + 1.5 * mod(station_index, 5) / 4
        stations[station_index] = (lat, lon, alt)
    end
    return stations
end

@testset "evaluate_gsl_batch_gpu CPU parity" begin
    for (n_satellites, n_stations, n_times) in (
        (66, 10, 30),
        (132, 20, 60),
    )
        Random.seed!(n_satellites + n_stations + n_times)
        positions = random_positions(n_satellites, n_times, Float64)
        stations = random_gsl_stations(n_stations)
        ground_ecef, ned_rotation = gsl_station_geometry(stations)

        reference = golden_gsl_batch(positions, stations)
        candidate = evaluate_gsl_batch_gpu(
            positions,
            ground_ecef,
            ned_rotation;
            gsl_min_elevation_deg=25.0,
            gsl_max_range_km=2000.0,
        )

        @test candidate[1] == reference[1]
        @test isapprox(candidate[2], reference[2]; rtol=1e-10, atol=1e-10)
        @test isapprox(candidate[3], reference[3]; rtol=1e-10, atol=1e-10)
        @test isapprox(candidate[4], reference[4]; rtol=1e-10, atol=1e-10)

        for (label, actual, expected) in zip(
            ("distance", "elevation", "delay"),
            candidate[2:4],
            reference[2:4],
        )
            relative_error = maximum(
                abs.(actual .- expected) ./ max.(abs.(expected), eps(Float64)),
            )
            @info "GSL parity" n_satellites n_stations n_times label relative_error
        end
        @info "GSL availability parity" n_satellites n_stations n_times equal=(
            candidate[1] == reference[1]
        )

        if n_satellites == 66
            positions32 = Float32.(positions)
            ground_ecef32 = Float32.(ground_ecef)
            ned_rotation32 = Float32.(ned_rotation)
            candidate32 = evaluate_gsl_batch_gpu(
                positions32,
                ground_ecef32,
                ned_rotation32;
                gsl_min_elevation_deg=Float32(25.0),
                gsl_max_range_km=Float32(2000.0),
            )
            @test size(candidate32[1]) == (n_satellites, n_stations, n_times)
            @test candidate32[1] == reference[1]
            @test isapprox(
                candidate32[2],
                reference[2];
                rtol=1e-5,
                atol=1e-3,
            )
            @test isapprox(
                candidate32[3],
                reference[3];
                rtol=1e-5,
                atol=1e-3,
            )
            @test isapprox(
                candidate32[4],
                reference[4];
                rtol=1e-5,
                atol=1e-5,
            )
        end
    end
end

@testset "evaluate_gsl_batch_gpu validation" begin
    positions = zeros(Float64, 2, 3, 3)
    ground_ecef = zeros(Float64, 4, 3)
    ned_rotation = zeros(Float64, 4, 3, 3)
    @test_throws ArgumentError evaluate_gsl_batch_gpu(
        positions[:, :, 1:2], ground_ecef, ned_rotation,
    )
    @test_throws ArgumentError evaluate_gsl_batch_gpu(
        positions, ground_ecef, zeros(Float64, 4, 2, 3),
    )
end

@testset "Kernel compute backend GSL contract" begin
    Random.seed!(20260716)
    positions = random_positions(24, 8, Float64)
    stations = random_gsl_stations(6)
    expected = golden_gsl_batch(positions, stations)
    backend = KernelComputeBackend(CPU(); precision=Float64)
    actual = evaluate_gsl_series(
        backend,
        positions,
        stations;
        gsl_min_elevation_deg=25.0,
        gsl_max_range_km=2000.0,
    )

    @test actual.available == expected[1]
    @test isapprox(actual.distance_km, expected[2]; rtol=1e-10, atol=1e-10)
    @test isapprox(actual.elevation_deg, expected[3]; rtol=1e-10, atol=1e-10)
    @test isapprox(actual.delay_ms, expected[4]; rtol=1e-10, atol=1e-10)
    @test compute_backend_capabilities(backend).operations == (:gsl_series, :isl_series)
    @test compute_backend_capabilities(backend).device == :cpu
    @test compute_backend_fingerprint(backend).implementation_module ==
          "SatelliteSimGPU"
    @test compute_backend_cache_token(backend) !== nothing
    @test all(isfile, compute_backend_source_files(backend))
    @test compute_backend_capabilities(KernelComputeBackend(CPU())).precision ===
          Float64
    @test_throws ArgumentError register_kernel_compute_backend!(:not_gpu, CPU())
    @test SatelliteSimGPU._compute_precision((;)) === Float64
    @test SatelliteSimGPU._compute_precision((precision="float64",)) === Float64
    @test_throws ArgumentError SatelliteSimGPU._compute_precision(
        (precisionn="float64",),
    )

    empty_result = evaluate_gsl_series(
        backend,
        positions,
        NTuple{3,Float64}[];
        gsl_min_elevation_deg=25.0,
        gsl_max_range_km=2000.0,
    )
    @test size(empty_result.available) == (24, 0, 8)
end

include(joinpath(GOLDEN_DIR, "golden_isl_reference.jl"))

function random_isl_scenario(n_sat, n_times, ::Type{T}; seed=0) where {T}
    Random.seed!(seed)
    positions = Array{T}(undef, n_sat, n_times, 3)
    velocities = Array{T}(undef, n_sat, n_times, 3)
    for sat in 1:n_sat, time_index in 1:n_times
        dir = randn(T, 3)
        dir ./= sqrt(sum(abs2, dir))
        radius = T(6871.0 + 80.0 * rand())
        positions[sat, time_index, :] .= radius .* dir
        vdir = randn(T, 3)
        vdir ./= sqrt(sum(abs2, vdir))
        velocities[sat, time_index, :] .= T(7.6) .* vdir
    end
    return positions, velocities
end

@testset "evaluate_isl_batch_gpu CPU parity" begin
    for (n_sat, n_times) in ((12, 5), (30, 8))
        positions, velocities =
            random_isl_scenario(n_sat, n_times, Float64; seed=n_sat + n_times)
        pairs = Tuple{Int,Int}[]
        for i in 1:n_sat, j in (i + 1):n_sat
            push!(pairs, (i, j))
        end

        # 位置-only 路径（距离 + LOS + 距离约束）
        ref0 = GoldenISLReference.evaluate_isl_series(positions, pairs)
        cand0 = evaluate_isl_batch_gpu(positions, pairs)
        @test cand0.available == ref0.available
        @test cand0.line_of_sight == ref0.line_of_sight
        @test isapprox(cand0.distance_km, ref0.distance_km; rtol=1e-9, atol=1e-9)
        @test isapprox(cand0.delay_ms, ref0.delay_ms; rtol=1e-9, atol=1e-9)

        # 带速度路径（RTN 仰角 / 方位 / 持续时长）
        ref1 = GoldenISLReference.evaluate_isl_series(
            positions, pairs; velocities=velocities,
        )
        cand1 = evaluate_isl_batch_gpu(positions, pairs; velocities=velocities)
        @test cand1.available == ref1.available
        @test isapprox(cand1.distance_km, ref1.distance_km; rtol=1e-9, atol=1e-9)
        @test isapprox(cand1.elevation_deg, ref1.elevation_deg; rtol=1e-8, atol=1e-8)
        @test isapprox(cand1.cos_psi, ref1.cos_psi; rtol=1e-8, atol=1e-8)
        @test isapprox(cand1.duration_s, ref1.duration_s; rtol=1e-6, atol=1e-6)
        @info "ISL parity" n_sat n_times n_pairs=length(pairs)
    end
end

@testset "evaluate_isl_batch_gpu validation" begin
    positions = zeros(Float64, 3, 4, 3)
    @test_throws ArgumentError evaluate_isl_batch_gpu(
        positions[:, :, 1:2], [(1, 2)],
    )
    @test_throws ArgumentError evaluate_isl_batch_gpu(
        positions, [(1, 9)],
    )
    empty = evaluate_isl_batch_gpu(positions, Tuple{Int,Int}[])
    @test size(empty.available) == (0, 4)
end

@testset "Kernel compute backend ISL contract" begin
    backend = KernelComputeBackend(CPU(); precision=Float64)
    for (n_sat, n_times) in ((12, 5), (24, 6))
        positions, velocities =
            random_isl_scenario(n_sat, n_times, Float64; seed=100 + n_sat + n_times)
        pairs = Tuple{Int,Int}[]
        for i in 1:n_sat, j in (i + 1):n_sat
            push!(pairs, (i, j))
        end

        # 位置-only 路径（距离 + LOS + 距离约束）
        ref0 = GoldenISLReference.evaluate_isl_series(positions, pairs)
        got0 = evaluate_isl_series(backend, positions, pairs)
        @test got0 isa ISLSeriesResult
        @test got0.available == ref0.available
        @test got0.line_of_sight == ref0.line_of_sight
        @test isapprox(got0.distance_km, ref0.distance_km; rtol=1e-9, atol=1e-9)
        @test isapprox(got0.delay_ms, ref0.delay_ms; rtol=1e-9, atol=1e-9)
        @test got0.metadata["backend"] == compute_backend_name(backend)

        # 带速度路径（RTN 仰角 / 方位 / 持续时长）
        ref1 = GoldenISLReference.evaluate_isl_series(
            positions, pairs; velocities=velocities,
        )
        got1 = evaluate_isl_series(backend, positions, pairs; velocities=velocities)
        @test got1.available == ref1.available
        @test isapprox(got1.distance_km, ref1.distance_km; rtol=1e-9, atol=1e-9)
        @test isapprox(got1.elevation_deg, ref1.elevation_deg; rtol=1e-8, atol=1e-8)
        @test isapprox(got1.cos_psi, ref1.cos_psi; rtol=1e-8, atol=1e-8)
        @test isapprox(got1.duration_s, ref1.duration_s; rtol=1e-6, atol=1e-6)
        @info "ISL series parity" n_sat n_times n_pairs=length(pairs)
    end

    @test compute_backend_capabilities(backend).operations ==
          (:gsl_series, :isl_series)

    # 空 pairs → (0, n_times)
    positions, _ = random_isl_scenario(8, 4, Float64; seed=1)
    empty_result = evaluate_isl_series(backend, positions, Tuple{Int,Int}[])
    @test empty_result isa ISLSeriesResult
    @test size(empty_result.available) == (0, 4)

    # 契约回退：generic evaluate_isl_series 对未实现该算子的后端抛 MethodError
    @test_throws MethodError evaluate_isl_series(
        CPUComputeBackend(), positions, [(1, 2)],
    )
end

@testset "device residency pipeline" begin
    positions, velocities = random_isl_scenario(20, 6, Float64; seed=7)
    pairs = [(i, i + 1) for i in 1:19]
    direct = evaluate_isl_batch_gpu(positions, pairs; velocities=velocities)

    # 上传一次 → 设备上算 → 下载一次
    out = device_pipeline(CPU(), positions, velocities) do pos_d, vel_d
        evaluate_isl_batch_gpu(pos_d, pairs; velocities=vel_d)
    end
    @test out.available == direct.available
    @test isapprox(out.distance_km, direct.distance_km; rtol=1e-12, atol=1e-12)
    @test isapprox(out.elevation_deg, direct.elevation_deg; rtol=1e-12, atol=1e-12)
    @test isapprox(out.duration_s, direct.duration_s; rtol=1e-12, atol=1e-12)
    @test out.available isa Array{Bool}
    @test out.distance_km isa Array{Float64}

    # to_device / to_host 往返
    @test to_host(to_device(CPU(), positions)) == positions
end

@testset "coverage_loss_gpu adjoint (finite-difference)" begin
    Random.seed!(11)
    n_sat, n_times, n_lat, n_lon = 8, 4, 4, 6
    positions = Array{Float64}(undef, n_sat, n_times, 3)
    for s in 1:n_sat, t in 1:n_times
        dir = randn(3)
        dir ./= sqrt(sum(abs2, dir))
        positions[s, t, :] .= (6900.0 + 50 * rand()) .* dir
    end
    ground_pts, weights = random_ground_grid(n_lat, n_lon, Float64)
    kw = (min_el=10.0, τ_cov=5.0, dt=1.0, τ_revisit=1.0, λ=0.1)

    y, pb = ChainRulesCore.rrule(coverage_loss_gpu, positions, ground_pts, weights; kw...)
    @test y == coverage_loss_gpu(positions, ground_pts, weights; kw...)
    _, gradP, _, _ = pb(1.0)
    @test size(gradP) == size(positions)

    h = 1e-3
    for _ in 1:12
        s = rand(1:n_sat)
        t = rand(1:n_times)
        c = rand(1:3)
        Pp = copy(positions); Pp[s, t, c] += h
        Pm = copy(positions); Pm[s, t, c] -= h
        fd = (coverage_loss_gpu(Pp, ground_pts, weights; kw...) -
              coverage_loss_gpu(Pm, ground_pts, weights; kw...)) / (2h)
        @test isapprox(gradP[s, t, c], fd; atol=1e-5, rtol=1e-3)
    end
end

@testset "Float32 cutoff policy" begin
    station = [(0.0, 0.0, 0.0)]
    positions = reshape([8378.13701, 0.0, 0.0], 1, 1, 3)
    result64 = evaluate_gsl_series(
        KernelComputeBackend(CPU(); precision=Float64),
        positions,
        station;
        gsl_min_elevation_deg=25.0,
        gsl_max_range_km=2000.0,
    )
    result32 = evaluate_gsl_series(
        KernelComputeBackend(CPU(); precision=Float32),
        positions,
        station;
        gsl_min_elevation_deg=25.0,
        gsl_max_range_km=2000.0,
    )

    @test !result64.available[1, 1, 1]
    @test result32.available[1, 1, 1]
    @test abs(result64.distance_km[1, 1, 1] - 2000.0) <= 1e-4
    @test abs(result32.distance_km[1, 1, 1] - 2000.0) <= 1e-3
end

include(joinpath(GOLDEN_DIR, "golden_propagator_reference.jl"))

function random_kepler_elements(n_sat, ::Type{T}; seed=0) where {T}
    Random.seed!(seed)
    sma = Vector{T}(undef, n_sat)
    ecc = Vector{T}(undef, n_sat)
    inc = Vector{T}(undef, n_sat)
    raan = Vector{T}(undef, n_sat)
    argp = Vector{T}(undef, n_sat)
    nu = Vector{T}(undef, n_sat)
    for s in 1:n_sat
        sma[s] = T(6771.0 + 400.0 * rand())            # LEO：高度约 393–793 km
        ecc[s] = T(0.0005 + 0.02 * rand())             # 近圆
        inc[s] = T(deg2rad(30.0 + 120.0 * rand()))
        raan[s] = T(deg2rad(360.0 * rand()))
        argp[s] = T(deg2rad(360.0 * rand()))
        nu[s] = T(deg2rad(360.0 * rand()))
    end
    return sma, ecc, inc, raan, argp, nu
end

# SatelliteToolbox 参考：与 src/orbit 的 propagate_positions 同一算法（step! 累进 Δt）。
function satellitetoolbox_series(sma, ecc, inc, raan, argp, nu, tspan, model)
    n_sat = length(sma)
    n_times = length(tspan)
    out = Array{Float64}(undef, n_sat, n_times, 3)
    val = model === :j2 ? Val(:J2) : Val(:TwoBody)
    for s in 1:n_sat
        el = SatelliteToolbox.KeplerianElements(
            0.0, Float64(sma[s]) * 1000, Float64(ecc[s]),
            Float64(inc[s]), Float64(raan[s]), Float64(argp[s]), Float64(nu[s]),
        )
        prop = SatelliteToolbox.Propagators.init(val, el)
        for (time_index, t) in enumerate(tspan)
            Δt = time_index == 1 ? tspan[1] : tspan[time_index] - tspan[time_index - 1]
            sv = SatelliteToolbox.Propagators.step!(
                prop, Float64(Δt), SatelliteToolbox.OrbitStateVector,
            )
            out[s, time_index, 1] = sv.r[1] / 1000
            out[s, time_index, 2] = sv.r[2] / 1000
            out[s, time_index, 3] = sv.r[3] / 1000
        end
    end
    return out
end

# SatelliteToolbox 参考 ECEF：与 src/orbit 的 propagate_to_ecef 同一路径
# （ST 传播器出 ECI + r_eci_to_ecef(TEME(), PEF(), jd)，jd = tspan/86400）。
function satellitetoolbox_series_ecef(sma, ecc, inc, raan, argp, nu, tspan, model)
    eci = satellitetoolbox_series(sma, ecc, inc, raan, argp, nu, tspan, model)
    out = similar(eci)
    for (time_index, t) in enumerate(tspan)
        D = SatelliteToolbox.r_eci_to_ecef(
            SatelliteToolbox.TEME(), SatelliteToolbox.PEF(), Float64(t) / 86400.0,
        )
        for s in 1:size(eci, 1)
            v = @view eci[s, time_index, :]
            r = D * v
            out[s, time_index, 1] = r[1]
            out[s, time_index, 2] = r[2]
            out[s, time_index, 3] = r[3]
        end
    end
    return out
end

@testset "propagate_kepler_gpu analytic parity" begin
    for model in (:two_body, :j2)
        sma, ecc, inc, raan, argp, nu =
            random_kepler_elements(20, Float64; seed=(model === :j2 ? 2 : 1))
        tspan = collect(0.0:120.0:3600.0)   # 0..1h，31 个时刻

        # 1) 设备核（KA CPU 后端）vs 冻结 golden 标量：机器精度对齐（主对标）
        golden = GoldenPropagatorReference.propagate_series(
            sma, ecc, inc, raan, argp, nu, tspan; model=model,
        )
        got = propagate_kepler_gpu(sma, ecc, inc, raan, argp, nu, tspan; model=model)
        @test got isa Array{Float64,3}
        @test size(got) == (20, length(tspan), 3)
        @test isapprox(got, golden; rtol=1e-9, atol=1e-7)

        # 2) 交叉验证 vs SatelliteToolbox（src/orbit propagate_positions/J2 所封装）
        reference = satellitetoolbox_series(sma, ecc, inc, raan, argp, nu, tspan, model)
        @test isapprox(got, reference; rtol=1e-7, atol=1e-5)
        @info "propagator parity" model max_abs_err_km=maximum(abs.(got .- reference))
    end

    # 3) 设备驻留：元素上设备 → 设备上传播 → ISL 直接吃设备位置（省 host 往返）
    sma, ecc, inc, raan, argp, nu = random_kepler_elements(12, Float64; seed=9)
    tspan = collect(0.0:300.0:1800.0)
    pairs = [(i, i + 1) for i in 1:11]
    host_pos = propagate_kepler_gpu(sma, ecc, inc, raan, argp, nu, tspan; model=:j2)
    isl_host = evaluate_isl_batch_gpu(host_pos, pairs)
    out = device_pipeline(CPU(), sma, ecc, inc, raan, argp, nu, tspan) do a, e, i, om, w, v, ts
        pos_d = propagate_kepler_gpu(a, e, i, om, w, v, ts; model=:j2)
        evaluate_isl_batch_gpu(pos_d, pairs)
    end
    @test out.available == isl_host.available
    @test isapprox(out.distance_km, isl_host.distance_km; rtol=1e-12, atol=1e-12)

    # 4) Float32 后端可运行且物理正确（放宽容差，短时段限制舍入累积）
    sma32, ecc32, inc32, raan32, argp32, nu32 =
        random_kepler_elements(16, Float32; seed=5)
    tspan32 = collect(Float32, 0.0:60.0:600.0)
    golden32 = GoldenPropagatorReference.propagate_series(
        Float64.(sma32), Float64.(ecc32), Float64.(inc32),
        Float64.(raan32), Float64.(argp32), Float64.(nu32),
        Float64.(tspan32); model=:two_body,
    )
    got32 = propagate_kepler_gpu(
        sma32, ecc32, inc32, raan32, argp32, nu32, tspan32; model=:two_body,
    )
    @test got32 isa Array{Float32,3}
    @test all(isfinite, got32)
    @test isapprox(Float64.(got32), golden32; rtol=1e-2, atol=2.0)

    # 5) 校验：非法 model / 长度不一致
    @test_throws ArgumentError propagate_kepler_gpu(
        sma, ecc, inc, raan, argp, nu, tspan; model=:sgp4,
    )
    @test_throws ArgumentError propagate_kepler_gpu(
        sma[1:3], ecc, inc, raan, argp, nu, tspan,
    )
end

@testset "propagate_to_ecef_gpu TEME->PEF parity" begin
    for model in (:two_body, :j2)
        sma, ecc, inc, raan, argp, nu =
            random_kepler_elements(18, Float64; seed=(model === :j2 ? 4 : 3))
        tspan = collect(0.0:150.0:5400.0)   # 0..1.5h

        # 1) 设备 ECEF vs 冻结 golden 标量 ECEF：机器精度对齐（主对标）
        golden_ecef = GoldenPropagatorReference.propagate_series_ecef(
            sma, ecc, inc, raan, argp, nu, tspan; model=model,
        )
        got_ecef = propagate_to_ecef_gpu(sma, ecc, inc, raan, argp, nu, tspan; model=model)
        @test got_ecef isa Array{Float64,3}
        @test size(got_ecef) == (18, length(tspan), 3)
        @test isapprox(got_ecef, golden_ecef; rtol=1e-9, atol=1e-7)

        # 2) 交叉验证 vs CPU 主链变换：SatelliteToolbox ECI + r_eci_to_ecef(TEME,PEF,jd)
        ref_ecef = satellitetoolbox_series_ecef(sma, ecc, inc, raan, argp, nu, tspan, model)
        @test isapprox(got_ecef, ref_ecef; rtol=1e-7, atol=1e-6)
        @info "ECEF parity vs CPU main-chain transform" model max_abs_err_km=maximum(
            abs.(got_ecef .- ref_ecef)
        )
    end

    # 3) 独立 teme_to_pef_gpu 与链式 propagate_to_ecef_gpu 一致；且确有恒星时旋转 + 保范
    sma, ecc, inc, raan, argp, nu = random_kepler_elements(10, Float64; seed=8)
    tspan = collect(0.0:300.0:3600.0)
    eci = propagate_kepler_gpu(sma, ecc, inc, raan, argp, nu, tspan; model=:j2)
    ecef_standalone = teme_to_pef_gpu(eci, tspan)
    ecef_chained = propagate_to_ecef_gpu(sma, ecc, inc, raan, argp, nu, tspan; model=:j2)
    @test ecef_standalone == ecef_chained
    @test !isapprox(ecef_standalone, eci)   # GMST(t)≠0 → ECEF 应不同于 ECI
    for s in 1:10, tj in 1:length(tspan)
        r_eci = sqrt(sum(abs2, @view eci[s, tj, :]))
        r_ecef = sqrt(sum(abs2, @view ecef_standalone[s, tj, :]))
        @test isapprox(r_eci, r_ecef; rtol=1e-11, atol=1e-7)   # Z 旋转保范
    end

    # 4) Float32 后端可运行、有限（恒星时角内部仍走 Float64）
    sma32, ecc32, inc32, raan32, argp32, nu32 =
        random_kepler_elements(12, Float32; seed=6)
    tspan32 = collect(Float32, 0.0:120.0:1200.0)
    got32 = propagate_to_ecef_gpu(
        sma32, ecc32, inc32, raan32, argp32, nu32, tspan32; model=:two_body,
    )
    @test got32 isa Array{Float32,3}
    @test all(isfinite, got32)

    # 5) 校验：tspan 长度不一致 / 形状错误
    @test_throws ArgumentError teme_to_pef_gpu(eci, tspan[1:2])
    @test_throws ArgumentError teme_to_pef_gpu(eci[:, :, 1:2], tspan)
end

@testset "device residency: 元素→传播→TEME→PEF→GSL/覆盖 全程设备" begin
    sma, ecc, inc, raan, argp, nu = random_kepler_elements(24, Float64; seed=11)
    tspan = collect(0.0:120.0:1800.0)
    stations = random_gsl_stations(8)
    ground_ecef, ned_rotation = gsl_station_geometry(stations)
    ground_pts, weights = random_ground_grid(6, 8, Float64)

    # host 基线（相同 GPU 函数，host 驻留）
    host_ecef = propagate_to_ecef_gpu(sma, ecc, inc, raan, argp, nu, tspan; model=:j2)
    host_gsl = evaluate_gsl_batch_gpu(
        host_ecef, ground_ecef, ned_rotation;
        gsl_min_elevation_deg=25.0, gsl_max_range_km=2000.0,
    )
    host_cov = coverage_loss_gpu(
        host_ecef, ground_pts, weights;
        min_el=10.0, τ_cov=5.0, dt=1.0, τ_revisit=1.0, λ=0.1,
    )

    # 全程设备驻留：元素 + 站点几何一次上传 → 设备传播 → 设备 TEME→PEF → 设备 GSL → 一次下载
    gsl_out = device_pipeline(
        CPU(), sma, ecc, inc, raan, argp, nu, tspan, ground_ecef, ned_rotation,
    ) do a, e, i, om, w, v, ts, ge, nr
        pos_ecef = propagate_to_ecef_gpu(a, e, i, om, w, v, ts; model=:j2)
        evaluate_gsl_batch_gpu(
            pos_ecef, ge, nr; gsl_min_elevation_deg=25.0, gsl_max_range_km=2000.0,
        )
    end
    @test gsl_out[1] == host_gsl[1]
    @test isapprox(gsl_out[2], host_gsl[2]; rtol=1e-12, atol=1e-12)
    @test isapprox(gsl_out[3], host_gsl[3]; rtol=1e-12, atol=1e-12)
    @test isapprox(gsl_out[4], host_gsl[4]; rtol=1e-12, atol=1e-12)
    @test any(gsl_out[1])   # 物理 sanity：ECEF 对齐地面站后确有可见 GSL

    # 全程设备驻留：→ 覆盖损失（标量）
    cov_out = device_pipeline(
        CPU(), sma, ecc, inc, raan, argp, nu, tspan, ground_pts, weights,
    ) do a, e, i, om, w, v, ts, gp, wt
        pos_ecef = propagate_to_ecef_gpu(a, e, i, om, w, v, ts; model=:j2)
        coverage_loss_gpu(
            pos_ecef, gp, wt; min_el=10.0, τ_cov=5.0, dt=1.0, τ_revisit=1.0, λ=0.1,
        )
    end
    @test isapprox(cov_out, host_cov; rtol=1e-12, atol=1e-12)

    # 说明 ECEF 变换的必要性：ECI 直接喂 GSL（未对齐地固站）可见性与 ECEF 不同
    eci = propagate_kepler_gpu(sma, ecc, inc, raan, argp, nu, tspan; model=:j2)
    gsl_from_eci = evaluate_gsl_batch_gpu(
        eci, ground_ecef, ned_rotation;
        gsl_min_elevation_deg=25.0, gsl_max_range_km=2000.0,
    )
    @info "ECEF vs ECI GSL visibility" ecef_visible=sum(host_gsl[1]) eci_visible=sum(
        gsl_from_eci[1]
    )
end
