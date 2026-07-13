using Test
using ChainRulesCore
using SatelliteSimGPU

function coverage_fixture(::Type{T}) where {T<:AbstractFloat}
    positions = Array{T}(undef, 2, 3, 3)
    positions[1, 1, :] .= T.((6900.0, 500.0, 200.0))
    positions[1, 2, :] .= T.((6850.0, -600.0, 300.0))
    positions[1, 3, :] .= T.((7000.0, 400.0, -250.0))
    positions[2, 1, :] .= T.((400.0, 6900.0, -150.0))
    positions[2, 2, :] .= T.((-500.0, 6850.0, 250.0))
    positions[2, 3, :] .= T.((600.0, 7000.0, 100.0))

    ground_pts = T[
        6378.137 0.0 0.0
        0.0 6378.137 0.0
    ]
    weights = T[1.0, 0.7]
    kwargs = (
        min_el=T(15.0),
        τ_cov=T(12.0),
        dt=T(2.0),
        τ_revisit=T(1.5),
        λ=T(0.2),
    )
    return positions, ground_pts, weights, kwargs
end

@testset "coverage_loss_gpu input validation" begin
    for T in (Float32, Float64)
        positions, ground_pts, weights, kwargs = coverage_fixture(T)
        loss = function (
            test_weights;
            τ_cov=kwargs.τ_cov,
            dt=kwargs.dt,
            τ_revisit=kwargs.τ_revisit,
        )
            return coverage_loss_gpu(
                positions,
                ground_pts,
                test_weights;
                min_el=kwargs.min_el,
                τ_cov=τ_cov,
                dt=dt,
                τ_revisit=τ_revisit,
                λ=kwargs.λ,
            )
        end

        valid_loss = loss(weights)
        @test valid_loss isa T
        @test isfinite(valid_loss)

        for invalid_weight in (
            zero(T),
            -one(T),
            T(NaN),
            T(Inf),
            T(-Inf),
        )
            invalid_weights = copy(weights)
            invalid_weights[1] = invalid_weight
            @test_throws ArgumentError loss(invalid_weights)
        end
        @test_throws ArgumentError loss(fill(floatmax(T), length(weights)))

        for invalid_parameter in (
            zero(T),
            -one(T),
            T(NaN),
            T(Inf),
            T(-Inf),
        )
            @test_throws ArgumentError loss(weights; τ_cov=invalid_parameter)
            @test_throws ArgumentError loss(weights; dt=invalid_parameter)
            @test_throws ArgumentError loss(weights; τ_revisit=invalid_parameter)
        end
    end
end

@testset "coverage_loss_gpu positions-only pullback contract" begin
    positions, ground_pts, weights, kwargs = coverage_fixture(Float32)
    y, pullback = ChainRulesCore.rrule(
        coverage_loss_gpu,
        positions,
        ground_pts,
        weights;
        kwargs...,
    )
    @test y == coverage_loss_gpu(positions, ground_pts, weights; kwargs...)

    function test_zero_seed(seed)
        tangents = pullback(seed)
        @test tangents[1] isa NoTangent
        @test tangents[2] isa ZeroTangent
        @test tangents[3] isa ZeroTangent
        @test tangents[4] isa ZeroTangent
    end

    test_zero_seed(ZeroTangent())
    test_zero_seed(NoTangent())
    test_zero_seed(0.0f0)
    test_zero_seed(ChainRulesCore.Thunk(() -> 0.0f0))

    _, positions_tangent, ground_tangent, weights_tangent = pullback(1.0f0)
    @test positions_tangent isa Array{Float32,3}
    @test size(positions_tangent) == size(positions)
    @test ground_tangent isa ChainRulesCore.NotImplemented
    @test weights_tangent isa ChainRulesCore.NotImplemented

    thunk_evaluated = Ref(false)
    seed = ChainRulesCore.Thunk() do
        thunk_evaluated[] = true
        return 0.25f0
    end
    _, thunk_tangent, thunk_ground_tangent, thunk_weights_tangent = pullback(seed)
    @test thunk_evaluated[]
    @test isapprox(thunk_tangent, 0.25f0 .* positions_tangent)
    @test thunk_ground_tangent isa ChainRulesCore.NotImplemented
    @test thunk_weights_tangent isa ChainRulesCore.NotImplemented
end

@testset "coverage_loss_gpu saturated position derivative" begin
    positions = reshape(Float32[7000.0, 0.0, 0.0], 1, 1, 3)
    ground_pts = reshape(Float32[6378.137, 0.0, 0.0], 1, 3)
    weights = Float32[1.0]
    _, pullback = ChainRulesCore.rrule(
        coverage_loss_gpu,
        positions,
        ground_pts,
        weights;
        min_el=-90.0f0,
        τ_cov=1.0f-3,
        dt=1.0f0,
        τ_revisit=1.0f0,
        λ=0.1f0,
    )
    positions_tangent = pullback(1.0f0)[2]
    @test all(isfinite, positions_tangent)
    @test all(iszero, positions_tangent)
end

@testset "coverage_loss_gpu Float32 CPU finite differences" begin
    positions, ground_pts, weights, kwargs = coverage_fixture(Float32)
    _, pullback = ChainRulesCore.rrule(
        coverage_loss_gpu,
        positions,
        ground_pts,
        weights;
        kwargs...,
    )
    positions_tangent = pullback(1.0f0)[2]

    step = 0.5f0
    finite_difference = similar(positions)
    for index in eachindex(positions)
        positions_plus = copy(positions)
        positions_minus = copy(positions)
        positions_plus[index] += step
        positions_minus[index] -= step
        finite_difference[index] = (
            coverage_loss_gpu(positions_plus, ground_pts, weights; kwargs...) -
            coverage_loss_gpu(positions_minus, ground_pts, weights; kwargs...)
        ) / (2 * step)
    end

    @test maximum(abs, positions_tangent) > 1.0f-5
    @test isapprox(positions_tangent, finite_difference; rtol=5.0f-2, atol=2.0f-5)
end
