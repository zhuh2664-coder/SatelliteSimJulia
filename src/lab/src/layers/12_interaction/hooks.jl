# ===== 钩子系统（借鉴 Claude Code 的 PreToolUse/PostToolUse 事件钩子）=====
#
# 把横切关注点（截断、记忆记录、参数审计）从 execute_tool 的 if-elseif 与
# run_agent 的循环里解耦。借鉴 Claude Code 泄露源码的 4 个核心生命周期钩子，
# 不贪多（完整版有 25+，本项目工具少，4 个覆盖 80% 价值）。
#
# 设计：
#   - 钩子 = Function，注册到 HOOKS[event] 向量
#   - pre 钩子返回 :block 可阻断（execute_tool 不执行，返回阻断提示）
#   - post 钩子返回值替换原结果（用于截断/格式化/记录）
#   - 零注册表：用 Dict{Symbol,Vector{Function}}，多重分派不适用（钩子是运行时动态注册）

export HookContext, PreToolCtx, PostToolCtx, PreLLMCtx, PostLLMCtx,
       register_hook!, clear_hooks!, run_hooks!, ensure_default_hooks!,
       default_post_tool_hook, default_truncation_hook

# ─── 钩子上下文类型 ───
# 每个 hook 接收一个 ctx，携带该事件的相关数据 + agent 引用（可读会话状态）。

"""钩子上下文抽象基类。每个生命周期事件有自己的 ctx 子类型。"""
abstract type HookContext end

"""PreToolUse：工具执行前。pre 钩子返回 :block 可阻断执行。"""
struct PreToolCtx <: HookContext
    tool::String
    args::Dict{String,Any}
    agent::Any   # SimAgent（用 Any 避免 hooks.jl ↔ agent.jl 循环依赖）
end

"""PostToolUse：工具执行后。post 钩子返回值替换原结果字符串。"""
struct PostToolCtx <: HookContext
    tool::String
    args::Dict{String,Any}
    result::String
    agent::Any
end

"""PreLLM：调 LLM 前。可读/改 messages。"""
struct PreLLMCtx <: HookContext
    messages::Vector{Dict{String,Any}}
    agent::Any
end

"""PostLLM：LLM 返回后。可读 response。"""
struct PostLLMCtx <: HookContext
    response::Any   # AssistantMessage
    agent::Any
end

# ─── 钩子注册表 ───
# 模块级全局。每个事件一个函数向量，按注册顺序执行。
const HOOKS = Dict{Symbol,Vector{Function}}(
    :pre_tool  => Function[],
    :post_tool => Function[],
    :pre_llm   => Function[],
    :post_llm  => Function[],
)

"""
    register_hook!(event::Symbol, fn::Function)

注册钩子。event ∈ {:pre_tool, :post_tool, :pre_llm, :post_llm}。
- pre 钩子签名：fn(ctx::PreToolCtx) -> 返回 :block 阻断，否则放行
- post 钩子签名：fn(ctx::PostToolCtx) -> 返回值替换原 result

```julia
# 注册一个 post_tool 钩子，把结果截断到 200 字符
register_hook!(:post_tool) do ctx
    length(ctx.result) > 200 ? ctx.result[1:200] * "..." : ctx.result
end
```
"""
function register_hook!(event::Symbol, fn::Function)
    haskey(HOOKS, event) || error("未知钩子事件: $event（应为 :pre_tool/:post_tool/:pre_llm/:post_llm）")
    push!(HOOKS[event], fn)
    return fn
end

# 支持 do-block 语法：register_hook!(:event) do ctx ... end
# Julia do-block 把闭包作为第一个参数传入，故提供 (fn, event) 顺序。
register_hook!(fn::Function, event::Symbol) = register_hook!(event, fn)

"""清空所有钩子（测试用）。同时重置默认钩子注册标记，以便重新注册。"""
function clear_hooks!()
    for k in keys(HOOKS); empty!(HOOKS[k]); end
    _DEFAULT_HOOKS_REGISTERED[] = false
    isdefined(@__MODULE__, :_DEFAULT_TOOL_GUARDS_REGISTERED) && (_DEFAULT_TOOL_GUARDS_REGISTERED[] = false)
    isdefined(@__MODULE__, :_DEFAULT_LEDGER_HOOKS_REGISTERED) && (_DEFAULT_LEDGER_HOOKS_REGISTERED[] = false)
    return nothing
end

"""
    run_hooks!(event::Symbol, ctx::HookContext) -> (proceed::Bool, value)

按注册顺序执行钩子。
- pre 类钩子（:pre_tool/:pre_llm）：签名 fn(ctx)，任一返回 :block 则 proceed=false。
- post 类钩子（:post_tool/:post_llm）：签名 fn(ctx, value) -> new_value，链式转换。
  value 从 ctx 的初始值（如 ctx.result）开始，每个钩子接收上一钩子输出并返回新值。
  返回 nothing 表示保留当前 value（不改）。
"""
function run_hooks!(event::Symbol, ctx::HookContext)
    value = nothing
    proceed = true
    is_post = event in (:post_tool, :post_llm)
    # post 类的初始 value 取自 ctx 的主载荷字段
    if is_post
        value = ctx isa PostToolCtx ? ctx.result :
                ctx isa PostLLMCtx ? (ctx.response === nothing ? "" : string(ctx.response)) : ""
    end
    for fn in HOOKS[event]
        ret = is_post ? fn(ctx, value) : fn(ctx)
        if !is_post
            if ret === :block
                proceed = false
                value = "blocked by hook"
                break
            elseif ret isa Tuple && length(ret) >= 1 && ret[1] === :block
                proceed = false
                value = length(ret) >= 2 ? string(ret[2]) : "blocked by hook"
                break
            end
        else  # post 类：返回值替换 value（nothing 表示不改）
            ret !== nothing && (value = ret)
        end
    end
    return proceed, value
end

# ─── 默认 post_tool 钩子：结果截断 ───
# 把原来写死在 run_agent 里的 [1:4000] 截断逻辑改为可注册的默认钩子。

"""默认截断阈值（字符数）。与原写死值一致，保持行为不变。"""
const DEFAULT_TRUNCATE_CHARS = 4000

"""
    default_truncation_hook(ctx::PostToolCtx, value::AbstractString) -> String

默认 post_tool 钩子：把超长结果截断到 DEFAULT_TRUNCATE_CHARS 字符。
post 钩子签名 fn(ctx, value)，value 为链式累加值（此处即当前结果）。
（字符安全截断：用 collect 避免在 UTF-8 多字节边界切断）
"""
function default_truncation_hook(ctx::PostToolCtx, value::AbstractString)
    length(value) <= DEFAULT_TRUNCATE_CHARS && return value
    chars = collect(value)
    return String(chars[1:DEFAULT_TRUNCATE_CHARS]) * "...(截断)"
end

"""默认 post_tool 钩子别名（截断）。注册时用。"""
default_post_tool_hook = default_truncation_hook

# 默认钩子是否已注册（幂等保护，避免多 agent 重复注册）
const _DEFAULT_HOOKS_REGISTERED = Ref(false)

"""
    ensure_default_hooks!()

幂等注册默认 post_tool 截断钩子。在 SimAgent 构造时调用，
保证「结果截断到 4000 字符」的既有行为不丢（原写死在 run_agent 里）。
多次调用安全（只注册一次）。
"""
function ensure_default_hooks!()
    _DEFAULT_HOOKS_REGISTERED[] && return
    push!(HOOKS[:post_tool], default_truncation_hook)
    _DEFAULT_HOOKS_REGISTERED[] = true
end
