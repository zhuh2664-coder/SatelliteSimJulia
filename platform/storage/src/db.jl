# db.jl — PostgreSQL 元数据操作

export connect, disconnect,
       create_user, get_user_by_email, get_user_by_token,
       create_experiment, get_experiment, list_experiments,
       create_job, get_job, list_jobs, update_job_status!

using Dates
using LibPQ
using UUIDs

# 全局连接（第一期简化；后续可改为连接池）
const _CONN = Ref{Union{LibPQ.Connection,Nothing}}(nothing)

function connect()
    url = get(ENV, "DATABASE_URL", "postgresql://postgres:postgres@localhost:5432/satnet")
    _CONN[] = LibPQ.Connection(url)
    return nothing
end

function disconnect()
    c = _CONN[]
    c === nothing || LibPQ.close(c)
    _CONN[] = nothing
    return nothing
end

function _conn()
    c = _CONN[]
    (c === nothing || LibPQ.status(c) != LibPQ.CONNECTION_OK) && connect()
    return _CONN[]
end

function _execute(sql::String, params = [])
    return LibPQ.execute(_conn(), sql, params)
end

# ── users ──
function create_user(email::String, token_hash::String)::User
    result = _execute(
        "INSERT INTO users (email, token_hash) VALUES (\$1, \$2) RETURNING *",
        [email, token_hash],
    )
    row = first(result)
    return _row_to_user(row)
end

function get_user_by_email(email::String)::Union{User,Nothing}
    result = _execute("SELECT * FROM users WHERE email = \$1 LIMIT 1", [email])
    isempty(result) && return nothing
    return _row_to_user(first(result))
end

function get_user_by_token(token_hash::String)::Union{User,Nothing}
    result = _execute("SELECT * FROM users WHERE token_hash = \$1 LIMIT 1", [token_hash])
    isempty(result) && return nothing
    return _row_to_user(first(result))
end

# ── experiments ──
function create_experiment(owner_id::UUID, name::String, config_key::String)::Experiment
    result = _execute(
        "INSERT INTO experiments (owner_id, name, config_key) VALUES (\$1, \$2, \$3) RETURNING *",
        [string(owner_id), name, config_key],
    )
    return _row_to_experiment(first(result))
end

function get_experiment(owner_id::UUID, id::UUID)::Union{Experiment,Nothing}
    result = _execute(
        "SELECT * FROM experiments WHERE id = \$1 AND owner_id = \$2 LIMIT 1",
        [string(id), string(owner_id)],
    )
    isempty(result) && return nothing
    return _row_to_experiment(first(result))
end

function list_experiments(owner_id::UUID)::Vector{Experiment}
    result = _execute(
        "SELECT * FROM experiments WHERE owner_id = \$1 ORDER BY created_at DESC",
        [string(owner_id)],
    )
    return [_row_to_experiment(row) for row in result]
end

# ── jobs ──
function create_job(owner_id::UUID, experiment_id::UUID)::Job
    result = _execute(
        "INSERT INTO jobs (owner_id, experiment_id) VALUES (\$1, \$2) RETURNING *",
        [string(owner_id), string(experiment_id)],
    )
    return _row_to_job(first(result))
end

function get_job(owner_id::UUID, id::UUID)::Union{Job,Nothing}
    result = _execute(
        "SELECT * FROM jobs WHERE id = \$1 AND owner_id = \$2 LIMIT 1",
        [string(id), string(owner_id)],
    )
    isempty(result) && return nothing
    return _row_to_job(first(result))
end

function list_jobs(owner_id::UUID)::Vector{Job}
    result = _execute(
        "SELECT * FROM jobs WHERE owner_id = \$1 ORDER BY created_at DESC",
        [string(owner_id)],
    )
    return [_row_to_job(row) for row in result]
end

function update_job_status!(owner_id::UUID, id::UUID;
                            status::Union{String,Nothing} = nothing,
                            k8s_job_name::Union{String,Nothing} = nothing,
                            result_key::Union{String,Nothing} = nothing,
                            runner_logs::Union{String,Nothing} = nothing,
                            completed_at::Union{DateTime,Nothing} = nothing)
    # 先校验 owner_id
    j = get_job(owner_id, id)
    j === nothing && error("job not found or access denied: $id")

    set_clauses = String[]
    params = Any[]

    if status !== nothing
        push!(set_clauses, "status = \$$(length(params)+1)")
        push!(params, status)
    end
    if k8s_job_name !== nothing
        push!(set_clauses, "k8s_job_name = \$$(length(params)+1)")
        push!(params, k8s_job_name)
    end
    if result_key !== nothing
        push!(set_clauses, "result_key = \$$(length(params)+1)")
        push!(params, result_key)
    end
    if runner_logs !== nothing
        push!(set_clauses, "runner_logs = \$$(length(params)+1)")
        push!(params, runner_logs)
    end
    if completed_at !== nothing
        push!(set_clauses, "completed_at = \$$(length(params)+1)")
        push!(params, completed_at)
    end

    isempty(set_clauses) && return nothing

    push!(params, string(id))
    sql = "UPDATE jobs SET $(join(set_clauses, ", ")) WHERE id = \$$(length(params))"
    _execute(sql, params)
    return nothing
end
