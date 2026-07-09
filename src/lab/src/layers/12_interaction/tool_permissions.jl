# ===== AI tool permissions / HITL =====
#
# 轻量权限层：按工具名决定 allow/deny/ask。ask 表示需要人工批准（HITL），
# 批准记录保存在 agent 会话内，只对同一 tool+args 生效。

export ToolPermissionPolicy, tool_permission_decision, approve_tool_call!,
       clear_tool_approvals!, permission_guard_hook, register_default_tool_permissions!

Base.@kwdef struct ToolPermissionPolicy
    default::Symbol = :allow
    rules::Dict{String,Symbol} = Dict{String,Symbol}()
end

const _DEFAULT_TOOL_PERMISSIONS_REGISTERED = Ref(false)
const _TOOL_PERMISSION_POLICIES = IdDict{Any,ToolPermissionPolicy}()
const _TOOL_APPROVALS = IdDict{Any,Set{String}}()

function _tool_call_key(tool::String, args::AbstractDict)::String
    return stable_digest(Dict("tool" => tool, "args" => Dict(string(k) => v for (k, v) in args)))
end

function _tool_policy(agent)::ToolPermissionPolicy
    agent === nothing && return ToolPermissionPolicy()
    return get(_TOOL_PERMISSION_POLICIES, agent, ToolPermissionPolicy())
end

function _set_tool_permission_policy!(agent, policy::ToolPermissionPolicy)
    _TOOL_PERMISSION_POLICIES[agent] = policy
    return policy
end

function tool_permission_decision(agent, tool::String, args::AbstractDict)::Symbol
    policy = _tool_policy(agent)
    decision = get(policy.rules, tool, policy.default)
    decision in (:allow, :deny, :ask) || error("unknown tool permission decision: $decision")
    if decision == :ask
        approved = get(_TOOL_APPROVALS, agent, Set{String}())
        _tool_call_key(tool, args) in approved && return :allow
    end
    return decision
end

function approve_tool_call!(agent, tool::String, args::AbstractDict)
    approvals = get!(_TOOL_APPROVALS, agent, Set{String}())
    push!(approvals, _tool_call_key(tool, args))
    if hasproperty(agent, :memory)
        record_ledger_event!(agent.memory, Dict{String,Any}(
            "event_type" => "tool_permission",
            "tool" => tool,
            "args_hash" => stable_digest(args),
            "decision" => "approved",
        ))
    end
    return true
end

function clear_tool_approvals!(agent)
    haskey(_TOOL_APPROVALS, agent) && empty!(_TOOL_APPROVALS[agent])
    return nothing
end

function permission_guard_hook(ctx::PreToolCtx)
    decision = tool_permission_decision(ctx.agent, ctx.tool, ctx.args)
    decision == :allow && return nothing

    if hasproperty(ctx.agent, :memory)
        record_ledger_event!(ctx.agent.memory, Dict{String,Any}(
            "event_type" => "tool_permission",
            "tool" => ctx.tool,
            "args_hash" => stable_digest(ctx.args),
            "decision" => string(decision),
        ))
    end

    decision == :deny && return (:block, "permission denied for tool $(ctx.tool)")
    return (:block, "human approval required for tool $(ctx.tool); call approve_tool_call! with the same tool and args")
end

function register_default_tool_permissions!()
    _DEFAULT_TOOL_PERMISSIONS_REGISTERED[] && return nothing
    register_hook!(:pre_tool, permission_guard_hook)
    _DEFAULT_TOOL_PERMISSIONS_REGISTERED[] = true
    return nothing
end
