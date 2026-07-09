# SatelliteSimNetSim — 分组级离散事件网络层

## 定位

| 层 | 包 | 保真度 | 可微 |
|---|---|---|---|
| 解析层 | `SatelliteSimNet` + `SatelliteSimTraffic` | 拓扑 / Dijkstra / AoN 流量矩阵 | 是（经 Opt） |
| **DES 层** | **`SatelliteSimNetSim`** | 排队 / 丢包 / CGR / Bundle·LTP / TCP / FlowMonitor / PCAP | **否** |

两层共享解析层给出的 **ISL 拓扑 + 逐跳传播时延**；DES 层补 ns-3 / DTN 风格行为。

## 快速开始

```julia
using SatelliteSimJulia

demo_netsim()      # DropTail 多跳 + FlowMonitor
demo_cgr()         # ContactPlan + CGR
demo_tcp_reno()    # 简化 TCP Reno
demo_dtn()         # Bundle BPA store-and-forward + PCAP
demo_ltp()         # LTP red/green + 重传
demo_dual_fidelity()  # 解析 vs DES 双档 + M/D/1 + ns-3 JSON
```

完整验证（含 GMAT 轨道交叉）见 [VALIDATION.md](VALIDATION.md)：

```bash
julia --project=. scripts/validate_phase4.jl
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

### Phase 2 — DTN 路由 / 传输 / 观测
- `Contact` / `ContactPlan` / `add_contact!` / `build_contact_plan_from_pos!`
- `cgr_route` / `cgr_earliest_arrival` / `CgrRoute`
- `FlowMonitor` / `record_tx!` / `record_rx!` / `record_drop!` / `flow_summary`
- `UdpHeader` / `udp_payload_bytes`
- `simulate_tcp_reno` / `TcpRenoConfig` / `TcpRenoResult`

### Phase 3 — Bundle / LTP / PCAP
- `Bundle` / `BundleEID` / `BundleStore` / `fragment_bundle` / `serialize_bundle`
- `LtpSession` / `ltp_segment!` / `simulate_ltp_transfer`
- `simulate_dtn_forward` / `DtnNode` / `DtnSimResult`
- `open_pcap` / `write_pcap_packet!` / `close_pcap!`

### Phase 4 — 双档对齐 / 验证基线
- `compare_path_fidelity` / `DualFidelityResult`
- `compare_to_md1` / `md1_mean_wait_s` / `Md1Baseline`
- `Ns3Scenario` / `export_ns3_scenario`
- `scripts/validate_phase4.jl`（Iridium 路径 + GMAT 轨道交叉）
- 文档：`docs/VALIDATION.md`

## 与 archive 的关系

`src/_archive/legacy_layers/09_protocol/netsim/` 仍保留更完整的实验性栈。  
正式包走干净、可测试的子集；外部 ns-3 对比用导出的 scenario JSON。

## 架构红线

**不要把 DES 放进可微优化路径。** `optimize_coverage` 继续走解析层。
