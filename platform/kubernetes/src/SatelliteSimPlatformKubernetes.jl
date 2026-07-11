module SatelliteSimPlatformKubernetes

using SHA

export AbstractKubernetesJobClient,
       KubernetesResources,
       KubernetesJobSpec,
       RenderedJob,
       KubernetesJobRecord,
       KubernetesSubmissionError,
       FakeKubernetesJobClient,
       render_job,
       submit_job!, get_job_status, cancel_job!, set_job_status!, list_submitted_jobs

"""An invalid or unsafe Kubernetes submission request."""
struct KubernetesSubmissionError <: Exception
    message::String
end
Base.showerror(io::IO, error::KubernetesSubmissionError) = print(io, error.message)

"""CPU/memory requests and limits expressed in portable scheduler units."""
struct KubernetesResources
    cpu_millicores::Int
    memory_mib::Int
    function KubernetesResources(cpu_millicores::Integer, memory_mib::Integer)
        1 <= cpu_millicores <= 64_000 || throw(KubernetesSubmissionError(
            "cpu_millicores must be between 1 and 64000",
        ))
        16 <= memory_mib <= 1_048_576 || throw(KubernetesSubmissionError(
            "memory_mib must be between 16 and 1048576",
        ))
        return new(Int(cpu_millicores), Int(memory_mib))
    end
end

const _LABEL_ALLOWLIST = Set([
    "app.kubernetes.io/part-of",
    "app.kubernetes.io/component",
    "satellitesim.io/tenant",
])
const _ANNOTATION_ALLOWLIST = Set([
    "satellitesim.io/request-id",
    "satellitesim.io/trace-id",
])
const _TERMINAL_STATES = Set([:succeeded, :failed, :cancelled])

"""
A restricted workload description. This is deliberately not an arbitrary PodSpec:
image, service account, resources, config key and artifact prefix are all explicit.
"""
struct KubernetesJobSpec
    job_id::String
    namespace::String
    image::String
    service_account::String
    config_key::String
    output_prefix::String
    resources::KubernetesResources
    ttl_seconds_after_finished::Int
    backoff_limit::Int
    labels::Dict{String,String}
    annotations::Dict{String,String}
end

function _dns_label(value::AbstractString, field::AbstractString; maximum::Int=63)
    text = String(value)
    occursin(r"^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", text) ||
        throw(KubernetesSubmissionError("$field must be a lowercase DNS label"))
    ncodeunits(text) <= maximum || throw(KubernetesSubmissionError("$field must be at most $maximum bytes"))
    return text
end

function _object_key(value::AbstractString, field::AbstractString)
    text = String(value)
    isempty(text) && throw(KubernetesSubmissionError("$field must not be empty"))
    startswith(text, '/') && throw(KubernetesSubmissionError("$field must be a relative object key"))
    occursin('\\', text) && throw(KubernetesSubmissionError("$field must not contain backslashes"))
    any(segment -> isempty(segment) || segment == "." || segment == "..", split(text, '/')) &&
        throw(KubernetesSubmissionError("$field contains an unsafe object-key segment"))
    return text
end

function _image(value::AbstractString)
    text = String(value)
    isempty(text) && throw(KubernetesSubmissionError("image must not be empty"))
    ncodeunits(text) <= 255 || throw(KubernetesSubmissionError("image must be at most 255 bytes"))
    occursin(r"^[A-Za-z0-9][A-Za-z0-9._/:@-]*$", text) ||
        throw(KubernetesSubmissionError("image contains unsupported characters"))
    occursin("..", text) && throw(KubernetesSubmissionError("image must not contain '..'"))
    occursin(r"(^|:)latest$", text) && throw(KubernetesSubmissionError("image must use an immutable tag or digest, not latest"))
    (occursin(':', text) || occursin("@sha256:", text)) ||
        throw(KubernetesSubmissionError("image must include an explicit tag or sha256 digest"))
    return text
end

