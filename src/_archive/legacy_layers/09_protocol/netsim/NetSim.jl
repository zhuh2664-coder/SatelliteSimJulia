"""
    NetSim — 太空互联网仿真平台

协议栈按真实 LEO 卫星互联网设计：
  地面段 ← UDP/IP → 网关 ← Bundle/LTP → 卫星网格 ← DRA/SDRA → 卫星网格 → ...
                            ↑ 集中路由控制面 (地面) ↑

太空协议栈 (ISL):    地面段 (用于网关):    不包含:
  Bundle/BPv7           IPv4/UDP              ❌ TCP (太空不用)
  LTP                   PointToPoint          ❌ WiFi/CSMA
  DRA/SDRA              StaticRouting         ❌ OSPF/BGP
  CGR + ContactPlan     UdpEcho               ❌ LTE/5G
  Semantic IPv6         PacketSink            ❌ ARP/ICMP/DHCP
  Proximity-1/USLP                             ❌ 所有地面MAC
  集中路由控制
  SDN控制面
"""
module NetSim

# === Core ===
include("core/time.jl")
include("core/packet.jl")
include("core/random.jl")
include("core/simulator.jl")
include("core/distributed.jl")

# === Node ===
include("node/node.jl")

# === Queue ===
include("queue/queue.jl")
include("queue/drop_tail.jl")
include("queue/red.jl")
include("queue/coDel.jl")

# === Channel (仅 P2P, 用于 ISL) ===
include("channel/channel.jl")
include("channel/point_to_point.jl")

# === NetDevice (仅 P2P, 用于 ISL) ===
include("netdevice/netdevice.jl")
include("netdevice/point_to_point.jl")
include("netdevice/emu.jl")

# === 地面网络层 (最小集: 仅地面网关用) ===
include("internet/ipv4.jl")
include("internet/udp.jl")
include("internet/tcp_ground.jl")

# === 地面路由 (最小集) ===
include("routing/routing.jl")
include("routing/static.jl")
include("routing/global.jl")

# === 地面应用 (最小集: 仅地面段用) ===
include("app/packet_sink.jl")
include("app/udp_echo.jl")

# === Bridge (与 SatelliteSimJulia 对接) ===
include("bridge.jl")

# === 太空协议栈 (ISL 网络) ===
include("space/semantic.jl")
include("space/dra.jl")
include("space/sdra.jl")
include("space/contact_plan.jl")
include("space/cgr.jl")
include("space/bundle.jl")
include("space/ltp.jl")
include("space/proximity.jl")
include("space/centralized_routing.jl")
include("space/sdn.jl")
include("space/bpa.jl")
include("space/multishell.jl")

# === Starlink 流量层 ===

# === Monitor ===
include("monitor/flow_monitor.jl")
include("monitor/pcap.jl")
include("datalink/space_packet.jl")
include("datalink/uslp.jl")
include("space/starlink.jl")

# === PHY (纯太空: 自由空间 + 定向天线, 无 WiFi/LTE) ===
include("phy/loss_model.jl")
include("phy/antenna.jl")
include("phy/spectrum.jl")
include("phy/energy.jl")
include("phy/ntn.jl")

# === 导出 ===
# Core
export Time, Second, Milli, Micro, Nano
export Packet, next_pkt_id!
export Initialize, Schedule, Run, Stop, Now, Reset, IsRunning, GetEnv
export DistributedSim, partition_constellation
export UniformRandom, ExponentialRandom, NormalRandom, ConstantRandom

# Node/Queue/Channel/Device (最小集)
export NodeContainer, Node, Create, Get, GetId, AddDevice
export Queue, DropTailQueue, RedQueue, CoDelQueue
export Enqueue, Dequeue, Peek, Drop, BytesInQueue
export Channel, PointToPointChannel
export GetDelay, GetDevice, GetNDevices, Transmit, Attach, SetDelay
export NetDevice, PointToPointDevice
export GetNode, GetChannel, Send, Receive, SetQueue, GetQueue, SetRecvCallback, IsLinkUp

# 地面协议 (最小集)
export Ipv4Address, Ipv4Mask
export UdpSocket, Bind, Connect
export TcpSock, TcpPkt, connect!, synack!, send!, ack!, sack!
export tcp_input!, on_loss!, on_timeout!, pacing_delay, inflight
export CC_BBRv2, CC_CUBIC
export Ipv4RoutingProtocol, StaticRouting, GlobalRouting
export AddRoute, RouteOutput
export PacketSinkApp
export UdpEchoApp

