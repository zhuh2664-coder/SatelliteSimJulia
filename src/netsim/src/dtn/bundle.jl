# Bundle Protocol v7 — minimal subset (RFC 9171)

export BundleEID, Bundle, BundleStore, CanonicalBlock
export BPv7_VERSION, EID_NULL, EID_LOCAL
export BP_CUSTODY_TRANSFER, BP_SINGLETON_DEST, BP_NO_FRAGMENT
export get_payload, set_payload!, is_expired, store_bundle!, take_bundle!
export fragment_bundle, reassemble_bundles, next_bundle_seq!, reset_bundle_seq!
export serialize_bundle

const BPv7_VERSION = 7

const BP_CUSTODY_TRANSFER = 0x0002
const BP_SINGLETON_DEST   = 0x0004
const BP_NO_FRAGMENT      = 0x0008
const BP_IS_FRAGMENT      = 0x0400

const BLOCK_PAYLOAD = UInt8(1)

"""
    BundleEID

Endpoint ID: `dtn://node/service` or `ipn:node.service`.
"""
struct BundleEID
    scheme::String
    ssp::String
end

function BundleEID(uri::AbstractString)
    s = String(uri)
    if startswith(s, "dtn://")
        return BundleEID("dtn", s[7:end])
    elseif startswith(s, "ipn:")
        return BundleEID("ipn", s[5:end])
    else
        throw(ArgumentError("Invalid Bundle EID: $s"))
    end
end

Base.string(eid::BundleEID) =
    eid.scheme == "ipn" ? "ipn:$(eid.ssp)" : "dtn://$(eid.ssp)"
Base.show(io::IO, eid::BundleEID) = print(io, string(eid))
Base.:(==)(a::BundleEID, b::BundleEID) = a.scheme == b.scheme && a.ssp == b.ssp
Base.hash(eid::BundleEID, h::UInt) = hash((eid.scheme, eid.ssp), h)

const EID_NULL = BundleEID("dtn", "none")
const EID_LOCAL = BundleEID("dtn", "local")

"""Canonical block (payload / extension)."""
mutable struct CanonicalBlock
    type_code::UInt8
    flags::UInt16
    data::Vector{UInt8}
end

"""
    Bundle

BPv7 primary block + payload (simplified; no full CBOR round-trip).
"""
mutable struct Bundle
    version::UInt8
    source::BundleEID
    dest::BundleEID
    report_to::BundleEID
    custodian::BundleEID
    creation_time::Float64
    sequence::UInt64
    lifetime::Float64
    proc_flags::UInt16
    fragment_offset::UInt64
    fragment_length::UInt64
    payload::CanonicalBlock
    hop_count::Int
    hop_limit::Int
end

const _BUNDLE_SEQ = Ref{UInt64}(0)
next_bundle_seq!() = (_BUNDLE_SEQ[] += 1; _BUNDLE_SEQ[])
reset_bundle_seq!() = (_BUNDLE_SEQ[] = 0; nothing)

function Bundle(
    src::BundleEID,
    dst::BundleEID,
    payload_data::Vector{UInt8};
    lifetime::Float64=3600.0,
    custody::Bool=false,
    creation_time::Float64=0.0,
    hop_limit::Int=32,
)
    flags = UInt16(BP_SINGLETON_DEST)
    custody && (flags |= BP_CUSTODY_TRANSFER)
    seq = next_bundle_seq!()
    pb = CanonicalBlock(BLOCK_PAYLOAD, 0x0008, copy(payload_data))
    return Bundle(
        UInt8(BPv7_VERSION), src, dst, EID_NULL, EID_NULL,
        creation_time, seq, lifetime, flags, UInt64(0), UInt64(0),
        pb, 0, hop_limit,
    )
end

get_payload(b::Bundle) = b.payload.data
function set_payload!(b::Bundle, data::Vector{UInt8})
    b.payload = CanonicalBlock(BLOCK_PAYLOAD, 0x0008, copy(data))
    return b
end

is_expired(b::Bundle, now::Real) = (Float64(now) - b.creation_time) > b.lifetime

"""
    BundleStore

Custody / store-and-forward buffer at a DTN node.
"""
mutable struct BundleStore
    bundles::Vector{Bundle}
    max_bundles::Int
    current_bytes::Int
end

BundleStore(; max_bundles::Int=10_000) = BundleStore(Bundle[], max_bundles, 0)

function store_bundle!(s::BundleStore, b::Bundle; now::Real=0.0)::Bool
    length(s.bundles) >= s.max_bundles && return false
    is_expired(b, now) && return false
    push!(s.bundles, b)
    s.current_bytes += length(get_payload(b))
    return true
end

function take_bundle!(s::BundleStore)::Union{Bundle,Nothing}
    isempty(s.bundles) && return nothing
    b = popfirst!(s.bundles)
    s.current_bytes -= length(get_payload(b))
    return b
end

function fragment_bundle(b::Bundle, max_size::Int)::Vector{Bundle}
    max_size > 0 || throw(ArgumentError("max_size must be positive"))
    data = get_payload(b)
    length(data) <= max_size && return [b]
    frags = Bundle[]
    for start in 1:max_size:length(data)
        stop = min(start + max_size - 1, length(data))
        frag = Bundle(b.source, b.dest, data[start:stop];
                      lifetime=b.lifetime,
                      custody=(b.proc_flags & BP_CUSTODY_TRANSFER) != 0,
                      creation_time=b.creation_time,
                      hop_limit=b.hop_limit)
        frag.fragment_offset = UInt64(start - 1)
        frag.fragment_length = UInt64(stop - start + 1)
        frag.proc_flags |= BP_IS_FRAGMENT
        frag.sequence = b.sequence
        push!(frags, frag)
    end
    return frags
end

function reassemble_bundles(frags::Vector{Bundle})::Union{Bundle,Nothing}
    isempty(frags) && return nothing
    sorted = sort(frags, by=f -> f.fragment_offset)
    all_data = UInt8[]
    for f in sorted
        append!(all_data, get_payload(f))
    end
    out = Bundle(sorted[1].source, sorted[1].dest, all_data;
                 lifetime=sorted[1].lifetime, creation_time=sorted[1].creation_time)
    out.sequence = sorted[1].sequence
    return out
end

"""Compact binary serialization (not full CBOR; stable for pcap/tests)."""
function serialize_bundle(b::Bundle)::Vector{UInt8}
    src_s = string(b.source)
    dst_s = string(b.dest)
    payload = get_payload(b)
    io = IOBuffer()
    write(io, UInt8(b.version))
    write(io, htol(UInt16(b.proc_flags)))
    write(io, htol(UInt16(length(src_s))))
    write(io, Vector{UInt8}(src_s))
    write(io, htol(UInt16(length(dst_s))))
    write(io, Vector{UInt8}(dst_s))
    write(io, htol(UInt64(b.sequence)))
    write(io, htol(UInt32(length(payload))))
    write(io, payload)
    return take!(io)
end
