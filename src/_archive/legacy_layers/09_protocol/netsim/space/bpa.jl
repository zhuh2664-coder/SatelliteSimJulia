
using ResumableFunctions

# Convergence Layer Adapter types
const CLA_LTP = 1
const CLA_UDP = 2
const CLA_TCP = 3

mutable struct ConvergenceLayerAdapter
    cla_type::Int
    local_eid::BundleEID
    remote_eid::BundleEID
    is_active::Bool
    tx_count::Int
    rx_count::Int
    mtu::Int
end

mutable struct BundleProcessingFlags
    status_time::Bool
    custody_transfer::Bool
    singleton_dest::Bool
    no_fragment::Bool
    ack_by_app::Bool
end

"""
    BundleProtocolAgent — DTN 节点主代理

每颗卫星运行一个 BPA 实例。
"""
mutable struct BundleProtocolAgent
    node_id::UInt32
    local_eid::BundleEID
    store::BundleStore
    contact_plan::ContactPlan
    route_table::CgrRouteTable
    clas::Vector{ConvergenceLayerAdapter}

    # Current route
    current_path::Vector{UInt32}
    current_path_time::Float64

    # Stats
    bundles_created::Int
    bundles_forwarded::Int
    bundles_delivered::Int
    bundles_expired::Int
    bundles_stored::Int

    # Convergence layer dispatching
    default_cla::Int
end

function BundleProtocolAgent(eid::BundleEID, cp::ContactPlan, nid::UInt32=UInt32(1))
    rt = CgrRouteTable(nid, cp)
    store = BundleStore()
    BundleProtocolAgent(nid, eid, store, cp, rt, ConvergenceLayerAdapter[],
                        UInt32[], 0.0, 0, 0, 0, 0, 0, CLA_LTP)
end

"""
    add_cla!(bpa, cla_type, remote_eid, mtu)

注册一个 Convergence Layer Adapter。
"""
function add_cla!(bpa::BundleProtocolAgent, cla_type::Int, remote::BundleEID, mtu::Int=1400)
    cla = ConvergenceLayerAdapter(cla_type, bpa.local_eid, remote, true, 0, 0, mtu)
    push!(bpa.clas, cla)
end

"""
    bundle_created!(bpa, bundle)

BPA 收到上层应用创建的 Bundle。
"""
function bundle_created!(bpa::BundleProtocolAgent, bundle::Bundle)
    bpa.bundles_created += 1

    # 检查是否发往本地
    if bundle.dest == bpa.local_eid
        bundle_delivered!(bpa, bundle)
        return
    end

    # 检查是否过期
    if is_expired(bundle)
        bpa.bundles_expired += 1
        return
    end

    # 存储转发
    if store_bundle!(bpa.store, bundle)
        bpa.bundles_stored += 1
        # 触发转发
        forward_bundle!(bpa, bundle)
    end
end

"""
    forward_bundle!(bpa, bundle)

CGR 路由决策 + CLA 分发。
"""
function forward_bundle!(bpa::BundleProtocolAgent, bundle::Bundle)
    # 更新路由表
    update_routes!(bpa.route_table, Now())

    # CGR 寻路
    dest_id = parse(UInt32, bundle.dest.ssp)  # 简化: EID → node ID
    dest_node = max(dest_id, UInt32(1))  # 确保 >= 1 (Julia 1-indexed)
    bsz = Float64(length(get_payload(bundle)))
    path, delay, _ = cgr_route(bpa.contact_plan, bpa.node_id, dest_node, Now();
                                bundle_size=bsz)

    if isempty(path)
        # 无路径: 留在存储中等待
        return
    end

    # 选 Convergence Layer
    cla = select_cla(bpa, bundle.dest)
    if cla === nothing
        return  # 无可用 CLA
    end

    # 通过 CLA 发送
    if cla.cla_type == CLA_LTP
        send_via_ltp(bpa, bundle, path)
    elseif cla.cla_type == CLA_UDP
        send_via_udp(bpa, bundle, path)
    end

    bpa.bundles_forwarded += 1
    bpa.current_path = path
    bpa.current_path_time = Now()

    # Custody Transfer
    if (bundle.proc_flags & BP_CUSTODY_TRANSFER) != 0
        custody_transfer!(bundle, bpa.local_eid)
    end