function _metadata(input, allowlist::Set{String}, field::AbstractString)
    input === nothing && return Dict{String,String}()
    input isa AbstractDict || throw(KubernetesSubmissionError("$field must be a string dictionary"))
    output = Dict{String,String}()
    for (raw_key, raw_value) in input
        raw_key isa AbstractString || throw(KubernetesSubmissionError("$field keys must be strings"))
        raw_value isa AbstractString || throw(KubernetesSubmissionError("$field values must be strings"))
        key = String(raw_key)
        value = String(raw_value)
        key in allowlist || throw(KubernetesSubmissionError("$field key '$key' is not allowlisted"))
        isempty(value) && throw(KubernetesSubmissionError("$field value '$key' must not be empty"))
        ncodeunits(value) <= 256 || throw(KubernetesSubmissionError("$field value '$key' must be at most 256 bytes"))
        occursin(r"[\r\n\x00]", value) && throw(KubernetesSubmissionError("$field value '$key' contains control characters"))
        if field == "labels"
            ncodeunits(value) <= 63 || throw(KubernetesSubmissionError("label value '$key' must be at most 63 bytes"))
            occursin(r"^[A-Za-z0-9]([A-Za-z0-9_.-]*[A-Za-z0-9])?$", value) ||
                throw(KubernetesSubmissionError("label value '$key' is not Kubernetes-safe"))
        end
        output[key] = value
    end
    return output
end

function KubernetesJobSpec(; job_id::AbstractString,
                             namespace::AbstractString="satellitesim",
                             image::AbstractString,
                             service_account::AbstractString="satellitesim-runner",
                             config_key::AbstractString,
                             output_prefix::AbstractString,
                             resources::KubernetesResources=KubernetesResources(1000, 2048),
                             ttl_seconds_after_finished::Integer=3600,
                             backoff_limit::Integer=0,
                             labels=nothing,
                             annotations=nothing)
    raw_id = String(job_id)
    occursin(r"^[A-Za-z0-9_-]{1,128}$", raw_id) ||
        throw(KubernetesSubmissionError("job_id must use 1-128 ASCII letters, digits, '_' or '-'"))
    0 <= ttl_seconds_after_finished <= 604_800 || throw(KubernetesSubmissionError(
        "ttl_seconds_after_finished must be between 0 and 604800",
    ))
    0 <= backoff_limit <= 6 || throw(KubernetesSubmissionError("backoff_limit must be between 0 and 6"))
    return KubernetesJobSpec(
        raw_id,
        _dns_label(namespace, "namespace"),
        _image(image),
        begin
            account = _dns_label(service_account, "service_account")
            account == "default" && throw(KubernetesSubmissionError("service_account must not be the namespace default account"))
            account
        end,
        _object_key(config_key, "config_key"),
        _object_key(output_prefix, "output_prefix"),
        resources,
        Int(ttl_seconds_after_finished),
        Int(backoff_limit),
        _metadata(labels, _LABEL_ALLOWLIST, "labels"),
        _metadata(annotations, _ANNOTATION_ALLOWLIST, "annotations"),
    )
end

"""A deterministic manifest plus the Kubernetes-safe name derived from a platform job id."""
struct RenderedJob
    name::String
    manifest::Dict{String,Any}
end

"""Status captured by a Kubernetes client adapter; it never contains credentials."""
mutable struct KubernetesJobRecord
    name::String
    namespace::String
    state::Symbol
    manifest::Dict{String,Any}
    error_message::Union{Nothing,String}
end

"""Boundary for real Kubernetes clients. Production adapters own their own credential handling."""
abstract type AbstractKubernetesJobClient end

"""In-memory Kubernetes client used only by local tests and development."""
mutable struct FakeKubernetesJobClient <: AbstractKubernetesJobClient
    jobs::Dict{String,KubernetesJobRecord}
end
FakeKubernetesJobClient() = FakeKubernetesJobClient(Dict{String,KubernetesJobRecord}())

function _kubernetes_name(job_id::String)
    normalized = lowercase(replace(job_id, r"[^a-z0-9]+" => "-"))
    normalized = strip(normalized, '-')
    isempty(normalized) && (normalized = "job")
    digest = bytes2hex(sha256(codeunits(job_id)))[1:10]
    base = "satellitesim-$(normalized)"
    base = first(base, min(ncodeunits(base), 52))
    base = strip(base, '-')
    return "$base-$digest"
end

function _string_env(name::String, value::String)
    return Dict{String,Any}("name" => name, "value" => value)
end

