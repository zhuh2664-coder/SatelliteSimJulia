# ===== AI tool schema validation =====
#
# 运行时校验 LLM tool_call 参数，避免非法参数进入实验工具 handler。
# 只实现当前工具 schema 用到的 JSON Schema 子集：object/properties/required/type/enum/items。

export ToolSchemaValidationResult, validate_tool_args,
       schema_validation_hook, register_default_schema_validation!

struct ToolSchemaValidationResult
    ok::Bool
    errors::Vector{String}
end

const _DEFAULT_SCHEMA_VALIDATION_REGISTERED = Ref(false)

function _schema_type_ok(expected::AbstractString, value)::Bool
    expected == "string"  && return value isa AbstractString
    expected == "number"  && return value isa Real && !(value isa Bool)
    expected == "integer" && return value isa Integer && !(value isa Bool)
    expected == "boolean" && return value isa Bool
    expected == "object"  && return value isa AbstractDict
    expected == "array"   && return value isa AbstractVector
    expected == "null"    && return value === nothing
    return true
end

function _schema_type_ok(expected::AbstractVector, value)::Bool
    return any(t -> t isa AbstractString && _schema_type_ok(t, value), expected)
end

function _schema_type_ok(expected, value)::Bool
    return true
end

function _validate_schema!(errors::Vector{String}, path::String, schema::AbstractDict, value)
    if haskey(schema, "type") && !_schema_type_ok(schema["type"], value)
        push!(errors, "$path expected type $(schema["type"]), got $(typeof(value))")
        return errors
    end

    if haskey(schema, "enum")
        allowed = schema["enum"]
        any(x -> x == value, allowed) || push!(errors, "$path must be one of $(join(string.(allowed), ", "))")
    end

    if get(schema, "type", nothing) == "object" || haskey(schema, "properties") || haskey(schema, "required")
        value isa AbstractDict || return errors
        props = get(schema, "properties", Dict{String,Any}())
        required = get(schema, "required", String[])

        for key in required
            haskey(value, key) || push!(errors, "$path.$key is required")
        end

        if get(schema, "additionalProperties", true) === false
            for key in keys(value)
                haskey(props, string(key)) || push!(errors, "$path.$key is not allowed")
            end
        end

        for (key, subschema) in props
            haskey(value, key) || continue
            subschema isa AbstractDict || continue
            _validate_schema!(errors, "$path.$key", subschema, value[key])
        end
    end

    if (get(schema, "type", nothing) == "array" || haskey(schema, "items")) && value isa AbstractVector
        item_schema = get(schema, "items", nothing)
        if item_schema isa AbstractDict
            for (i, item) in enumerate(value)
                _validate_schema!(errors, "$path[$i]", item_schema, item)
            end
        end
    end

    return errors
end

function validate_tool_args(name::String, args::AbstractDict)::ToolSchemaValidationResult
    isdefined(@__MODULE__, :ensure_default_ai_tools!) && ensure_default_ai_tools!()
    spec = isdefined(@__MODULE__, :get_ai_tool) ? get_ai_tool(name) : nothing
    spec === nothing && return ToolSchemaValidationResult(false, ["unknown tool: $name"])

    errors = String[]
    _validate_schema!(errors, "args", spec.input_schema, args)
    return ToolSchemaValidationResult(isempty(errors), errors)
end

function schema_validation_hook(ctx::PreToolCtx)
    result = validate_tool_args(ctx.tool, ctx.args)
    result.ok && return nothing
    return (:block, "schema validation failed: $(join(result.errors, "; "))")
end

function register_default_schema_validation!()
    _DEFAULT_SCHEMA_VALIDATION_REGISTERED[] && return nothing
    register_hook!(:pre_tool, schema_validation_hook)
    _DEFAULT_SCHEMA_VALIDATION_REGISTERED[] = true
    return nothing
end
