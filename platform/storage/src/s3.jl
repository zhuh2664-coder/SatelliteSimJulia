# s3.jl — MinIO / S3 对象存储封装

export download_config, upload_config, upload_result_prefix, download_result, list_results

using AWS
using AWSS3
using JSON
using URIs

struct MinIOAWSConfig <: AWS.AbstractAWSConfig
    base::AWS.AWSConfig
    endpoint::String
end

AWS.credentials(config::MinIOAWSConfig) = AWS.credentials(config.base)
AWS.region(config::MinIOAWSConfig) = AWS.region(config.base)
AWS.max_attempts(config::MinIOAWSConfig) = AWS.max_attempts(config.base)

function AWS.generate_service_url(config::MinIOAWSConfig, service::String, resource::String)
    if service == "s3"
        return rstrip(config.endpoint, '/') * resource
    end
    return AWS.generate_service_url(config.base, service, resource)
end

function _s3_config()
    endpoint = get(ENV, "MINIO_ENDPOINT", "http://localhost:9000")
    access_key = get(ENV, "MINIO_ACCESS_KEY", "minioadmin")
    secret_key = get(ENV, "MINIO_SECRET_KEY", "minioadmin")
    region = get(ENV, "MINIO_REGION", "us-east-1")

    creds = AWS.AWSCredentials(access_key, secret_key)
    base = AWS.AWSConfig(creds, region, "json")
    return isempty(endpoint) ? base : MinIOAWSConfig(base, endpoint)
end

function _s3_location(value::String, default_bucket::String)
    if startswith(value, "s3://")
        uri = URI(value)
        bucket = String(uri.host)
        key = lstrip(String(uri.path), '/')
        return bucket, key
    end
    return default_bucket, lstrip(value, '/')
end

function _join_key(prefix::AbstractString, name::String)
    isempty(prefix) && return name
    return rstrip(prefix, '/') * "/" * name
end

# 下载实验配置 JSON 并解析为 Dict
function download_config(location::String)::Dict
    config = _s3_config()
    default_bucket = get(ENV, "MINIO_BUCKET_CONFIGS", "configs")
    bucket, key = _s3_location(location, default_bucket)
    bytes = AWSS3.s3_get(config, bucket, key; raw = true)
    return JSON.parse(String(bytes))
end

# 上传配置 bytes
function upload_config(key::String, data::Vector{UInt8})::String
    config = _s3_config()
    default_bucket = get(ENV, "MINIO_BUCKET_CONFIGS", "configs")
    bucket, object_key = _s3_location(key, default_bucket)
    AWSS3.s3_put(config, bucket, object_key, data)
    return "s3://$(bucket)/$(object_key)"
end

# 上传本地目录下所有文件到指定 S3 prefix
function upload_result_prefix(local_dir::String, s3_prefix::String)::String
    config = _s3_config()
    default_bucket = get(ENV, "MINIO_BUCKET_RESULTS", "results")
    bucket, prefix = _s3_location(s3_prefix, default_bucket)

    for (root, _, files) in walkdir(local_dir)
        for file in files
            entry = joinpath(root, file)
            rel = relpath(entry, local_dir)
            object_name = replace(rel, '\\' => '/')
            data = read(entry)
            AWSS3.s3_put(config, bucket, _join_key(prefix, object_name), data)
        end
    end
    return "s3://$(bucket)/$(rstrip(prefix, '/'))/"
end

# 下载单个对象
function download_result(location::String)::Vector{UInt8}
    config = _s3_config()
    default_bucket = get(ENV, "MINIO_BUCKET_RESULTS", "results")
    bucket, key = _s3_location(location, default_bucket)
    return AWSS3.s3_get(config, bucket, key; raw = true)
end

# 列出某 prefix 下所有对象 key
function list_results(prefix::String)::Vector{String}
    config = _s3_config()
    default_bucket = get(ENV, "MINIO_BUCKET_RESULTS", "results")
    bucket, key = _s3_location(prefix, default_bucket)
    objs = AWSS3.s3_list_keys(config, bucket, key)
    return objs
end
