#!/usr/bin/env julia
# 增量3验证：三层会话记忆（Index/Topic/Transcripts 落盘 JSON）
#
# 检查项：
#   A. record_result! 写 Layer 3（transcript.jsonl）+ Layer 1（index.jsonl + 内存）
#   B. 每条 Layer 1 摘要 ≤150 字符；多字节安全截断
#   C. load_topic 读写 Layer 2；grep_transcript 查 Layer 3
#   D. 跨进程恢复：新进程 load_memory 同一 session_id，index 完整
#   E. consolidate! 去重整理
#
# 用法：julia --project=src/lab scripts/test_memory.jl

using SatelliteSimLab
using JSON

ok = 0; fail = 0
function check(name, cond)
    global ok, fail
    if cond
        ok += 1; println("  ✓ $name")
    else
        fail += 1; println("  ✗ FAIL: $name")
    end
end

# 用唯一 session id 隔离
SID = "memtest_$(round(Int, time()))"

println("=== A. record_result! 写三层 ===")
mem = SessionMemory(session_id=SID)
# 清空可能的残留（幂等）
isfile(mem.transcript_path) && rm(mem.transcript_path)
idx_path = replace(mem.transcript_path, "transcript.jsonl"=>"index.jsonl")
isfile(idx_path) && rm(idx_path)

record_result!(mem, "scan_parameter", Dict("param"=>"alt_km","values"=>[550,800]), "{\"coverage\":0.5}")
record_result!(mem, "run_simulation", Dict("constellation"=>"iridium","topology"=>"robust","propagator"=>"fast"), "{\"coverage\":0.9}")
record_result!(mem, "compare_constellations", Dict("constellations"=>["iridium","starlink"]), "{\"diff\":0.1}")
record_result!(mem, "list_available", Dict("what"=>"all"), "{}")  # 不入 Layer 1

check("Layer 3 transcript.jsonl 有 4 行（全部记录）",  countlines(mem.transcript_path) == 4)
check("Layer 1 index.jsonl 有 3 行（list_available 不入）", countlines(idx_path) == 3)
check("Layer 1 内存 index 长度 3",                     length(mem.index) == 3)

println("\n=== B. Layer 1 摘要 ≤150 字符 + 多字节安全 ===")
# 构造超长 compare_constellations
record_result!(mem, "compare_constellations",
               Dict("constellations"=>[string("星座",i) for i in 1:80]), "{}")
check("所有 index 条目 ≤150 字符", all(length(e) <= 150 for e in mem.index))
check("超长条目含截断标记",          any(occursin("...", e) for e in mem.index))

println("\n=== C. Layer 2 topic + grep_transcript ===")
write_topic!(mem, "alt_study", "# 高度扫描结论\n550km 覆盖 95%, 800km 覆盖 98%")
content = load_topic(mem, "alt_study")
check("load_topic 读回正确",       occursin("550km 覆盖", content))
check("load_topic 不存在返回空",   load_topic(mem, "nonexistent") == "")
hits = grep_transcript(mem, "iridium")
check("grep_transcript 命中",       !isempty(hits))
check("grep 命中行是 JSON",         startswith(first(hits), "{"))

println("\n=== D. 跨进程恢复（新内存对象 load 同一 session_id）===")
mem2 = SessionMemory(session_id=SID)
check("新对象恢复 Layer 1 index 完整", length(mem2.index) == length(mem.index))
check("恢复的 index 首条一致",         mem2.index[1] == mem.index[1])

println("\n=== E. consolidate! 去重 ===")
# 再记一条与第一条同 key 的记录（不同 result）
record_result!(mem, "scan_parameter", Dict("param"=>"alt_km","values"=>[550,800]), "{\"coverage\":0.7}")
n_before = length(mem.index)
n_after = consolidate!(mem)
check("consolidate 去重后条数 ≤ 之前", n_after <= n_before)
check("consolidate 后仍 ≤150 字符",    all(length(e) <= 150 for e in mem.index))

println("\n=== memory_context 注入 prompt ===")
ctx = memory_context(mem2)
check("memory_context 非空（有摘要）",  !isempty(ctx))
check("含「实验摘要」标识",            occursin("实验摘要", ctx))

# 清理测试数据
rm(joinpath("data", "sessions", SID); recursive=true, force=true)

println("\n" * "=" ^ 48)
println("THREE-TIER MEMORY: $ok passed, $fail failed")
println("=" ^ 48)
exit(fail == 0 ? 0 : 1)