"""
    render_job(spec) -> RenderedJob

Render a constrained `batch/v1 Job` without accepting caller-supplied PodSpec,
volumes, privileged settings, host networking, or arbitrary environment values.
"""
function render_job(spec::KubernetesJobSpec)::RenderedJob
    name = _kubernetes_name(spec.job_id)
    labels = Dict{String,Any}(
        "app.kubernetes.io/name" => "satellitesim-experiment",
        "app.kubernetes.io/part-of" => "satellitesim",
        "app.kubernetes.io/component" => "experiment-runner",
        "satellitesim.io/job-id" => name,
    )
    merge!(labels, spec.labels)
    annotations = Dict{String,Any}(spec.annotations)
    env = Any[
        _string_env("SATSIM_JOB_ID", spec.job_id),
        _string_env("SATSIM_CONFIG_KEY", spec.config_key),
        _string_env("SATSIM_OUTPUT_PREFIX", spec.output_prefix),
    ]
    resources = Dict{String,Any}(
        "requests" => Dict("cpu" => "$(spec.resources.cpu_millicores)m", "memory" => "$(spec.resources.memory_mib)Mi"),
        "limits" => Dict("cpu" => "$(spec.resources.cpu_millicores)m", "memory" => "$(spec.resources.memory_mib)Mi"),
    )
    container = Dict{String,Any}(
        "name" => "experiment",
        "image" => spec.image,
        "imagePullPolicy" => "IfNotPresent",
        "env" => env,
        "resources" => resources,
        "securityContext" => Dict(
            "allowPrivilegeEscalation" => false,
            "readOnlyRootFilesystem" => true,
            "runAsNonRoot" => true,
            "capabilities" => Dict("drop" => ["ALL"]),
            "seccompProfile" => Dict("type" => "RuntimeDefault"),
        ),
    )
    pod_spec = Dict{String,Any}(
        "restartPolicy" => "Never",
        "serviceAccountName" => spec.service_account,
        "automountServiceAccountToken" => false,
        "securityContext" => Dict("runAsNonRoot" => true),
        "containers" => Any[container],
    )
    manifest = Dict{String,Any}(
        "apiVersion" => "batch/v1",
        "kind" => "Job",
        "metadata" => Dict("name" => name, "namespace" => spec.namespace, "labels" => labels, "annotations" => annotations),
        "spec" => Dict(
            "backoffLimit" => spec.backoff_limit,
            "ttlSecondsAfterFinished" => spec.ttl_seconds_after_finished,
            "template" => Dict("metadata" => Dict("labels" => labels), "spec" => pod_spec),
        ),
    )
    return RenderedJob(name, manifest)
end

function submit_job!(client::AbstractKubernetesJobClient, rendered::RenderedJob)
    throw(MethodError(submit_job!, (client, rendered)))
end

function submit_job!(client::FakeKubernetesJobClient, rendered::RenderedJob)::KubernetesJobRecord
    haskey(client.jobs, rendered.name) && throw(KubernetesSubmissionError("Kubernetes Job '$(rendered.name)' already exists"))
    metadata = rendered.manifest["metadata"]::AbstractDict
    record = KubernetesJobRecord(rendered.name, String(metadata["namespace"]), :submitted, rendered.manifest, nothing)
    client.jobs[rendered.name] = record
    return record
end

function get_job_status(client::AbstractKubernetesJobClient, name::AbstractString)
    throw(MethodError(get_job_status, (client, name)))
end
get_job_status(client::FakeKubernetesJobClient, name::AbstractString) = get(client.jobs, String(name), nothing)

function list_submitted_jobs(client::AbstractKubernetesJobClient)
    throw(MethodError(list_submitted_jobs, (client,)))
end
function list_submitted_jobs(client::FakeKubernetesJobClient)::Vector{KubernetesJobRecord}
    records = collect(values(client.jobs))
    sort!(records; by=record -> record.name)
    return records
end

function set_job_status!(client::AbstractKubernetesJobClient, name::AbstractString, state::Symbol; error_message=nothing)
    throw(MethodError(set_job_status!, (client, name, state)))
end
function set_job_status!(client::FakeKubernetesJobClient, name::AbstractString, state::Symbol; error_message=nothing)::KubernetesJobRecord
    state in Set([:submitted, :running, :succeeded, :failed, :cancelled]) ||
        throw(KubernetesSubmissionError("unsupported Kubernetes Job state '$state'"))
    record = get_job_status(client, name)
    record === nothing && throw(KubernetesSubmissionError("Kubernetes Job '$(name)' does not exist"))
    record.state in _TERMINAL_STATES && record.state != state &&
        throw(KubernetesSubmissionError("Kubernetes Job '$(name)' is already terminal"))
    record.state = state
    record.error_message = error_message === nothing ? nothing : String(error_message)
    return record
end

function cancel_job!(client::AbstractKubernetesJobClient, name::AbstractString)
    throw(MethodError(cancel_job!, (client, name)))
end
function cancel_job!(client::FakeKubernetesJobClient, name::AbstractString)::KubernetesJobRecord
    record = get_job_status(client, name)
    record === nothing && throw(KubernetesSubmissionError("Kubernetes Job '$(name)' does not exist"))
    record.state in _TERMINAL_STATES && return record
    return set_job_status!(client, name, :cancelled)
end

end # module
