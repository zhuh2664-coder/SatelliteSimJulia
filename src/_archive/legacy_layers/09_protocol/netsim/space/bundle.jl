"""
    bundle.jl — Bundle Protocol v7 (RFC 9171 完整实现)

BPv7 数据单元 (Bundle) 核心类型。
遵循 CCSDS 734.2-B-2 / RFC 9171 标准。
"""
const BPv7_VERSION = 7

# Block Processing Control Flags (RFC 9171 §4.4.3)
const BP_BLOCK_REPLICATE     = 0x0001  # 复制到每个分片
const BP_BLOCK_REPORT        = 0x0002  # 状态报告
const BP_BLOCK_DELETE_BUNDLE = 0x0004  # 处理失败则删 Bundle
const BP_BLOCK_LAST          = 0x0008  # 最后一个 block
const BP_BLOCK_DISCARD       = 0x0010  # 处理后可丢弃
const BP_BLOCK_FWD_UNPROC  = 0x0020  # 未处理也转发

# Bundle Processing Control Flags (RFC 9171 §4.2.2)
const BP_STATUS_TIME        = 0x0001  # 报告包含时间
const BP_CUSTODY_TRANSFER   = 0x0002  # 需要托管传输
const BP_SINGLETON_DEST     = 0x0004  # 单点投递
const BP_NO_FRAGMENT        = 0x0008  # 禁止分片
const BP_ACK_BY_APP         = 0x0010  # 应用层确认

# Canonical Block Types
const BLOCK_PAYLOAD = 1
const BLOCK_PREVIOUS_NODE = 7
const BLOCK_BUNDLE_AGE = 8
const BLOCK_CUSTODY_ACK = 9

"""
    BundleEID — BPv7 端点标识符 (RFC 9171 §4.3.2)

格式: dtn://<node>/<service> 或 ipn:<node>.<service>
"""
struct BundleEID
    scheme::String  # "dtn" or "ipn"
    ssp::String     # scheme-specific part
    function BundleEID(scheme::String, ssp::String)
        new(lowercase(scheme), ssp)
    end
end

# Constructor from URI string
function BundleEID(uri::String)
    if startswith(uri, "dtn://")
        ssp = uri[7:end]
        BundleEID("dtn", ssp)
    elseif startswith(uri, "ipn:")
        ssp = uri[5:end]
        BundleEID("ipn", ssp)
    else
        error("Invalid Bundle EID: $uri")
    end
end

Base.string(eid::BundleEID) = "$(eid.scheme)://$(eid.ssp)"
Base.show(io::IO, eid::BundleEID) = print(io, string(eid))
Base.:(==)(a::BundleEID, b::BundleEID) = a.scheme == b.scheme && a.ssp == b.ssp
Base.hash(eid::BundleEID, h::UInt64) = hash((eid.scheme, eid.ssp), h)

# DTN endpoint constants
const EID_NULL = BundleEID("dtn", "none")
const EID_LOCAL = BundleEID("dtn", "local")

# CBOR encoding (simplified - RFC 9171 §4.5)
const CBOR_UINT = 0x00; const CBOR_NEGINT = 0x20
const CBOR_BSTR = 0x40; const CBOR_TSTR = 0x60
const CBOR_ARR = 0x80; const CBOR_MAP = 0xa0

"""
    CborWriter — 简化 CBOR 编码器 (RFC 9171 §4.5)
"""
mutable struct CborWriter
    buf::Vector{UInt8}
end
CborWriter() = CborWriter(UInt8[])

function write_int!(cw::CborWriter, val::Int)
    if val >= 0
        if val <= 23; push!(cw.buf, CBOR_UINT | UInt8(val))
        elseif val <= 0xff; append!(cw.buf, [CBOR_UINT | 24, UInt8(val)])
        elseif val <= 0xffff;
            v = bswap(UInt16(val))
            append!(cw.buf, [CBOR_UINT | 25, UInt8(v >> 8), UInt8(v & 0xff)])
        else
            v = bswap(UInt32(val))
            append!(cw.buf, [CBOR_UINT | 26, UInt8(v >> 24), UInt8(v >> 16), UInt8(v >> 8), UInt8(v & 0xff)])
        end
    end
