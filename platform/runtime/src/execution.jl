# Execution backend abstraction (design ADR: start/status/wait_result/cancel).
#
# A backend runs one job's runner and produces the reproducibility artifact set.
# Phase 2A ships only a deterministic in-process test backend; the rootless
# container backend and the real Julia runner are Phase 2B/PR2. The interface is
# intentionally non-blocking: `backend_start` returns a handle, and progress is
# observed with `backend_status` / `backend_wait_result`, so leases and
# cancellation stay under the application service's control.

using Dates
using JSON
using SHA
using SatelliteSimPlatformStorage: AbstractExperimentStorage, get_json,
    object_metadata, list_objects, upload_directory!

const RUNNER_ARTIFACT_NAMES = ["config.snapshot.json", "result.json", "run_metadata.json"]
const ARTIFACT_INDEX_NAME = "artifacts.index.json"

"""An immutable, network-free description of one job's execution."""
struct ExecutionSpec
    job_id::String
    tenant_id::String
    release_sha::String
    image_digest::String
    normalized_config::Dict{String,Any}
    input_dir::String
    output_dir::String
    cpu_millicores::Int
    memory_mib::Int
    timeout_seconds::Int
end

"""A point-in-time view of a running execution."""
struct ExecutionStatus
    state::Symbol            # :running | :succeeded | :failed | :cancelled
    phase::Union{Nothing,String}
    message::Union{Nothing,String}
end

"""The outcome of an execution once it leaves the running state."""
struct ExecutionResult
    exit_status::Symbol      # :succeeded | :failed | :cancelled
    artifact_dir::Union{Nothing,String}
    error_message::Union{Nothing,String}
end

abstract type AbstractExecutionBackend end

backend_start(backend::AbstractExecutionBackend, spec::ExecutionSpec) =
    throw(MethodError(backend_start, (backend, spec)))
backend_status(backend::AbstractExecutionBackend, handle) =
    throw(MethodError(backend_status, (backend, handle)))
backend_wait_result(backend::AbstractExecutionBackend, handle) =
    throw(MethodError(backend_wait_result, (backend, handle)))
backend_cancel!(backend::AbstractExecutionBackend, handle) =
    throw(MethodError(backend_cancel!, (backend, handle)))
backend_probe(backend::AbstractExecutionBackend) =
    throw(MethodError(backend_probe, (backend,)))

_sha256_file(path::AbstractString) = bytes2hex(sha256(read(path)))

"""Write the deterministic reproducibility artifact set into `output_dir`."""
function write_runner_artifacts(spec::ExecutionSpec)
    mkpath(spec.output_dir)
    normalized = spec.normalized_config
    config_sha = bytes2hex(sha256(JSON.json(normalized)))
    satellites = get(get(normalized, "constellation", Dict()), "T", nothing)
    result = Dict{String,Any}(
        "deterministic" => true,
        "config_sha256" => config_sha,
        "name" => get(normalized, "name", nothing),
        "satellites" => satellites,
        "steps" => get(normalized, "steps", nothing),
    )
    metadata = Dict{String,Any}(
        "schema_version" => get(normalized, "schema_version", nothing),
        "backend" => "deterministic-test",
        "release_sha" => spec.release_sha,
        "image_digest" => spec.image_digest,
        "input_config_sha256" => config_sha,
    )
    writes = Dict(
        "config.snapshot.json" => normalized,
        "result.json" => result,
        "run_metadata.json" => metadata,
    )
    for name in RUNNER_ARTIFACT_NAMES
        open(joinpath(spec.output_dir, name), "w") do io
            write(io, JSON.json(writes[name]))
        end
    end
    index = Dict{String,Any}("artifacts" => [
        Dict{String,Any}(
            "name" => name,
            "bytes" => filesize(joinpath(spec.output_dir, name)),
            "sha256" => _sha256_file(joinpath(spec.output_dir, name)),
        ) for name in RUNNER_ARTIFACT_NAMES
    ])
    open(joinpath(spec.output_dir, ARTIFACT_INDEX_NAME), "w") do io
        write(io, JSON.json(index))
    end
    return spec.output_dir
end

