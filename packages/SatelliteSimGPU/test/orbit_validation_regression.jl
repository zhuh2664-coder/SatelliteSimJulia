using Test
using KernelAbstractions
using SatelliteSimGPU

struct ValidationGPUBackend <: KernelAbstractions.Backend end

struct BackendArray{T,N,B<:KernelAbstractions.Backend} <: AbstractArray{T,N}
    data::Array{T,N}
    backend::B
end

BackendArray(data::Array{T,N}, backend::B) where {T,N,B<:KernelAbstractions.Backend} =
    BackendArray{T,N,B}(data, backend)

Base.size(array::BackendArray) = size(array.data)
Base.getindex(array::BackendArray, indices...) = getindex(array.data, indices...)
Base.IndexStyle(::Type{<:BackendArray}) = IndexLinear()
KernelAbstractions.get_backend(array::BackendArray) = array.backend

struct FailingBackendArray{T,N} <: AbstractArray{T,N}
    data::Array{T,N}
end

Base.size(array::FailingBackendArray) = size(array.data)
Base.getindex(array::FailingBackendArray, indices...) = getindex(array.data, indices...)
Base.IndexStyle(::Type{<:FailingBackendArray}) = IndexLinear()
KernelAbstractions.get_backend(::FailingBackendArray) =
    throw(ArgumentError("backend context unavailable"))

function kepler_inputs(::Type{T}=Float64) where {T<:AbstractFloat}
    return (
        T[7000, 7100],
        T[0.001, 0.01],
        T[0.4, 0.8],
        T[0.1, 0.2],
        T[0.3, 0.4],
        T[0.5, 0.6],
        T[0, 60],
    )
end

function sgp4_inputs(::Type{T}=Float64) where {T<:AbstractFloat}
    return (
        T[0.065, 0.06],
        T[0.001, 0.01],
        T[0.4, 0.8],
        T[0.1, 0.2],
        T[0.3, 0.4],
        T[0.5, 0.6],
        T[1e-5, -1e-5],
    )
end

const VALID_SGP4_CONSTANTS = (
    R0=6378.137,
    XKE=60.0 / sqrt(6378.137^3 / 398600.5),
    J2=0.00108262998905,
    J3=-0.00000253215306,
    J4=-0.00000161098761,
)

@testset "Kepler validation regression" begin
    inputs = kepler_inputs()
    positions = propagate_kepler_gpu(inputs...; model=:two_body)
    @test size(positions) == (2, 2, 3)
    @test all(isfinite, positions)

    range_inputs = (
        range(7000.0, 7100.0; length=2),
        range(0.001, 0.01; length=2),
        range(0.4, 0.8; length=2),
        range(0.1, 0.2; length=2),
        range(0.3, 0.4; length=2),
        range(0.5, 0.6; length=2),
        range(0.0, 60.0; length=2),
    )
    range_positions = propagate_kepler_gpu(range_inputs...; model=:two_body)
    @test size(range_positions) == (2, 2, 3)
    @test all(isfinite, range_positions)

    for input_index in eachindex(inputs)
        invalid = map(copy, inputs)
        invalid[input_index][1] = NaN
        @test_throws ArgumentError propagate_kepler_gpu(invalid...)
    end

    invalid = map(copy, inputs)
    invalid[1][1] = 0
    @test_throws ArgumentError propagate_kepler_gpu(invalid...)
    invalid = map(copy, inputs)
    invalid[2][1] = -eps()
    @test_throws ArgumentError propagate_kepler_gpu(invalid...)
    invalid[2][1] = 1
    @test_throws ArgumentError propagate_kepler_gpu(invalid...)

    @test_throws ArgumentError propagate_kepler_gpu(inputs...; mu_km3_s2=Inf)
    @test_throws ArgumentError propagate_kepler_gpu(inputs...; j2=0)
    @test_throws ArgumentError propagate_kepler_gpu(inputs...; earth_radius_km=-1)
    inputs32 = kepler_inputs(Float32)
    @test_throws ArgumentError propagate_kepler_gpu(inputs32...; mu_km3_s2=1e100)

    off_backend = BackendArray(copy(inputs[2]), ValidationGPUBackend())
    @test_throws ArgumentError propagate_kepler_gpu(
        inputs[1],
        off_backend,
        inputs[3],
        inputs[4],
        inputs[5],
        inputs[6],
        inputs[7],
    )

    failing_backend = FailingBackendArray(copy(inputs[2]))
    error = try
        propagate_kepler_gpu(
            inputs[1],
            failing_backend,
            inputs[3],
            inputs[4],
            inputs[5],
            inputs[6],
            inputs[7],
        )
        nothing
    catch caught
        caught
    end
    @test error isa ArgumentError
    @test error.msg == "backend context unavailable"
end

