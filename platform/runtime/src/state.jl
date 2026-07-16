# Job state machine (design section 6). Public states are what callers observe;
# internal phases are progress detail attached to a running job and never widen
# the public contract.

const PUBLIC_STATES = Set(["queued", "running", "succeeded", "failed", "cancelled"])
const TERMINAL_STATES = Set(["succeeded", "failed", "cancelled"])
const INTERNAL_PHASES = Set([
    "admission",
    "waiting_for_worker",
    "materializing_input",
    "starting_runner",
    "simulating",
    "verifying_artifacts",
    "uploading_artifacts",
    "finalizing",
])

const _ALLOWED_TRANSITIONS = Dict{String,Set{String}}(
    "queued" => Set(["running", "cancelled"]),
    "running" => Set(["succeeded", "failed", "cancelled"]),
    "succeeded" => Set{String}(),
    "failed" => Set{String}(),
    "cancelled" => Set{String}(),
)

is_public_state(state::AbstractString) = String(state) in PUBLIC_STATES
is_terminal(state::AbstractString) = String(state) in TERMINAL_STATES

"""Whether a direct public-state transition is legal."""
function can_transition(from::AbstractString, to::AbstractString)::Bool
    allowed = get(_ALLOWED_TRANSITIONS, String(from), nothing)
    allowed === nothing && return false
    return String(to) in allowed
end

"""Guard an internal transition; an illegal transition is a runtime invariant bug."""
function assert_transition(from::AbstractString, to::AbstractString)
    can_transition(from, to) || throw(RuntimeError(
        "INTERNAL_ERROR",
        "illegal job state transition from '$(String(from))' to '$(String(to))'",
    ))
    return nothing
end

function assert_phase(phase::AbstractString)
    String(phase) in INTERNAL_PHASES || throw(RuntimeError(
        "INTERNAL_ERROR",
        "unknown internal phase '$(String(phase))'",
    ))
    return nothing
end
