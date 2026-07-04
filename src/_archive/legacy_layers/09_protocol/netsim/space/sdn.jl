"""
    sdn.jl — 星载 SDN 控制面 (软件定义卫星网络)

OpenFlow 风格控制器：
1. SDN 控制器 (地面) 下发流表到卫星
2. 卫星按流表匹配转发
3. 支持主动/被动模式
"""
const OFP_MATCH_IN_PORT  = 0x01
const OFP_MATCH_ETH_DST  = 0x02
const OFP_MATCH_IP_DST   = 0x04
const OFP_MATCH_UDP_PORT = 0x08
const OFP_MATCH_TCP_PORT = 0x10
const OFP_MATCH_SAT_ID   = 0x20

const OFP_ACTION_OUTPUT   = 0x01
const OFP_ACTION_DROP     = 0x02
const OFP_ACTION_SET_FIELD = 0x03
const OFP_ACTION_FORWARD  = 0x04

mutable struct FlowMatch
    fields::Dict{UInt8, UInt64}  # match_type → value
end

mutable struct FlowAction
    action_type::UInt8
    value::UInt64
end

mutable struct FlowEntry
    priority::Int
    match::FlowMatch
    actions::Vector{FlowAction}
    packets_matched::Int
    bytes_matched::Int
    idle_timeout::Float64
    hard_timeout::Float64
    installed_at::Float64
end

""" SDN 流表 (每颗卫星一个) """
mutable struct FlowTable
    entries::Vector{FlowEntry}
    default_action::UInt8  # 默认动作: 0=drop, 1=forward_to_controller
end

FlowTable() = FlowTable(FlowEntry[], 1)

function add_flow!(ft::FlowTable, match::FlowMatch, actions::Vector{FlowAction}; priority=100, idle=0.0, hard=0.0)
    push!(ft.entries, FlowEntry(priority, match, actions, 0, 0, idle, hard, Now()))
    sort!(ft.entries, by=e -> e.priority, rev=true)
end

function match_packet(ft::FlowTable, pkt_attrs::Dict{UInt8, UInt64})
    for entry in ft.entries
        matched = true
        for (k, v) in entry.match.fields
            if get(pkt_attrs, k, nothing) != v
                matched = false; break
            end
        end
        if matched
            entry.packets_matched += 1
            entry.bytes_matched += 100  # 近似
            return entry.actions
        end
    end
    return ft.default_action == 1 ? [FlowAction(OFP_ACTION_FORWARD, 0)] : FlowAction[]
end

""" SDN 控制器 (地面) """
mutable struct SdnController
    satellites::Vector{UInt32}
    flow_tables::Dict{UInt32, FlowTable}
end

function push_flow!(ctrl::SdnController, sat_id::UInt32, match::FlowMatch, actions::Vector{FlowAction})
    ft = get!(ctrl.flow_tables, sat_id, FlowTable())
    add_flow!(ft, match, actions)
end

function delete_flow!(ctrl::SdnController, sat_id::UInt32, match::FlowMatch)
    ft = get(ctrl.flow_tables, sat_id, nothing)
    ft === nothing && return
    filter!(e -> e.match != match, ft.entries)
end

""" 安装隔离流表 (链路故障快速切换) """
function install_isolation_routes!(ctrl::SdnController, failed_sat::UInt32, alt_paths::Dict{UInt32, UInt32})
    for (dst, alt_nh) in alt_paths
        m = FlowMatch(Dict(OFP_MATCH_SAT_ID => UInt64(dst)))
        a = [FlowAction(OFP_ACTION_FORWARD, UInt64(alt_nh))]
        push_flow!(ctrl, failed_sat, m, a)
    end
end
