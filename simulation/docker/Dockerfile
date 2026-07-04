# SatelliteSimJulia — 自治卫星 Agent Docker 镜像
#
# 每个容器 = 一颗卫星的数字孪生
# 运行：Julia Agent Runtime（可选）+ Python BPv7/DTN 协议栈
#
# 构建：
#   docker build -t satellite-agent .
# 启动：
#   docker run --name sat-001 satellite-agent --sat-id 1

FROM julia:1.11-ubuntu

LABEL description="SatelliteSimJulia Autonomous Satellite Agent"
LABEL maintainer="SatelliteSimJulia"

# 安装系统依赖
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    python3-venv \
    iproute2 \
    iputils-ping \
    net-tools \
    tcpdump \
    curl \
    && rm -rf /var/lib/apt/lists/*

# 安装 Python DTN 协议 (预留)
# RUN pip3 install pydtn  # 当前无直接可用的纯 Python BPv7 库，需自行实现或使用 C 库绑定

# 复制 Julia Agent Runtime
COPY agent_runtime /opt/satellite/agent_runtime

# 启动脚本
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# 健康检查
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

ENTRYPOINT ["entrypoint.sh"]
