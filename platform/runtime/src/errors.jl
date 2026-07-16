# Public error taxonomy and stable transport envelope.
#
# The application service raises `RuntimeError` with a bounded, public message.
# A transport adapter (FastMCP in a later phase) performs a one-to-one mapping
# to the wire envelope and must not reinterpret these codes.

"""Every public error code defined by the runtime contract (design section 7)."""
const RUNTIME_ERROR_CODES = Set([
    "UNAUTHENTICATED",
    "FORBIDDEN",
    "INVALID_ARGUMENT",
    "SCHEMA_UNSUPPORTED",
    "RUNTIME_POLICY_REJECTED",
    "QUOTA_EXCEEDED",
    "IDEMPOTENCY_CONFLICT",
    "JOB_NOT_FOUND",
    "JOB_NOT_CANCELLABLE",
    "ARTIFACT_NOT_READY",
    "ARTIFACT_NOT_FOUND",
    "ARTIFACT_TOO_LARGE",
    "WORKER_UNAVAILABLE",
    "WORKER_LOST",
    "EXECUTION_TIMEOUT",
    "EXECUTION_FAILED",
    "STORAGE_UNAVAILABLE",
    "INTERNAL_ERROR",
])

"""
Codes that may be marked retryable without changing the request or external
state: only availability, lease, timeout and storage classes qualify.
"""
const RETRYABLE_ERROR_CODES = Set([
    "WORKER_UNAVAILABLE",
    "WORKER_LOST",
    "EXECUTION_TIMEOUT",
    "STORAGE_UNAVAILABLE",
])

"""A public, bounded runtime error carrying a stable code and retryability flag."""
struct RuntimeError <: Exception
    code::String
    message::String
    retryable::Bool
    function RuntimeError(code::AbstractString, message::AbstractString;
                         retryable::Union{Nothing,Bool}=nothing)
        code_text = String(code)
        code_text in RUNTIME_ERROR_CODES ||
            throw(ArgumentError("unknown runtime error code: $code_text"))
        flag = retryable === nothing ? (code_text in RETRYABLE_ERROR_CODES) : retryable
        return new(code_text, String(message), flag)
    end
end

Base.showerror(io::IO, error::RuntimeError) = print(io, "$(error.code): $(error.message)")

"""Build the stable success envelope for a request."""
function success_envelope(request_id::AbstractString, data)
    return Dict{String,Any}(
        "ok" => true,
        "request_id" => String(request_id),
        "data" => data,
    )
end

"""Build the stable error envelope for a request from a `RuntimeError`."""
function error_envelope(request_id::AbstractString, error::RuntimeError)
    return Dict{String,Any}(
        "ok" => false,
        "request_id" => String(request_id),
        "error" => Dict{String,Any}(
            "code" => error.code,
            "message" => error.message,
            "retryable" => error.retryable,
        ),
    )
end
