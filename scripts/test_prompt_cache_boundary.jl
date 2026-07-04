#!/usr/bin/env julia
# 验证 System Prompt 缓存边界（借鉴 Claude Code SYSTEM_PROMPT_DYNAMIC_BOUNDARY）。
#
# 检查项：
#   1. 稳定前缀字节级固定（两个不同动态区的 agent，稳定前缀字节必须一致 → 缓存命中前提）
#   2. 动态后缀承载 session_goal / scanned_params
#   3. scanned_params 记录正确，多字节 UTF-8 截断安全（≤150 字符）
#   4. 非扫描工具（list_available）不污染扫描记忆
#   5. 初始 messages[1] = STABLE + BOUNDARY
#
# 用法：julia --project=src/lab scripts/test_prompt_cache_boundary.jl

using SatelliteSimLab
using SatelliteSimLab: SYSTEM_PROMPT_STABLE, SYSTEM_PROMPT_DYNAMIC_BOUNDARY,
                       system_prompt, _record_scanned!

# 构造 LLMProvider 不会实际发请求（本脚本只测 prompt 拼装），用 dummy key 抑制 warning。
const _KEY = get(ENV, "DEEPSEEK_API_KEY", "dummy-key-for-selftest")
# 用临时 session id 隔离，避免污染默认会话记忆
const _SID = "prompttest_$(round(Int, time()))"

a  = SimAgent(LLMProvider(key=_KEY); session_goal="", session_id=_SID)
a2 = SimAgent(LLMProvider(key=_KEY); session_goal="对比 Iridium 与 Starlink 覆盖", session_id=_SID)

sp  = system_prompt(a)
sp2 = system_prompt(a2)

# 1. 字节级前缀一致性（prompt cache 命中的硬条件）
nbytes = sizeof(SYSTEM_PROMPT_STABLE)
@assert view(codeunits(sp),  1:nbytes) == codeunits(SYSTEM_PROMPT_STABLE)
@assert view(codeunits(sp2), 1:nbytes) == codeunits(SYSTEM_PROMPT_STABLE)

# 2. 动态后缀内容
@assert occursin(SYSTEM_PROMPT_DYNAMIC_BOUNDARY, sp)
@assert occursin("当前时间", sp)
@assert occursin("对比 Iridium 与 Starlink 覆盖", sp2)

# 3. 三层记忆 Layer 1 注入 prompt 动态区
_record_scanned!(a2, "scan_parameter", Dict("param"=>"alt_km","values"=>[550,800,1200]), "{}")
@assert occursin("扫描 alt_km=550/800/1200", system_prompt(a2))

# 4. _record_scanned! + 多字节截断（新签名含 result 第4参，写三层记忆）
_record_scanned!(a2, "scan_parameter",       Dict("param"=>"inc_deg","values"=>[53,87]), "{}")
_record_scanned!(a2, "run_simulation",       Dict("constellation"=>"iridium","topology"=>"robust","propagator"=>"fast"), "{}")
_record_scanned!(a2, "compare_constellations", Dict("constellations"=>[string("星座",i) for i in 1:60]), "{}")
@assert all(length(e) <= 150 for e in a2.scanned_params)
@assert any(occursin("扫描 inc_deg", e) for e in a2.scanned_params)
@assert any(occursin("仿真 iridium", e) for e in a2.scanned_params)

# 5. list_available 不记入扫描记忆
n_before = length(a2.scanned_params)
_record_scanned!(a2, "list_available", Dict("what"=>"all"), "{}")
@assert length(a2.scanned_params) == n_before

# 6. 初始 system 消息 = STABLE + BOUNDARY（构造时无动态数据）
@assert a.messages[1]["content"] == SYSTEM_PROMPT_STABLE * SYSTEM_PROMPT_DYNAMIC_BOUNDARY

println("=" ^ 56)
println("PROMPT-CACHE BOUNDARY: ALL CHECKS PASSED")
println("=" ^ 56)
println("  稳定前缀: $(length(SYSTEM_PROMPT_STABLE)) 字符 / $nbytes 字节（字节级固定）")
println("  动态边界标记: $(length(SYSTEM_PROMPT_DYNAMIC_BOUNDARY)) 字符")
println("  含 session_goal 完整 prompt: $(length(sp2)) 字符")
println("  scanned_params 记录: $(length(a2.scanned_params)) 条（均 ≤150 字符）")
