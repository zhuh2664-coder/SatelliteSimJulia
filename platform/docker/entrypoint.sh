#!/bin/bash
# entrypoint.sh — 仿真 runner 容器入口
# 从环境变量读取 S3 URL，调用 satnet-run.jl

set -e

CONFIG_S3="${CONFIG_S3_URL:-${1:-}}"
OUTPUT_S3="${OUTPUT_S3_URL:-${2:-}}"

# 允许命令行传参覆盖环境变量
if [[ -n "$1" && "$1" != --* ]]; then
    CONFIG_S3="$1"
fi
if [[ -n "$2" && "$2" != --* ]]; then
    OUTPUT_S3="$2"
fi

if [[ -z "$CONFIG_S3" ]]; then
    echo "ERROR: CONFIG_S3_URL or first arg required" >&2
    exit 1
fi
if [[ -z "$OUTPUT_S3" ]]; then
    echo "ERROR: OUTPUT_S3_URL or second arg required" >&2
    exit 1
fi

exec julia --project=/opt/satnet/platform/runner \
    /opt/satnet/platform/runner/bin/satnet-run.jl \
    --config-s3 "$CONFIG_S3" \
    --output-s3 "$OUTPUT_S3"