# 太空协议
export SemanticAddress, encode, to_ipv6, from_orbit_params, orbital_distance, is_neighbor
export DraState, dra_route, dra_reroute, DIR_FWD, DIR_BACK, DIR_LEFT, DIR_RIGHT
export SdraState, sdra_forward
export Contact, ContactPlan, add_contact!, cgr_shortest_path, build_from_pos!
export TimeContact, cgr_route, cgr_multipath, cgr_eto, cgr_bia, cgr_lsa
export neighbors_at, active_contacts, contact_schedule, contact_stats
export predict_contacts, is_reachable_at, prune_contacts!, merge_plan!
export rebuild_adjacency!, validate_path, route_compare
export CgrRouteTable, update_routes!, get_next_hop, fast_reroute!
export partition_cgr
export Bundle, BundleStore, BundleEID, CanonicalBlock, BPv7_VERSION
export store_bundle!, forward_bundle!, custody_transfer!, is_expired
export set_previous_node!, update_bundle_age!, set_hop_limit!, decrement_hop!
export send_data!, send_checkpoint, receive_report!, process_retransmit!
export reassemble_red!, reassemble_green!, ltp_timed_out, ltp_stats
export fragment_bundle, reassemble_bundles, next_bundle_seq!
export serialize, get_payload, set_payload!, add_block!
export LtpSession, LtpSegment, segment_data, send_checkpoint, receive_report, process_timeout, reassemble
export SpacePacket, SpacePacketHeader, VirtualChannel, make_pkt_hdr
export encode, add_packet!, get_packets
export UslpFrame, UslpFrameHeader, MasterChannel, transmit_frame, receive_frame
export compute_crc16, segment_data, reassemble_frames, Clcw
export Proximity1Link, Proximity1Frame, USLPFrame, encode_frame, receive_frame, set_signal_quality
export CentralizedRoutingTable, build_routes_from_pos!, get_next_hop, fast_reroute, update_route!
export FlowTable, FlowEntry, FlowMatch, FlowAction, SdnController, push_flow!, delete_flow!, add_flow!, match_packet
export BundleProtocolAgent, ConvergenceLayerAdapter, add_cla!, bundle_created!, forward_bundle!
export select_cla, bundle_delivered!, periodic_housekeeping!, bundle_stats, CfdpTransaction
export cfdp_put, cfdp_get, cfdp_status, cfdp_eof!
export CLA_LTP, CLA_UDP, CLA_TCP
export ShellConfig, MultiShellConstellation
export generate_multishell_pos, shell_range, cross_shell_distance
export build_multishell_contacts, print_multishell, same_shell
export STARLINK_SHELLS
export ltp_start_timer!, ltp_stop_timer!, ltp_timer_expired, ltp_next_timeout

# Starlink
export HandoverConfig, HandoverApp, handover_state, update_handover!
export DynamicIslChannel, build_dynamic_isl!, update_isl_delay!
export GslLink, compute_elevation, compute_path_loss, update_gsl!
export StarlinkScenario, run_starlink_scenario

# NTN
export NtnCell, NtnUe, NtnGnb, FeederLink, handover!, schedule_ntn

# Monitor
export FlowMonitor, FlowStats
export RecordTx, RecordRx, RecordDrop, GetFlowStats, PrintFlowStats, ToDataFrame
export OpenPcap, WritePacket, ClosePcap, PcapWriter

# PHY
export free_space_loss, atmospheric_loss, total_path_loss, compute_doppler, link_budget
export AntennaModel, IsotropicAntenna, ParabolicAntenna
export UniformPlanarArray, ThreeGppAntenna, gain
export SpectrumChannel, SpectrumValue, OfdmParams, sinr, add_signal, clear_signals, interference_probability, noise_power
export EnergySource, LiIonBattery, SolarPanel, SatelliteEnergyModel
export NtnChannelConfig, NtnChannelState, ntn_channel, ntn_los_probability
export ntn_k_factor, ntn_apply_fading, NtnGwConfig, ntn_feeder_link
export remaining_energy, remaining_pct, total_power, update_energy!
export discharge!, charge!, harvest_power

# Bridge
export SatelliteConfig, run_packet_sim, run_traffic_matrix

end # module
