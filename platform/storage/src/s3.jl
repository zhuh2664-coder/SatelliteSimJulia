# s3.jl — MinIO / S3 对象存储封装

export download_config, upload_config, upload_result_prefix, download_result, list_results

using AWS
using AWSS3
using JSON
using URIs

function _s3_config()
    endpoint = get(ENV, "MINIO_ENDPOINT", "http://localhost:9000")
    access_key = get(ENV, "MINIO_ACCESS_KEY", "minioadmin")
    secret_key = get(ENV, "MINIO_SECRET_KEY", "minioadmin")
    region = get(ENV, "MINIO_REGION", "us-east-1")

    creds = AWS.AWSCredentials(access_key, secret_key)
    config = AWS.AWSConfig(creds, region)

    # 覆盖 endpoint 为 MinIO
    ENV["AWS_REGION"] = region
    return config, endpoint
end

function _parse_s3_url(url::String)
    uri = URI(url)
    path = lstrip(uri.path, '/')
    parts = split(path, '/'; limit = 2)
    bucket = parts[1]
    key = length(parts) > 1 ? parts[2] : ""
    return bucket, key
end

# 下载实验配置 JSON 并解析为 Dict
function download_config(key::String)::Dict
    config, _ = _s3_config()
    bucket = get(ENV, "MINIO_BUCKET_CONFIGS", "configs")
    bytes = AWSS3.s3_get(config, bucket, key)
    return JSON.parse(String(bytes))
end

# 上传配置 bytes
function upload_config(key::String, data::Vector{UInt8})::String
    config, _ = _s3_config()
    bucket = get(ENV, "MINIO_BUCKET_CONFIGS", "configs")
    AWSS3.s3_put(config, bucket, key, data)
    return "s3://$(bucket)/$(key)"
end

# 上传本地目录下所有文件到指定 S3 prefix
function upload_result_prefix(local_dir::String, s3_prefix::String)::String
    config, _ = _s3_config()
    bucket = get(ENV, "MINIO_BUCKET_RESULTS", "results")
    prefix = lstrip(s3_prefix, '/')

    for entry in readdir(local_dir; join = true)
        isfile(entry) || continue
        fname = basename(entry)
        key = prefix * fname
        data = read(entry)
        AWSS3.s3_put(config, bucket, key, data)
    end
    return s3_prefix
end

# 下载单个对象
function download_result(key::String)::Vector{UInt8}
    config, _ = _s3_config()
    bucket = get(ENV, "MINIO_BUCKET_RESULTS", "results")
    return AWSS3.s3_get(config, bucket, key)
end

# 列出某 prefix 下所有对象 key
function list_results(prefix::String)::Vector{String}
    config, _ = _s3_config()
    bucket = get(ENV, "MINIO_BUCKET_RESULTS", "results")
    objs = AWSS3.s3_list_keys(config, bucket, prefix)
    return objs
end
