# ===== 三层会话记忆（借鉴 Claude Code 的 Index / Topic / Transcripts 分层）=====
#
# 解决问题：长扫描会话的上下文爆炸 + 「做过什么」的跨会话持久化。
#
# 三层结构（按访问模式分存储，对齐 cache.jl/checkpoint.jl 的 data/ 落盘风格）：
#   Layer 1 - Index（index.jsonl）：始终加载，每条 ≤150 字符。会话开始读入内存，
#             注入 System Prompt 动态区。类比图书馆卡片目录。
#   Layer 2 - Topic（topics/<name>.md）：按需加载，整文件读入。Agent 主动查阅时取。
#             类比从书架取书。本层默认不写（预留扩展点）。
#   Layer 3 - Transcript（transcript.jsonl）：append-only，永不主动加载，仅按需 grep。
#             每次工具调用追加一条。类比地下档案室原始卷宗。
#
# 落盘位置：data/sessions/<session_id>/{index.jsonl, topics/, transcript.jsonl}
#
# 设计原则（对齐 Claude Code arXemXtech 逆向）：
#   - Index 的 150 字符约束是「全量进上下文也不肉痛」的成本红线
#   - Transcript append-only，保证可追溯、利于 grep
#   - 不做 autoDream（24/7 常驻整理），用户显式调 consolidate! 即可

using JSON
using Dates

export SessionMemory, memory_context, load_topic, write_topic!, record_result!,
       load_memory, consolidate!, grep_transcript, DEFAULT_SESSION_ID

const DEFAULT_SESSION_ID = "default"

# ─── SessionMemory ───

"""
    SessionMemory

三层会话记忆。Layer 1（index）常驻内存；Layer 2/3 落盘按需。

字段：
- `session_id::String`：会话标识，决定落盘目录
- `index::Vector{String}`：Layer 1，每条 ≤150 字符的摘要
- `topics_dir::String`：Layer 2 目录路径
- `transcript_path::String`：Layer 3 文件路径（append-only jsonl）
"""
mutable struct SessionMemory
    session_id::String
    index::Vector{String}
    topics_dir::String
    transcript_path::String
end

"""
    SessionMemory(; session_id) -> SessionMemory

构造记忆。若落盘目录已有 index/transcript，则加载既有 Layer 1（跨会话恢复）。
"""
function SessionMemory(; session_id::String = DEFAULT_SESSION_ID)
    base = joinpath("data", "sessions", session_id)
    topics_dir = joinpath(base, "topics")
    transcript_path = joinpath(base, "transcript.jsonl")
    index_path = joinpath(base, "index.jsonl")
    index = String[]
    isfile(index_path) && append!(index, readlines(index_path))
    return SessionMemory(session_id, index, topics_dir, transcript_path)
end

# ─── Layer 1：index（始终加载）───

"""
    memory_context(mem; max_entries=20) -> String

把 Layer 1 index 格式化为可注入 System Prompt 动态区的文本。
条目过多时只展示最近 max_entries 条并标注总数。
"""
function memory_context(mem::SessionMemory; max_entries::Int = 20)
    isempty(mem.index) && return ""
    n = length(mem.index)
    if n <= max_entries
        body = join(mem.index, "\n")
    else
        body = join(mem.index[(n - max_entries + 1):n], "\n")
        body *= "\n…（最近 $max_entries 条，共 $n 条）"
    end
    return "本次会话已记录的实验摘要：\n$body"
end

# ─── Layer 2：topic（按需加载）───

"""
    load_topic(mem, name) -> String

读取 Layer 2 主题文件 `topics/<name>.md` 全文。文件不存在返回空串。
"""
function load_topic(mem::SessionMemory, name::AbstractString)
    path = joinpath(mem.topics_dir, "$(name).md")
    return isfile(path) ? read(path, String) : ""
end

"""
    write_topic!(mem, name, content)

写入 Layer 2 主题文件（覆盖）。供 consolidate! 或 Agent 显式调用。
"""
function write_topic!(mem::SessionMemory, name::AbstractString, content::AbstractString)
    mkpath(mem.topics_dir)
    write(joinpath(mem.topics_dir, "$(name).md"), content)
    return content
end

# ─── Layer 3：transcript（append-only）───

