#!/usr/bin/env julia
# ===== 配置文件密钥清除工具 =====
#
# 纯 Julia 实现，无外部依赖。
# 用正则匹配 API Key 模式，替换为 xxxx。
#
# 用法：
#   julia scripts/sanitize_keys.jl temp-wolaiyongde
#   julia scripts/sanitize_keys.jl temp-wolaiyongde --output clean.json
#   julia scripts/sanitize_keys.jl .claude/settings.local.json

# ──────────────────────────────────────────────
# 匹配模式：常见的 API Key 前缀
# ──────────────────────────────────────────────
const KEY_PATTERNS = [
    r"""(?<=["']ANTHROPIC_AUTH_TOKEN["']\s*:\s*["'])(sk-[^"']+)["']""" => "sk-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
    r"""(?<=["'](?:API_KEY|API_SECRET|TOKEN|PASSWORD|SECRET)["']\s*:\s*["'])([^"']+)["']""" => "xxxx",
    r"(?<=sk-)([a-zA-Z0-9]{20,})(?=[\"'])",  # sk- 开头，长字符串
    r"(?<=sk-ant-)([a-zA-Z0-9]{20,})(?=[\"'])",
    r"(?<=gh[pous]_)([a-zA-Z0-9]{10,})(?=[\"'])",
    r"(?<=AKIA)([A-Z0-9]{16})(?=[\"'])",
]

"""
    sanitize_json_file(input_path, output_path)

读取 JSON 文件，替换所有 API Key 为占位符，写入输出。
"""
function sanitize_json_file(input_path::String, output_path::String)
    if !isfile(input_path)
        println("错误: 文件不存在: $input_path")
        return false
    end

    content = read(input_path, String)
    original = content

    # 回合 1: 特定键值对替换（保留键名）
    # "ANTHROPIC_AUTH_TOKEN": "sk-xxxx..."
    content = replace(content, r"(\"ANTHROPIC_AUTH_TOKEN\"\s*:\s*\")[^\"]+(\")" => s"\1sk-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\2")
    content = replace(content, r"(\"ANTHROPIC_BASE_URL\"\s*:\s*\")[^\"]+(\")" => s"\1(redacted)\2")

    # 回合 2: 通用 API Key 前缀替换（以防遗漏）
    content = replace(content, r"sk-[a-zA-Z0-9]{20,}" => "sk-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx")
    content = replace(content, r"gh[pous]_[a-zA-Z0-9]{15,}" => "ghx_xxxxxxxxxxxxxxxxxxxx")
    content = replace(content, r"AKIA[A-Z0-9]{16}" => "AKIAxxxxxxxxxxxxxxxx")

    if content == original && !occursin("redacted", content)
        println("⚠️  文件看起来没有包含明显的 API Key，已原样输出")
        content = original  # 还原，不要破坏文件
    end

    # 统计替换数
    diff_count = count_diff(original, content)
    println("替换了 $diff_count 处敏感信息")

    write(output_path, content)
    println("写入: $output_path")

    if output_path == input_path
        println("⚠️  原文件已被覆盖！")
    end

    return true
end

"""
    count_diff(original, cleaned) -> Int

粗略统计替换了多少处（字符串长度差 / 平均替换长度 ≈ 次数）
"""
function count_diff(orig::String, clean::String)::Int
    diff = length(orig) - length(clean)
    return diff > 0 ? max(1, div(diff, 20)) : 0
end

# ──────────────────────────────────────────────
# 主入口
# ──────────────────────────────────────────────
function main()
    if length(ARGS) < 1
        println("用法: julia scripts/sanitize_keys.jl <文件路径> [--output 输出文件]")
        println()
        println("示例:")
        println("  julia scripts/sanitize_keys.jl temp-wolaiyongde")
        println("  julia scripts/sanitize_keys.jl .claude/settings.local.json --output settings.public.json")
        return
    end

    input_path = ARGS[1]
    output_idx = findfirst(==("--output"), ARGS)
    output_path = output_idx !== nothing ? ARGS[output_idx + 1] : input_path

    println("📖 读取: $input_path")
    sanitize_json_file(input_path, output_path)
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
