# K8sScheduler.jl — K8s Job 调度与状态监听

module K8sScheduler

using JSON
using UUIDs
using Storage

const DEFAULT_IMAGE = "satnet-sim:latest"
const DEFAULT_NAMESPACE = "default"

# 渲染 K8s Job YAML
function _render_job_yaml(job_name::String, image::String,
                          config_s3_url::String, output_s3_url::String)::String
    job = Dict(
        "apiVersion" => "batch/v1",
        "kind" => "Job",
        "metadata" => Dict("name" => job_name),
        "spec" => Dict(
            "template" => Dict(
                "spec" => Dict(
                    "restartPolicy" => "OnFailure",
                    "containers" => [Dict(
                        "name" => "runner",
                        "image" => image,
                        "command" => ["entrypoint.sh", config_s3_url, output_s3_url],
                        "env" => [
                            Dict("name" => "DATABASE_URL", "valueFrom" =>
                                  Dict("secretKeyRef" =>
                                        Dict("name" => "satnet-db", "key" => "url"))),
                            Dict("name" => "MINIO_ENDPOINT", "valueFrom" =>
                                  Dict("secretKeyRef" =>
                                        Dict("name" => "satnet-minio", "key" => "endpoint"))),
                            Dict("name" => "MINIO_ACCESS_KEY", "valueFrom" =>
                                  Dict("secretKeyRef" =>
                                        Dict("name" => "satnet-minio", "key" => "access-key"))),
                            Dict("name" => "MINIO_SECRET_KEY", "valueFrom" =>
                                  Dict("secretKeyRef" =>
                                        Dict("name" => "satnet-minio", "key" => "secret-key"))),
                        ],
                    )),
                ),
            ),
            "backoffLimit" => 2,
        ),
    )
    return JSON.json(job, 2)
end

function _kubectl(args::Vector{String}; stdin::String = "")
    cmd = `kubectl $args`
    return stdin == "" ? readchomp(cmd) : readchomp(pipeline(cmd, stdin))
end

# 提交 K8s Job，返回 job_name
function submit_job(job_id::UUID, config_s3_url::String, output_s3_url::String;
                    image::String = DEFAULT_IMAGE,
                    namespace::String = DEFAULT_NAMESPACE)::String
    job_name = "satnet-job-$(string(job_id)[1:8])"
    yaml = _render_job_yaml(job_name, image, config_s3_url, output_s3_url)

    _kubectl(["apply", "-n", namespace, "-f", "-"]; stdin = yaml)
    return job_name
end

# 监听 Job 状态直到完成，更新 DB
function watch_job(job_id::UUID, k8s_job_name::String;
                   poll_interval::Float64 = 5.0,
                   namespace::String = DEFAULT_NAMESPACE)
    while true
        sleep(poll_interval)
        status_json = _kubectl(["get", "job", "-n", namespace, k8s_job_name, "-o", "jsonpath={.status}"])

        if contains(status_json, "succeeded:1")
            logs = _kubectl(["logs", "-n", namespace, "-l", "job-name=$(k8s_job_name)", "--tail=100"])
            Storage.update_job_status!(job_id, job_id; status = "succeeded",
                                       runner_logs = logs)
            return
        elseif contains(status_json, "failed:")
            logs = _kubectl(["logs", "-n", namespace, "-l", "job-name=$(k8s_job_name)", "--tail=100"])
            Storage.update_job_status!(job_id, job_id; status = "failed",
                                       runner_logs = logs)
            return
        end
    end
end

end  # module