end

"""
    select_cla(bpa, dest_eid) → CLA | nothing

选择最合适的 Convergence Layer。
"""
function select_cla(bpa::BundleProtocolAgent, dest::BundleEID)
    for cla in bpa.clas
        if cla.is_active && cla.remote_eid == dest
            return cla
        end
    end
    # 返回第一个活跃 CLA
    for cla in bpa.clas
        if cla.is_active
            return cla
        end
    end
    nothing
end

"""
    send_via_ltp(bpa, bundle, path)

通过 LTP 发送 Bundle。
"""
function send_via_ltp(bpa::BundleProtocolAgent, bundle::Bundle, path::Vector{UInt32})
    session = LtpSession(UInt64(Now()*1000), UInt64(0), UInt64(path[1]))
    payload = get_payload(bundle)
    segments = segment_data(session, payload)

    # 发送所有段 (通过下层 USLP 帧)
    for seg in segments
        push!(bpa.store.bundles, bundle)  # 保留 pending
    end
end

"""
    send_via_udp(bpa, bundle, path)

通过 UDP 发送 Bundle (简化: 直接封装)。
"""
function send_via_udp(bpa::BundleProtocolAgent, bundle::Bundle, path::Vector{UInt32})
    # 地面段使用: 直接通过网关转发
    nothing
end

"""
    bundle_delivered!(bpa, bundle)

Bundle 到达目的地。
"""
function bundle_delivered!(bpa::BundleProtocolAgent, bundle::Bundle)
    bpa.bundles_delivered += 1
    payload = get_payload(bundle)
    # 通知上层应用
    nothing
end

"""
    periodic_housekeeping!(bpa, t)

定期维护: 清理过期 Bundle、更新路由表。
"""
function periodic_housekeeping!(bpa::BundleProtocolAgent, t::Float64)
    # 清理过期
    bpa.store.bundles = filter(b -> !is_expired(b), bpa.store.bundles)

    # 尝试转发积压
    for bundle in bpa.store.bundles
        if t - bundle.arrival_time > 1.0  # 至少等 1 秒再试
            forward_bundle!(bpa, bundle)
        end
    end

    # 更新路由
    update_routes!(bpa.route_table, t)
end

"""
    bundle_stats(bpa) → Dict

BPA 统计信息。
"""
function bundle_stats(bpa::BundleProtocolAgent)
    Dict(
        :created => bpa.bundles_created,
        :forwarded => bpa.bundles_forwarded,
        :delivered => bpa.bundles_delivered,
        :expired => bpa.bundles_expired,
        :stored => bpa.bundles_stored,
        :in_store => length(bpa.store.bundles),
        :store_bytes => bpa.store.current_bytes,
    )
end

# ── CFDP (CCSDS File Delivery Protocol) 存根 ──

"""
    CfdpTransaction — CFDP 文件传输事务

CCSDS 727.0-B-5 文件传输协议简化实现。
"""
mutable struct CfdpTransaction
    source::BundleEID
    dest::BundleEID
    filename::String
    total_bytes::Int
    sent_bytes::Int
    is_complete::Bool
end

function cfdp_put(bpa::BundleProtocolAgent, dest::BundleEID, data::Vector{UInt8}, filename::String)
    # 将文件分割为 Bundle 发送
    mtu = 1400
    chunks = [data[i:min(i+mtu-1, end)] for i in 1:mtu:length(data)]

    for (i, chunk) in enumerate(chunks)
        b = Bundle(bpa.local_eid, dest, chunk;
                   lifetime=3600.0, custody=true, report=true)
        bundle_created!(bpa, b)
    end

    CfdpTransaction(bpa.local_eid, dest, filename, length(data), 0, false)
end

function cfdp_status(tx::CfdpTransaction)
    Dict(:filename=>tx.filename, :total=>tx.total_bytes, :sent=>tx.sent_bytes, :complete=>tx.is_complete)
end

function cfdp_get(bpa::BundleProtocolAgent, source::BundleEID)
    bundles = [b for b in bpa.store.bundles if b.source == source]
    isempty(bundles) && return nothing
    data = UInt8[]; for b in bundles; append!(data, get_payload(b)); end; data
end

function cfdp_eof!(tx::CfdpTransaction); tx.is_complete = true; end
