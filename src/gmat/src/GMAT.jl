# =============================================================================
# GMAT.jl — Julia 版 GMAT 核心引擎
# =============================================================================
#
# GMAT（General Mission Analysis Tool）是 NASA 的航天任务分析工具（C++，几十万行）。
# 本包是 GMAT 风格的 Julia 实现，聚焦 3 个核心子系统：
#   1. 力模型体系（forcemodel/）：可组合的摄动力（重力场/第三体/阻力/光压）
#   2. 数值积分器（propagator/）：PrinceDormand78 等高阶积分器
#   3. 任务序列命令（command/）：Propagate/Maneuver/Target 声明式任务描述
#
# 定位：SatelliteSimJulia 生态下的独立航天动力学引擎。
# 依赖方向：GMAT → SatelliteSimFoundation（常量/坐标）。不依赖 Orbit/Net/Lab。
#
# 不是 GMAT 的完整复现（不做 estimator/GUI/plugin/完整 attitude）。

module GMAT

using SatelliteSimFoundation
using LinearAlgebra
using StaticArrays

# 阶段 1：力模型体系
include("forcemodel/abstract.jl")
include("forcemodel/gravity.jl")
include("forcemodel/thirdbody.jl")
include("forcemodel/drag.jl")
include("forcemodel/srp.jl")

# 阶段 3：航天器模型（力模型和积分器都依赖它，先加载）
include("spacecraft/spacecraft.jl")

# 阶段 2：积分器
include("propagator/abstract.jl")
include("propagator/prince_dormand.jl")
include("propagator/integrator_setup.jl")

# 阶段 4：任务序列命令
include("command/abstract.jl")
include("command/propagate.jl")
include("command/maneuver.jl")
include("command/target.jl")

end # module