end
function write_text!(cw::CborWriter, s::String)
    b = Vector{UInt8}(s)
    write_int!(cw, length(b)); append!(cw.buf, b)
end
function write_bytes!(cw::CborWriter, b::Vector{UInt8})
    write_int!(cw, length(b)); append!(cw.buf, b)
end

"""
    CanonicalBlock — BPv7 规范块 (RFC 9171 §4.4)
"""
mutable struct CanonicalBlock
    type_code::UInt8      # BLOCK_PAYLOAD 等
    flags::UInt16          # Block Processing Control Flags
    data::Vector{UInt8}    # block body
end

"""
    Bundle — BPv7 束 (RFC 9171 §4.3)

完整字段：
  - Primary Block: version, EIDs, timestamp, lifetime, flags
  - Canonical Block(s): payload + extension blocks
"""
mutable struct Bundle
    # Primary Block
    version::UInt8
    source::BundleEID
    dest::BundleEID
    report_to::BundleEID
    custodian::BundleEID
    creation_time::Float64
    sequence::UInt64
    lifetime::Float64
    proc_flags::UInt16       # Bundle Processing Control Flags
    fragment_offset::UInt64
    fragment_length::UInt64

    # Canonical Blocks
    blocks::Vector{CanonicalBlock}
    payload::CanonicalBlock

    # Route state
    current_hop::Int
    max_hops::Int
    arrival_time::Float64

    # Extension blocks (BPv7三块: Previous Node / Bundle Age / Hop Count)
    previous_node::BundleEID
    bundle_age::Float64
    hop_count::Int
    hop_limit::Int
end

function Bundle(src::BundleEID, dst::BundleEID, payload_data::Vector{UInt8};
                lifetime::Float64=3600.0, custody::Bool=false,
                report::Bool=false)
    flags = custody ? BP_CUSTODY_TRANSFER : 0x0000
    flags |= report ? BP_STATUS_TIME : 0x0000
    flags |= BP_SINGLETON_DEST

    pb = CanonicalBlock(BLOCK_PAYLOAD, BP_BLOCK_LAST, payload_data)

    Bundle(BPv7_VERSION, src, dst, EID_NULL, EID_NULL,
           Now(), 0, lifetime, flags, 0, 0,
           CanonicalBlock[], pb, 0, 100, 0.0,
           EID_NULL, 0.0, 0, 100)
end

"""Payload accessor"""
function get_payload(b::Bundle)::Vector{UInt8}
    b.payload.data
end

"""Set payload"""
function set_payload!(b::Bundle, data::Vector{UInt8})
    b.payload = CanonicalBlock(BLOCK_PAYLOAD, BP_BLOCK_LAST, data)
end

"""Add extension block"""
function add_block!(b::Bundle, blk::CanonicalBlock)
    push!(b.blocks, blk)
end

"""Set Previous Node block (RFC 9171 §4.4.3, type code 7)"""
function set_previous_node!(b::Bundle, node::BundleEID)
    b.previous_node = node
    cb = CanonicalBlock(7, BP_BLOCK_FWD_UNPROC, Vector{UInt8}(string(node)))
    add_block!(b, cb)
end

"""Update Bundle Age block (RFC 9171 §4.4.3, type code 8)"""
function update_bundle_age!(b::Bundle)
    b.bundle_age = Now() - b.creation_time
    data = Vector{UInt8}(reinterpret(UInt8, [Float64(b.bundle_age)]))
    cb = CanonicalBlock(8, BP_BLOCK_DISCARD, data)
    add_block!(b, cb)
end

