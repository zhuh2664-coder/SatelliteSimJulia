module SatelliteSimPlatformScheduler

using Dates
using PlatformRunner
using SatelliteSimPlatformStorage
using UUIDs

export AbstractExperimentScheduler,
       FakeScheduler,
       JobRecord,
       SchedulerError,
       submit!, run_next!, run_all!, get_job, list_jobs

"""An invalid scheduler request or a violated runner/artifact contract."""
struct SchedulerError <: Exception
    message::String
end
Base.showerror(io::IO, error::SchedulerError) = print(io, error.message)

"""A durable-in-memory job record owned by a scheduler implementation."""
mutable struct JobRecord
    id::String
    config_key::String
    output_prefix::String
    state::Symbol
    submitted_at_utc::DateTime
    started_at_utc::Union{Nothing,DateTime}
    finished_at_utc::Union{Nothing,DateTime}
    artifact_keys::Vector{String}
    error_message::Union{Nothing,String}
end

"""Abstract scheduler boundary; cloud schedulers may implement the same API later."""
abstract type AbstractExperimentScheduler end

"""
    FakeScheduler(storage; work_root=mktempdir())

A deterministic local scheduler for contract tests and development. It persists
configuration/result objects through `storage`, but never contacts Kubernetes,
queues, or a network service.
"""
mutable struct FakeScheduler{S<:AbstractExperimentStorage} <: AbstractExperimentScheduler
    storage::S
    work_root::String
    jobs::Dict{String,JobRecord}
    queue::Vector{String}
end

function FakeScheduler(storage::S; work_root::AbstractString=mktempdir()) where {S<:AbstractExperimentStorage}
    return FakeScheduler{S}(storage, abspath(mkpath(work_root)), Dict{String,JobRecord}(), String[])
end

function _job_id(value::AbstractString)::String
    id = String(value)
    occursin(r"^[A-Za-z0-9_-]{1,128}$", id) ||
        throw(SchedulerError("job id must use 1-128 ASCII letters, digits, '_' or '-'"))
    return id
end

_join_key(prefix::AbstractString, name::AbstractString) = string(strip(String(prefix), '/'), "/", name)

function _require_output_prefix(prefix::AbstractString)::String
    text = strip(String(prefix), '/')
    isempty(text) && throw(SchedulerError("output_prefix must not be empty"))
    # Delegate full traversal and separator validation to the storage interface.
    try
        list_objects(LocalFilesystemStorage(mktempdir()); prefix=text)
    catch error
        error isa StorageKeyError && throw(SchedulerError(error.message))
        rethrow()
    end
    return text
end

function submit!(scheduler::AbstractExperimentScheduler, config_key::AbstractString; kwargs...)
    throw(MethodError(submit!, (scheduler, config_key)))
end

"""Queue an already stored JSON config and return a local job record."""
function submit!(scheduler::FakeScheduler, config_key::AbstractString;
                 output_prefix::Union{Nothing,AbstractString}=nothing,
                 job_id::Union{Nothing,AbstractString}=nothing)::JobRecord
    has_object(scheduler.storage, config_key) || throw(SchedulerError("config object '$config_key' does not exist"))
    id = _job_id(job_id === nothing ? string(uuid4()) : job_id)
    haskey(scheduler.jobs, id) && throw(SchedulerError("job '$id' already exists"))
    prefix = _require_output_prefix(output_prefix === nothing ? "jobs/$id" : output_prefix)
    record = JobRecord(id, String(config_key), prefix, :queued, now(UTC), nothing, nothing, String[], nothing)
    scheduler.jobs[id] = record
    push!(scheduler.queue, id)
    return record
end

function get_job(scheduler::AbstractExperimentScheduler, id::AbstractString)
    throw(MethodError(get_job, (scheduler, id)))
end

function get_job(scheduler::FakeScheduler, id::AbstractString)::Union{JobRecord,Nothing}
    return get(scheduler.jobs, String(id), nothing)
end

function list_jobs(scheduler::AbstractExperimentScheduler)::Vector{JobRecord}
    throw(MethodError(list_jobs, (scheduler,)))
end

function list_jobs(scheduler::FakeScheduler)::Vector{JobRecord}
    records = collect(values(scheduler.jobs))
    sort!(records; by=record -> record.submitted_at_utc)
    return records
end

function _expected_artifact_names()
    return Set(["config.snapshot.json", "result.json", "run_metadata.json", "artifacts.index.json"])
end

function _verify_artifact_contract(storage::AbstractExperimentStorage, prefix::String)::Vector{String}
    index_key = _join_key(prefix, "artifacts.index.json")
    index = get_json(storage, index_key)
    artifacts = get(index, "artifacts", nothing)
    artifacts isa AbstractVector || throw(SchedulerError("artifacts.index.json must contain an artifacts array"))

    indexed_names = Set{String}()
    for artifact in artifacts
        artifact isa AbstractDict || throw(SchedulerError("artifact index item must be an object"))
        name = get(artifact, "name", nothing)
        expected_hash = get(artifact, "sha256", nothing)
        name isa AbstractString || throw(SchedulerError("artifact index item is missing name"))
        expected_hash isa AbstractString || throw(SchedulerError("artifact index item is missing sha256"))
        push!(indexed_names, String(name))
        metadata = object_metadata(storage, _join_key(prefix, String(name)))
        metadata.sha256 == expected_hash || throw(SchedulerError("artifact checksum mismatch for '$name'"))
    end
    required_indexed_names = setdiff(
        _expected_artifact_names(),
        Set(["artifacts.index.json"]),
    )
    indexed_names == required_indexed_names ||
        throw(SchedulerError("artifact index does not describe the required runner artifacts"))

    keys = [object.key for object in list_objects(storage; prefix=prefix)]
    expected_keys = Set(_join_key(prefix, name) for name in _expected_artifact_names())
    Set(keys) == expected_keys || throw(SchedulerError("stored output prefix does not contain exactly the runner artifact set"))
    return sort!(collect(expected_keys))
end

function run_next!(scheduler::AbstractExperimentScheduler)
    throw(MethodError(run_next!, (scheduler,)))
end

"""Execute one queued job synchronously using `PlatformRunner` and upload its artifacts."""
function run_next!(scheduler::FakeScheduler)::Union{JobRecord,Nothing}
    isempty(scheduler.queue) && return nothing
    id = popfirst!(scheduler.queue)
    job = scheduler.jobs[id]
    job.state == :queued || throw(SchedulerError("job '$id' is not queued"))
    job.state = :running
    job.started_at_utc = now(UTC)

    try
        raw = get_json(scheduler.storage, job.config_key)
        mktempdir(scheduler.work_root; prefix="job-$id-") do local_directory
            output_directory = joinpath(local_directory, "artifacts")
            run_platform_experiment(raw; output_dir=output_directory)
            upload_directory!(scheduler.storage, job.output_prefix, output_directory)
        end
        job.artifact_keys = _verify_artifact_contract(scheduler.storage, job.output_prefix)
        job.state = :succeeded
        job.error_message = nothing
    catch error
        job.state = :failed
        job.error_message = sprint(showerror, error, catch_backtrace())
    finally
        job.finished_at_utc = now(UTC)
    end
    return job
end

function run_all!(scheduler::AbstractExperimentScheduler)::Vector{JobRecord}
    throw(MethodError(run_all!, (scheduler,)))
end

function run_all!(scheduler::FakeScheduler)::Vector{JobRecord}
    completed = JobRecord[]
    while true
        job = run_next!(scheduler)
        job === nothing && return completed
        push!(completed, job)
    end
end

end # module
