# SatelliteSimNetSim — 分组级离散事件网络层

## 定位

| 层 | 包 | 保真度 | 可微 |
|---|---|---|---|
| 解析层 | `SatelliteSimNet` + `SatelliteSimTraffic` | 拓扑 / Dijkstra / AoN 流量矩阵 | 是（经 Opt） |
| **DES 层** | **`SatelliteSimNetSim`** | 排队时延 / 丢包 / 时延分布 | **否** |

两层共享解析层给出的 **ISL 拓扑 + 逐跳传播时延**；DES 层只补 ns-3 风格的分组行为。

## 快速开始

```julia
using SatelliteSimJulia

# 纯 DES 自检（不依赖星座）
demo_netsim(load_mbps=130, rate_mbps=100, duration_s=2)

# 或：解析层路径 → DES
result = simulate_path([10.5, 10.8, 11.2], 100e6;
                       load_bps=130e6, duration_s=2.0, poisson=true)
```

桥接脚本（真实 Iridium 路径）：

```bash
julia --project=. scripts/demo_netsim_bridge.jl
```

测试：

```bash
julia --project=. test/test_netsim.jl
```

## API

- `Packet` / `create_packet!` — 数据包
- `DropTailQueue` / `enqueue!` / `dequeue!` — 尾丢弃队列
- `PathHop` / `PathSimConfig` / `PathSimResult`
- `simulate_path(prop_delay_ms, data_rate_bps; ...)` — 多跳 DES
- `hops_from_prop_ms` — 从解析层时延构造 hops
- `demo_netsim` — 自包含演示

## 与 archive 的关系

`src/_archive/legacy_layers/09_protocol/netsim/` 里有更完整的 ns-3 风格栈（TCP/CGR/FlowMonitor 等）。  
`SatelliteSimNetSim` 是 **Phase 1**：先把 DES 引擎 + DropTail + 多跳路径仿真正式接入主包。  
后续可按需把 archive 中的 CGR / TCP / pcap 迁入本包。

## 架构红线

**不要把 DES 放进可微优化路径。** `optimize_coverage` 继续走解析层；DES 只做高保真评估与交叉验证。