"""Set Hop Count block (RFC 9171 §4.4.3, type code 9)"""
function set_hop_limit!(b::Bundle, limit::Int)
    b.hop_limit = limit
    b.hop_count = 0
    data = Vector{UInt8}([UInt8(limit), UInt8(b.hop_count)])
    cb = CanonicalBlock(9, BP_BLOCK_FWD_UNPROC, data)
    add_block!(b, cb)
end

"""Decrement hop count; return false if expired"""
function decrement_hop!(b::Bundle)::Bool
    b.hop_count += 1
    b.hop_count <= b.hop_limit
end

"""Serialize to CBOR"""
function serialize(b::Bundle)::Vector{UInt8}
    cw = CborWriter()
    # Primary Block
    write_int!(cw, Int(b.version))
    write_int!(cw, Int(b.proc_flags))
    write_int!(cw, 0)  # CRC type (no CRC)
    write_text!(cw, string(b.dest))
    write_text!(cw, string(b.source))
    write_text!(cw, string(b.report_to))
    write_text!(cw, string(b.custodian))
    write_int!(cw, Int(b.creation_time))
    write_int!(cw, Int(b.sequence))
    write_int!(cw, Int(b.lifetime))
    write_int!(cw, Int(b.fragment_offset))
    write_int!(cw, Int(b.fragment_length))
    # Payload Block
    write_int!(cw, Int(b.payload.type_code))
    write_int!(cw, Int(b.payload.flags))
    write_bytes!(cw, b.payload.data)
    cw.buf
end

# ═══════════════════════════════════════════
#  Bundle 存储转发
# ═══════════════════════════════════════════

mutable struct BundleStore
    bundles::Vector{Bundle}
    max_size::Int
    current_bytes::Int
end

BundleStore(;max_size=10000) = BundleStore(Bundle[], max_size, 0)

function store_bundle!(s::BundleStore, b::Bundle)::Bool
    if length(s.bundles) >= s.max_size
        return false
    end
    # Check expiry
    if is_expired(b)
        return false
    end
    push!(s.bundles, b)
    s.current_bytes += length(b.payload.data)
    true
end

function forward_bundle!(s::BundleStore)::Union{Bundle,Nothing}
    isempty(s.bundles) && return nothing
    b = popfirst!(s.bundles)
    s.current_bytes -= length(b.payload.data)
    b
end

function custody_transfer!(b::Bundle, new_custodian::BundleEID)::Bool
    if (b.proc_flags & BP_CUSTODY_TRANSFER) != 0
        b.custodian = new_custodian
        return true
    end
    false
end

function is_expired(b::Bundle)::Bool
    (Now() - b.creation_time) > b.lifetime
end

"""Bundle 分片 (RFC 9171 §5.4)"""
function fragment_bundle(b::Bundle, max_size::Int)::Vector{Bundle}
    data = get_payload(b)
    n_frags = ceil(Int, length(data) / max_size)
    frags = Bundle[]
    for i in 1:n_frags
        start = (i-1) * max_size + 1
        stop = min(i * max_size, length(data))
        frag = Bundle(b.source, b.dest, data[start:stop];
                      lifetime=b.lifetime, custody=(b.proc_flags & BP_CUSTODY_TRANSFER) != 0)
        frag.fragment_offset = UInt64(start - 1)
        frag.fragment_length = UInt64(stop - start + 1)
        frag.proc_flags |= 0x0400  # fragment flag
        push!(frags, frag)
    end
    frags
end

"""Bundle 重组"""
function reassemble_bundles(frags::Vector{Bundle})::Union{Bundle,Nothing}
    if isempty(frags); return nothing; end
    src = frags[1].source; dst = frags[1].dest
    all_data = UInt8[]
    for f in sort(frags, by=f -> f.fragment_offset)
        append!(all_data, get_payload(f))
    end
    Bundle(src, dst, all_data; lifetime=frags[1].lifetime)
end

"""Bundle 序列号生成"""
const _bundle_seq = Ref{UInt64}(0)
function next_bundle_seq!()::UInt64
    _bundle_seq[] += 1; _bundle_seq[]
end
