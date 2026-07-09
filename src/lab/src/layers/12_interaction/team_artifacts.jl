# ===== TeamGraph structured artifacts =====
#
# 约定 Agent 输出中可包含一行：
#   ARTIFACT <key> <json-object-or-array-or-string>
# TeamGraph 会把这些结构化产物写入 state.artifacts，供后续节点和 checkpoint 使用。

export extract_team_artifacts!, team_artifact_summary

const TEAM_ARTIFACT_PREFIX = "ARTIFACT "

function _parse_artifact_line(line::AbstractString)
    startswith(line, TEAM_ARTIFACT_PREFIX) || return nothing
    rest = strip(line[length(TEAM_ARTIFACT_PREFIX) + 1:end])
    isempty(rest) && return nothing
    parts = split(rest, limit = 2)
    length(parts) == 2 || return nothing
    key = String(parts[1])
    value = try
        JSON.parse(parts[2])
    catch
        parts[2]
    end
    return key => value
end

function extract_team_artifacts!(state::TeamState, output::AbstractString)::Vector{String}
    keys = String[]
    for line in split(String(output), '\n')
        parsed = _parse_artifact_line(strip(line))
        parsed === nothing && continue
        key, value = parsed
        state.artifacts[key] = value
        push!(keys, key)
    end
    return keys
end

function team_artifact_summary(state::TeamState)::Dict{String,Any}
    return Dict{String,Any}(
        "count" => length(state.artifacts),
        "keys" => sort(collect(keys(state.artifacts))),
    )
end
