"""
    共享层：星历数据存储抽象模块

本文件位于项目流水线最上游的共享模块，定义了所有轨道星历（ephemeris）容器的
公共超类型。core/orbit_layer 中的具体实现（如 ConstellationEphemeris）继承自
AbstractEphemerisStore，从而为网络层、可视化层和测试床部署层提供统一的访问接口。
"""

"""
    AbstractEphemerisStore

所有星历存储容器的抽象基类型。

子类型负责保存仿真时间网格上每颗卫星的位置/速度样本，供后续
`core/network_layer/links.jl`、`core/network_layer/routing.jl` 与可视化层读取。
"""
abstract type AbstractEphemerisStore end
