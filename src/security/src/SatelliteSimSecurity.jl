"""
    SatelliteSimSecurity

LEO 卫星星座攻防对抗层（对应 12 层架构的 Layer 8 安全层 + 红蓝对抗编排）。

# 定位
独立子包，通过多重分派挂载到现有仿真流水线，**不修改 Layer 0-5 主干**。
消费下游层（Orbit/Link/Net/Traffic/Metrics）的输出，产出攻击/检测/对抗结果。

# 组成
- `types.jl`：攻击类型树（`AbstractAttack` 根 + 子类型）
- `topology_attacks.jl`：拓扑/链路层攻击原语（迁移自 legacy vulnerability.jl）
- `energy_drain_attack.jl`：能耗攻击（迁移自 legacy energy_drain.jl）
- `redteam.jl`：红队攻击施加（P1）
- `blueteam.jl`：蓝队检测器（P1）
- `arena.jl`：对抗沙箱 + 紫队闭环（P1）

# 依赖方向
Foundation ← Link ← Net ← Traffic ← Metrics ← **Security**
"""
module SatelliteSimSecurity

using Graphs
using SatelliteSimFoundation
using SatelliteSimLink
using SatelliteSimNet
using SatelliteSimTraffic
using SatelliteSimMetrics
using SatelliteSimCore

# 子文件按依赖顺序加载
include("types.jl")
include("topology_attacks.jl")
include("energy_drain_attack.jl")
include("redteam.jl")
include("blueteam.jl")
include("arena.jl")

end # module
