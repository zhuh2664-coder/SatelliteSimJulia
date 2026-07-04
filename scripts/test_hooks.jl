#!/usr/bin/env julia
# 增量2验证：四钩子系统
#
# 检查项：
#   A. pre_tool 钩子返回 :block → execute_tool 阻断
#   B. post_tool 钩子返回值替换结果（链式转换）
#   C. 默认截断钩子生效（4000+ 字符结果被截断）
#   D. pre/post_llm 钩子能注册且被调用
#   E. clear_hooks! 后钩子不生效；ensure_default_hooks! 幂等
#
# 用法：julia --project=src/lab scripts/test_hooks.jl

using SatelliteSimLab
using SatelliteSimLab: execute_tool, PreToolCtx, PostToolCtx, PreLLMCtx, PostLLMCtx,
                       register_hook!, clear_hooks!, run_hooks!, ensure_default_hooks!,
                       default_truncation_hook, HOOKS

const _KEY = get(ENV, "DEEPSEEK_API_KEY", "dummy-key-for-selftest")
ok = 0; fail = 0
function check(name, cond)
    global ok, fail
    if cond; ok += 1; println("  ✓ $name")
    else; fail += 1; println("  ✗ FAIL: $name"); end
end

# 构造 agent（会触发 ensure_default_hooks! 注册截断钩子）
agent = SimAgent(LLMProvider(key=_KEY))

println("=== C. 默认截断钩子生效 ===")
# list_available 返回的 JSON 通常 < 4000，构造一个长结果测截断
# 直接测 default_truncation_hook（post 钩子签名 fn(ctx, value)）
short_ctx = PostToolCtx("x", Dict(), "短结果", agent)
check("短结果不截断", default_truncation_hook(short_ctx, "短结果") == "短结果")
long_str = "x" ^ 5000
long_ctx = PostToolCtx("x", Dict(), long_str, agent)
truncated = default_truncation_hook(long_ctx, long_str)
check("长结果被截断（含截断标记）", occursin("...(截断)", truncated))
check("截断后 ≤ 4000 字符 + 标记", length(truncated) <= 4000 + 20)
# 字符安全（无 StringIndexError）
check("截断无多字节异常（纯 ASCII 此处）", isa(truncated, String))

println("\n=== A. pre_tool 钩子阻断 ===")
clear_hooks!()  # 清掉默认，避免干扰
register_hook!(:pre_tool) do ctx
    ctx.tool == "blocked_one" ? :block : nothing
end
r = execute_tool("blocked_one", Dict(), agent)
check("被阻断的工具返回阻断提示", occursin("被 pre_tool 钩子阻断", r))
# 非阻断的工具仍正常执行
r2 = execute_tool("list_available", Dict("what"=>"constellations"), agent)
check("非阻断工具正常执行", !occursin("阻断", r2) && occursin("constellations", r2))

println("\n=== B. post_tool 钩子链式转换 ===")
clear_hooks!()
register_hook!(:post_tool) do ctx, value
    "[TAG1]" * value
end
register_hook!(:post_tool) do ctx, value
    "[TAG2]" * value   # 第二个钩子接收第一个钩子的输出
end
r3 = execute_tool("list_available", Dict("what"=>"constellations"), agent)
check("两个 post 钩子链式生效", startswith(r3, "[TAG2][TAG1]"))

println("\n=== D. pre_llm / post_llm 钩子注册与调用 ===")
clear_hooks!()
called_pre = Ref(false); called_post = Ref(false)
register_hook!(:pre_llm) do ctx; called_pre[] = true; nothing; end
register_hook!(:post_llm) do ctx, value; called_post[] = true; nothing; end
# 手动触发（不走真实 LLM）
proceed, _ = run_hooks!(:pre_llm, PreLLMCtx(Dict{String,Any}[], agent))
check("pre_llm 钩子被调用", called_pre[])
run_hooks!(:post_llm, PostLLMCtx(nothing, agent))
check("post_llm 钩子被调用", called_post[])

println("\n=== E. clear_hooks! + 幂等 ensure_default_hooks! ===")
clear_hooks!()
check("clear 后 post_tool 为空", isempty(HOOKS[:post_tool]))
ensure_default_hooks!()
n1 = length(HOOKS[:post_tool])
ensure_default_hooks!()  # 再调一次
n2 = length(HOOKS[:post_tool])
check("ensure_default_hooks! 幂等（不重复注册）", n1 == 1 && n2 == 1)

println("\n" * "=" ^ 48)
println("HOOKS SYSTEM: $ok passed, $fail failed")
println("=" ^ 48)
exit(fail == 0 ? 0 : 1)