"""
    verify_artifact_contract(storage, prefix) -> Vector{String}

Confirm that the stored output prefix contains exactly the runner artifact set,
that the index enumerates the three runner artifacts, and that every recorded
checksum matches the stored object. Returns the sorted stored keys.
"""
function verify_artifact_contract(storage::AbstractExperimentStorage, prefix::AbstractString)
    base = strip(String(prefix), '/')
    join_key(name) = string(base, "/", name)
    index = get_json(storage, join_key(ARTIFACT_INDEX_NAME))
    artifacts = get(index, "artifacts", nothing)
    artifacts isa AbstractVector ||
        throw(RuntimeError("EXECUTION_FAILED", "artifacts.index.json must contain an artifacts array"))
    indexed = Set{String}()
    for artifact in artifacts
        artifact isa AbstractDict ||
            throw(RuntimeError("EXECUTION_FAILED", "artifact index item must be an object"))
        name = get(artifact, "name", nothing)
        expected = get(artifact, "sha256", nothing)
        (name isa AbstractString && expected isa AbstractString) ||
            throw(RuntimeError("EXECUTION_FAILED", "artifact index item missing name or sha256"))
        push!(indexed, String(name))
        metadata = object_metadata(storage, join_key(String(name)))
        metadata.sha256 == expected ||
            throw(RuntimeError("EXECUTION_FAILED", "artifact checksum mismatch for '$(String(name))'"))
    end
    indexed == Set(RUNNER_ARTIFACT_NAMES) ||
        throw(RuntimeError("EXECUTION_FAILED", "artifact index does not describe the required runner artifacts"))
    stored = Set(object.key for object in list_objects(storage; prefix=base))
    expected_keys = Set(join_key(name) for name in vcat(RUNNER_ARTIFACT_NAMES, [ARTIFACT_INDEX_NAME]))
    stored == expected_keys ||
        throw(RuntimeError("EXECUTION_FAILED", "stored output prefix does not contain exactly the runner artifact set"))
    return sort!(collect(expected_keys))
end

# ---- deterministic test backend --------------------------------------------

mutable struct DeterministicHandle
    spec::ExecutionSpec
    behavior::Symbol
    cancelled::Bool
end

"""
A deterministic, in-process execution backend for contract and race tests. It
performs no simulation, opens no network, and reads no credentials. Per-job
behavior can be steered through `behaviors` (`:succeed`, `:fail`, `:timeout`).
"""
mutable struct DeterministicTestBackend <: AbstractExecutionBackend
    release_sha::String
    image_digest::String
    behaviors::Dict{String,Symbol}
end

function DeterministicTestBackend(;
        release_sha::AbstractString="deterministic-test-release",
        image_digest::AbstractString="sha256:" * repeat("0", 64),
        behaviors::AbstractDict=Dict{String,Symbol}())
    return DeterministicTestBackend(String(release_sha), String(image_digest),
        Dict{String,Symbol}(String(k) => Symbol(v) for (k, v) in behaviors))
end

function backend_start(backend::DeterministicTestBackend, spec::ExecutionSpec)
    behavior = get(backend.behaviors, spec.job_id, :succeed)
    behavior == :succeed && write_runner_artifacts(spec)
    return DeterministicHandle(spec, behavior, false)
end

function backend_status(::DeterministicTestBackend, handle::DeterministicHandle)
    handle.cancelled && return ExecutionStatus(:cancelled, "finalizing", "cancelled by request")
    handle.behavior == :succeed && return ExecutionStatus(:succeeded, "verifying_artifacts", nothing)
    handle.behavior == :fail && return ExecutionStatus(:failed, "simulating", "deterministic failure")
    return ExecutionStatus(:running, "simulating", nothing)  # :timeout never completes
end

function backend_wait_result(::DeterministicTestBackend, handle::DeterministicHandle)
    handle.cancelled && return ExecutionResult(:cancelled, nothing, "cancelled by request")
    handle.behavior == :succeed && return ExecutionResult(:succeeded, handle.spec.output_dir, nothing)
    handle.behavior == :fail && return ExecutionResult(:failed, nothing, "deterministic failure")
    return ExecutionResult(:failed, nothing, "execution did not complete")
end

function backend_cancel!(::DeterministicTestBackend, handle::DeterministicHandle)
    handle.cancelled = true
    return nothing
end

function backend_probe(backend::DeterministicTestBackend)
    return Dict{String,Any}(
        "kind" => "deterministic-test",
        "release_sha" => backend.release_sha,
        "image_digest" => backend.image_digest,
        "network" => false,
        "credentials" => false,
        "available" => true,
    )
end
