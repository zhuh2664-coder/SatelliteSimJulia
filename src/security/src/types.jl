# ===== 攻击类型树 =====
#
# 所有攻击行为的根类型与子分类。设计遵循项目多重分派惯例：
# 新攻击 = 新子类型 + 新 attack! 方法，不改已有代码（Open-Closed）。
#
# 按威胁面分四个 abstract 子类，对应 P0-P5 路线图：
# - AbstractNetworkAttack：空间网络层（ISL/路由/拓扑）— P0/P1 先实现
# - AbstractGroundAttack：地面段 cyber 入侵 — P2
# - AbstractRFAttack：RF/物理层干扰欺骗 — P5
# - AbstractPayloadAttack：星上载荷/固件 — P4

export AbstractAttack,
       AbstractNetworkAttack, AbstractGroundAttack, AbstractRFAttack, AbstractPayloadAttack

"""
    AbstractAttack

所有攻击行为的根类型。

具体攻击以 struct 子类型定义，施加方式由 `attack!(靶场状态, 攻击实例)` 多重分派决定。
分派依据是「靶场状态类型」+「攻击类型」两个维度，支持同一攻击施加到不同保真度的靶场。
"""
abstract type AbstractAttack end

"""空间网络层攻击：ISL 黑洞、拓扑切断、路由污染、流量注入。P0/P1 优先实现。"""
abstract type AbstractNetworkAttack <: AbstractAttack end

"""地面段 cyber 入侵：VPN 错配、横向移动、调制解调器擦除（Viasat 类）。P2。"""
abstract type AbstractGroundAttack <: AbstractAttack end

"""RF/物理层攻击：信号干扰、GNSS 欺骗、伪 TT&C 命令上行。P5。"""
abstract type AbstractRFAttack <: AbstractAttack end

"""星上载荷/固件攻击：命令注入、固件篡改、资源耗尽。P4。"""
abstract type AbstractPayloadAttack <: AbstractAttack end
