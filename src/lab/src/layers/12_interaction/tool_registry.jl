# ===== AI tool registry =====
#
# LLM 工具注册表。保留现有工具行为，但把 schema/dispatch 从硬编码迁移到
# 可注册结构，后续新增工具只需 register_ai_tool!。

export AIToolSpec, register_ai_tool!, registered_ai_tools, get_ai_tool,
       build_registered_tool_schemas, execute_registered_tool,
       llm_tool_schema, ensure_default_ai_tools!

struct AIToolSpec
    name::String
    description::String
    input_schema::Dict{String,Any}
    handler::Function
end

const AI_TOOL_REGISTRY = Dict{String,AIToolSpec}()
const _DEFAULT_AI_TOOLS_REGISTERED = Ref(false)

function register_ai_tool!(spec::AIToolSpec)
    AI_TOOL_REGISTRY[spec.name] = spec
    return spec
end

registered_ai_tools() = sort(collect(keys(AI_TOOL_REGISTRY)))

get_ai_tool(name::String)::Union{AIToolSpec,Nothing} = get(AI_TOOL_REGISTRY, name, nothing)

function llm_tool_schema(spec::AIToolSpec)::Dict{String,Any}
    return Dict{String,Any}(
        "name" => spec.name,
        "description" => spec.description,
        "input_schema" => spec.input_schema,
    )
end

build_registered_tool_schemas() = [llm_tool_schema(AI_TOOL_REGISTRY[name]) for name in registered_ai_tools()]

function execute_registered_tool(name::String, args::AbstractDict)
    spec = get_ai_tool(name)
    spec === nothing && return nothing
    if isdefined(@__MODULE__, :validate_tool_args)
        validation = validate_tool_args(name, args)
        validation.ok || return Dict("error" => "schema validation failed: $(join(validation.errors, "; "))")
    end
    return spec.handler(args)
end

function _register_core_ai_tools!()
    register_ai_tool!(AIToolSpec(
        "run_simulation",
        "运行星座网络仿真。可指定星座规模、拓扑、传播器、路由策略、流量场景、TLE/SGP4 等参数。",
        Dict{String,Any}(
            "type" => "object",
            "properties" => Dict{String,Any}(
                "constellation" => Dict("type" => "string", "description" => "星座名或 'walker T/P/F'，如 'iridium' 或 'walker 66/6/2'"),
                "topology" => Dict("type" => "string", "enum" => ai_topology_terms(), "default" => "balanced"),
                "propagator" => Dict("type" => "string", "enum" => ai_propagator_terms(), "default" => "fast"),
                "routing" => Dict("type" => "string", "enum" => ai_routing_terms(), "default" => "shortest_path", "description" => "路由意图；load_balanced 在 traffic AON 逐流评估中体现负载均衡语义。"),
                "duration_s" => Dict("type" => "number", "default" => 600),
                "steps" => Dict("type" => "integer", "default" => 2),
                "traffic" => Dict("type" => "string", "enum" => ai_traffic_terms(), "default" => "none"),
                "tle" => Dict("type" => "string", "description" => "TLE 文件路径或 TLE 文本；仅在 propagator=tle_based 且 catalog 无对应 TLE 时使用。"),
                "max_sats" => Dict("type" => "integer", "default" => 24, "description" => "限制 TLE 载入卫星数，避免真实 TLE 文件全量仿真。"),
                "traffic_demands" => Dict(
                    "type" => "array",
                    "description" => "显式 OD traffic demand 列表；提供后优先于 traffic intent。",
                    "items" => Dict(
                        "type" => "object",
                        "properties" => Dict(
                            "id" => Dict("type" => "integer"),
                            "source_ground_id" => Dict("type" => "integer"),
                            "destination_ground_id" => Dict("type" => "integer"),
                            "start_elapsed_s" => Dict("type" => "integer"),
                            "end_elapsed_s" => Dict("type" => "integer"),
                            "rate_mbps" => Dict("type" => "number"),
                        ),
                        "required" => ["source_ground_id", "destination_ground_id", "rate_mbps"],
                    ),
                ),
                "ground_stations" => Dict(
                    "type" => "array",
                    "items" => Dict(
                        "type" => "object",
                        "properties" => Dict(
                            "id" => Dict("type" => "integer"),
                            "name" => Dict("type" => "string"),
                            "lat" => Dict("type" => "number"),
                            "lon" => Dict("type" => "number"),
                            "alt_km" => Dict("type" => "number"),
                        ),
                        "required" => ["lat", "lon"],
                    ),
                ),
                "ground_pairs" => Dict(
                    "type" => "array",
                    "items" => Dict(
                        "type" => "array",
                        "items" => Dict("type" => "integer"),
                    ),
                ),
            ),
            "required" => ["constellation"],
        ),
        _tool_run_simulation,
    ))

    register_ai_tool!(AIToolSpec(
        "scan_parameter",
        "扫描单一参数对网络性能的影响（如高度、倾角、面数）。",
        Dict{String,Any}(
            "type" => "object",
            "properties" => Dict{String,Any}(
                "base_constellation" => Dict("type" => "string", "default" => "walker 24/6/1"),
                "param" => Dict("type" => "string", "enum" => ["alt_km", "inc_deg", "P", "T"]),
                "values" => Dict("type" => "array", "items" => Dict("type" => "number")),
            ),
            "required" => ["param", "values"],
        ),
        _tool_scan_parameter,
    ))

    register_ai_tool!(AIToolSpec(
        "compare_constellations",
        "对比多个星座的网络性能（覆盖、时延、连通性）。",
        Dict{String,Any}(
            "type" => "object",
            "properties" => Dict{String,Any}(
                "constellations" => Dict("type" => "array", "items" => Dict("type" => "string")),
            ),
            "required" => ["constellations"],
        ),
        _tool_compare_constellations,
    ))

    register_ai_tool!(AIToolSpec(
        "list_available",
        "列出可用的星座预设、拓扑词表、传播器词表、路由/流量意图等。",
        Dict{String,Any}(
            "type" => "object",
            "properties" => Dict{String,Any}(
                "what" => Dict("type" => "string", "enum" => ["constellations", "topologies", "propagators", "routing", "traffic", "intents", "all"], "default" => "all"),
            ),
        ),
        _tool_list_available,
    ))
end

function ensure_default_ai_tools!()
    _DEFAULT_AI_TOOLS_REGISTERED[] && return
    _register_core_ai_tools!()
    if isdefined(@__MODULE__, :register_planner_ai_tools!)
        register_planner_ai_tools!()
    end
    _DEFAULT_AI_TOOLS_REGISTERED[] = true
    return nothing
end