@testset "SGP4 host initialization validation regression" begin
    inputs = sgp4_inputs()
    elements = sgp4_init_host(inputs...)
    @test size(elements.consts) == (2, 25)
    @test length(elements.algo) == 2

    range_inputs = (
        range(0.065, 0.06; length=2),
        range(0.001, 0.01; length=2),
        range(0.4, 0.8; length=2),
        range(0.1, 0.2; length=2),
        range(0.3, 0.4; length=2),
        range(0.5, 0.6; length=2),
        range(1e-5, -1e-5; length=2),
    )
    range_elements = sgp4_init_host(range_inputs...)
    @test size(range_elements.consts) == (2, 25)

    for input_index in eachindex(inputs)
        invalid = map(copy, inputs)
        invalid[input_index][1] = NaN
        @test_throws ArgumentError sgp4_init_host(invalid...)
    end

    invalid = map(copy, inputs)
    invalid[1][1] = 0
    @test_throws ArgumentError sgp4_init_host(invalid...)
    invalid = map(copy, inputs)
    invalid[2][1] = -eps()
    @test_throws ArgumentError sgp4_init_host(invalid...)
    invalid[2][1] = 1
    @test_throws ArgumentError sgp4_init_host(invalid...)

    device_input = BackendArray(copy(inputs[1]), ValidationGPUBackend())
    @test_throws ArgumentError sgp4_init_host(
        device_input,
        inputs[2],
        inputs[3],
        inputs[4],
        inputs[5],
        inputs[6],
        inputs[7],
    )

    failing_backend = FailingBackendArray(copy(inputs[1]))
    error = try
        sgp4_init_host(
            failing_backend,
            inputs[2],
            inputs[3],
            inputs[4],
            inputs[5],
            inputs[6],
            inputs[7],
        )
        nothing
    catch caught
        caught
    end
    @test error isa ArgumentError
    @test error.msg == "backend context unavailable"

    static_cpu_input = BackendArray(copy(inputs[1]), CPU(; static=true))
    static_elements = sgp4_init_host(
        static_cpu_input,
        inputs[2],
        inputs[3],
        inputs[4],
        inputs[5],
        inputs[6],
        inputs[7],
    )
    @test size(static_elements.consts) == (2, 25)

    @test_throws ArgumentError sgp4_init_host(
        inputs...; sgp4c=merge(VALID_SGP4_CONSTANTS, (R0=0.0,)),
    )
    @test_throws ArgumentError sgp4_init_host(
        inputs...; sgp4c=merge(VALID_SGP4_CONSTANTS, (XKE=Inf,)),
    )
    @test_throws ArgumentError sgp4_init_host(
        inputs...; sgp4c=merge(VALID_SGP4_CONSTANTS, (J2=-1.0,)),
    )
    @test_throws ArgumentError sgp4_init_host(
        inputs...; sgp4c=merge(VALID_SGP4_CONSTANTS, (J3=NaN,)),
    )
    @test_throws ArgumentError sgp4_init_host(
        inputs...; sgp4c=merge(VALID_SGP4_CONSTANTS, (J4=Inf,)),
    )
    inputs32 = sgp4_inputs(Float32)
    @test_throws ArgumentError sgp4_init_host(
        inputs32...; sgp4c=merge(VALID_SGP4_CONSTANTS, (R0=1e100,)),
    )
end

@testset "SGP4 device-element validation regression" begin
    elements = sgp4_init_host(sgp4_inputs()...)
    positions = sgp4_propagate_gpu(elements, [0, 10])
    @test size(positions) == (2, 2, 3)
    @test all(isfinite, positions)

    bad_shape = Sgp4DeviceElements(
        elements.consts[:, 1:24],
        elements.algo,
        elements.R0,
        elements.XKE,
        elements.k2,
        elements.A30,
    )
    @test_throws ArgumentError sgp4_propagate_gpu(bad_shape, [0.0])

    bad_length = Sgp4DeviceElements(
        elements.consts,
        elements.algo[1:1],
        elements.R0,
        elements.XKE,
        elements.k2,
        elements.A30,
    )
    @test_throws ArgumentError sgp4_propagate_gpu(bad_length, [0.0])

    bad_codes = copy(elements.algo)
    bad_codes[1] = Int32(2)
    bad_algo = Sgp4DeviceElements(
        elements.consts,
        bad_codes,
        elements.R0,
        elements.XKE,
        elements.k2,
        elements.A30,
    )
    @test_throws ArgumentError sgp4_propagate_gpu(bad_algo, [0.0])

    off_backend_algo = BackendArray(copy(elements.algo), ValidationGPUBackend())
    mixed_backend = Sgp4DeviceElements(
        elements.consts,
        off_backend_algo,
        elements.R0,
        elements.XKE,
        elements.k2,
        elements.A30,
    )
    @test_throws ArgumentError sgp4_propagate_gpu(mixed_backend, [0.0])

    bad_consts_data = copy(elements.consts)
    bad_consts_data[1, 1] = NaN
    bad_consts = Sgp4DeviceElements(
        bad_consts_data,
        elements.algo,
        elements.R0,
        elements.XKE,
        elements.k2,
        elements.A30,
    )
    @test_throws ArgumentError sgp4_propagate_gpu(bad_consts, [0.0])

    for (field_index, invalid_value) in ((7, 0.0), (8, 0.0), (10, 0.0))
        invalid_consts = copy(elements.consts)
        invalid_consts[1, field_index] = invalid_value
        invalid_elements = Sgp4DeviceElements(
            invalid_consts,
            elements.algo,
            elements.R0,
            elements.XKE,
            elements.k2,
            elements.A30,
        )
        @test_throws ArgumentError sgp4_propagate_gpu(invalid_elements, [0.0])
    end

    invalid_scalars = (
        (0.0, elements.XKE, elements.k2, elements.A30),
        (elements.R0, Inf, elements.k2, elements.A30),
        (elements.R0, elements.XKE, 0.0, elements.A30),
        (elements.R0, elements.XKE, elements.k2, NaN),
    )
    for scalars in invalid_scalars
        invalid_elements =
            Sgp4DeviceElements(elements.consts, elements.algo, scalars...)
        @test_throws ArgumentError sgp4_propagate_gpu(invalid_elements, [0.0])
    end

    @test_throws ArgumentError sgp4_propagate_gpu(elements, Float64[])
    @test_throws ArgumentError sgp4_propagate_gpu(elements, [NaN])
    @test_throws ArgumentError sgp4_propagate_gpu(elements, [Inf])

    elements32 = sgp4_init_host(sgp4_inputs(Float32)...)
    @test_throws ArgumentError sgp4_propagate_gpu(elements32, [1e100])
end
