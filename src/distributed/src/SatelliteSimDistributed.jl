# =============================================================================
# SatelliteSimDistributed — 分布式卫星仿真（每星一进程）
# =============================================================================
#
# 把单进程仿真（run_experiment）改造成"每颗卫星一个 worker 进程"的分布式架构。
# MVP 阶段：Distributed.jl + 协调进程集中路由 + 步进时间同步。
#
# 架构：
#   协调进程（Driver）：分发根数、步进同步、收集 ISL 边、集中算路由、聚合指标
#   卫星 worker（每星一个）：独立传播轨道、评估本地 ISL、上报结果
#
# 依赖方向：Distributed → Core/Net/Metrics/Foundation（复用现有计算能力）

module SatelliteSimDistributed

using LinearAlgebra
using Statistics
using SatelliteSimCore
using SatelliteSimNet
using SatelliteSimMetrics
using Distributed: addprocs, nworkers, remotecall, remotecall_fetch, @everywhere, rmprocs, workers

include("satellite_server.jl")
include("coordinator.jl")

end # module
