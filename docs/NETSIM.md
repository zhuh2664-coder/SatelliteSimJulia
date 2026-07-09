# SatelliteSimNetSim — 分组级离散事件网络层

## 定位

| 层 | 包 | 保真度 | 可微 |
|---|---|---|---|
| 解析层 | `SatelliteSimNet` + `SatelliteSimTraffic` | 拓扑 / Dijkstra / AoN 流量矩阵 | 是（经 Opt） |
| **DES 层** | **`SatelliteSimNetSim`** | 排队 / 丢包 / CGR / TCP / FlowMonitor | **否** |

两层共享解析层给出的 **ISL 拓扑 + 逐跳传播时延**；DES 层补 ns-3 / DTN 风格行为。

## 快速开始

```julia
using SatelliteSimJulia

demo_netsim()      # DropTail 多跳 + FlowMonitor
demo_cgr()         # ContactPlan + CGR
demo_tcp_reno()    # 简化 TCP Reno
```

桥接脚本（真实 Iridium 路径 → DES）：

```bash
julia --project=. scripts/demo_netsim_bridge.jl
```

测试：

```bash
julia --project=. test/test_netsim.jl
```

## API 一览

### Phase 1 — 路径 DES
- `Packet` / `create_packet!`
- `DropTailQueue` / `enqueue!` / `dequeue!`
- `PathHop` / `PathSimConfig` / `PathSimResult`
- `simulate_path(prop_delay_ms, data_rate_bps; ...)`
- `hops_from_prop_ms`

### Phase 2 — DTN / 传输 / 观测
- `Contact` / `ContactPlan` / `add_contact!` / `build_contact_plan_from_pos!`
- `cgr_route` / `cgr_earliest_arrival` / `CgrRoute`
- `FlowMonitor` / `record_tx!` / `record_rx!` / `record_drop!` / `flow_summary`
- `UdpHeader` / `udp_payload_bytes`
- `simulate_tcp_reno` / `TcpRenoConfig` / `TcpRenoResult`

## 与 archive 的关系

`src/_archive/legacy_layers/09_protocol/netsim/` 仍保留更完整的实验性栈。  
正式包走干净、可测试的子集；后续可继续迁入 Bundle/LTP/pcap。

## 架构红线

**不要把 DES 放进可微优化路径。** `optimize_coverage` 继续走解析层。
