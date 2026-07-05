# models.jl — 元数据实体定义

export User, Experiment, Job

using Dates
using UUIDs

struct User
    id::UUID
    email::String
    token_hash::String
    created_at::DateTime
end

struct Experiment
    id::UUID
    owner_id::UUID
    name::String
    config_key::String
    created_at::DateTime
end

struct Job
    id::UUID
    owner_id::UUID
    experiment_id::UUID
    status::String
    k8s_job_name::Union{String,Nothing}
    result_key::Union{String,Nothing}
    runner_logs::Union{String,Nothing}
    created_at::DateTime
    completed_at::Union{DateTime,Nothing}
end

# 从 LibPQ 行构造结构体
function _row_to_user(row)::User
    return User(
        UUID(string(row[:id])),
        string(row[:email]),
        string(row[:token_hash]),
        DateTime(string(row[:created_at])[1:19], "yyyy-mm-ddTHH:MM:SS"),
    )
end

function _row_to_experiment(row)::Experiment
    return Experiment(
        UUID(string(row[:id])),
        UUID(string(row[:owner_id])),
        string(row[:name]),
        string(row[:config_key]),
        DateTime(string(row[:created_at])[1:19], "yyyy-mm-ddTHH:MM:SS"),
    )
end

function _row_to_job(row)::Job
    return Job(
        UUID(string(row[:id])),
        UUID(string(row[:owner_id])),
        UUID(string(row[:experiment_id])),
        string(row[:status]),
        row[:k8s_job_name] === nothing ? nothing : string(row[:k8s_job_name]),
        row[:result_key] === nothing ? nothing : string(row[:result_key]),
        row[:runner_logs] === nothing ? nothing : string(row[:runner_logs]),
        DateTime(string(row[:created_at])[1:19], "yyyy-mm-ddTHH:MM:SS"),
        row[:completed_at] === nothing ? nothing :
            DateTime(string(row[:completed_at])[1:19], "yyyy-mm-ddTHH:MM:SS"),
    )
end