"""
    record_result!(mem, tool, args, result)

记录一次工具调用到三层记忆：
- Layer 3：append 一行 JSON 到 transcript.jsonl（永不主动加载）
- Layer 1：把工具调用压缩成 ≤150 字符摘要追加到 index（会进 prompt 动态区）

参数：
- `tool::String`：工具名
- `args::AbstractDict`：工具参数
- `result::String`：工具结果（已序列化为字符串）
"""
function record_result!(mem::SessionMemory, tool::AbstractString,
                        args::AbstractDict, result::AbstractString)
    mkpath(dirname(mem.transcript_path))
    # Layer 3：append-only jsonl（含时间戳）
    entry = Dict{String,Any}(
        "ts" => Dates.format(now(), "yyyy-mm-ddTHH:MM:SS"),
        "tool" => tool,
        "args" => args,
        "result" => result,
    )
    open(mem.transcript_path, "a") do io
        println(io, JSON.json(entry))
    end
    # Layer 1：≤150 字符摘要（部分工具如 list_available 不入 Layer 1，仅记 Layer 3）
    summary = _summarize_entry(tool, args, result)
    if summary !== nothing
        push!(mem.index, summary)
        # 同步 index 落盘（append 最后一行，保证跨会话可恢复）
        index_path = replace(mem.transcript_path, "transcript.jsonl" => "index.jsonl")
        open(index_path, "a") do io
            println(io, summary)
        end
    end
    return mem
end

# ─── 辅助：把工具调用压缩成 ≤150 字符摘要 ───
# 字符安全截断（collect 避免在 UTF-8 多字节边界切断）。
function _summarize_entry(tool::AbstractString, args::AbstractDict, result::AbstractString)
    entry = if tool == "scan_parameter"
        param = get(args, "param", "?")
        values = get(args, "values", [])
        vs = isempty(values) ? "?" : join(values, "/")
        "扫描 $param=$vs"
    elseif tool == "run_simulation"
        c = get(args, "constellation", "?")
        t = get(args, "topology", "-")
        p = get(args, "propagator", "-")
        "仿真 $c | topo=$t | prop=$p"
    elseif tool == "compare_constellations"
        cs = get(args, "constellations", [])
        "对比 " * (isempty(cs) ? "?" : join(cs, "/"))
    else
        return  # 其它工具不记入 Layer 1（但仍记 Layer 3）
    end
    if length(entry) > 150
        entry = String(collect(entry)[1:147]) * "..."
    end
    return entry
end

"""
    grep_transcript(mem, keyword) -> Vector{String}

在 Layer 3 transcript 中按关键词过滤，返回匹配的原始 JSON 行。
（永不把整个 transcript 加载进上下文，只 grep。）
"""
function grep_transcript(mem::SessionMemory, keyword::AbstractString)
    isfile(mem.transcript_path) || return String[]
    return [line for line in readlines(mem.transcript_path) if occursin(keyword, line)]
end

# ─── 跨会话加载 ───

"""
    load_memory(session_id) -> SessionMemory

加载某个会话的三层记忆（恢复 Layer 1 到内存；Layer 2/3 仍按需落盘访问）。
"""
load_memory(session_id::AbstractString) = SessionMemory(session_id = session_id)

# ─── 整理（autoDream 的极简版，用户显式触发）───

"""
    consolidate!(mem) -> Int

把 Layer 3 transcript 整理为 Layer 1 的去重摘要（极简版 autoDream）。
返回去重后的 index 条数。

不做 LLM 摘要（避免引入额外 LLM 调用），仅做基于工具调用的去重：
相同 (tool, 关键参数) 的记录只保留最后一次。
"""
function consolidate!(mem::SessionMemory)
    isfile(mem.transcript_path) || return 0
    records = [JSON.parse(line) for line in readlines(mem.transcript_path)]
    # 按工具+参数去重，保留最后出现
    seen = Dict{String,Int}()
    for (i, r) in enumerate(records)
        key = string(r["tool"], "_", _args_key(r["args"]))
        seen[key] = i
    end
    keep = sort(collect(values(seen)))
    # 重建 Layer 1
    empty!(mem.index)
    for i in keep
        s = _summarize_entry(records[i]["tool"], records[i]["args"], records[i]["result"])
        s === nothing && continue
        push!(mem.index, s)
    end
    # 落盘重建的 index
    index_path = replace(mem.transcript_path, "transcript.jsonl" => "index.jsonl")
    open(index_path, "w") do io
        for s in mem.index; println(io, s); end
    end
    return length(mem.index)
end

# 工具参数的关键字段（用于去重 key）
function _args_key(args)
    isempty(args) && return ""
    ks = sort(collect(keys(args)))
    return join(["$k=$(args[k])" for k in ks], ",")
end
