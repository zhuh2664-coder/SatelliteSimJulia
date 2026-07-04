# ── Link state/type hierarchy ─────────────────────────────────────────────────
# 共享类型，被 Layer 02 (link) 和 Layer 03 (topology) 共同依赖

export AbstractLinkType, AbstractLinkState,
       InterSatelliteLink, GroundSatelliteLink,
       LinkAvailable, LinkUnavailable

abstract type AbstractLinkType end
abstract type AbstractLinkState end
struct InterSatelliteLink <: AbstractLinkType end
struct GroundSatelliteLink <: AbstractLinkType end
struct LinkAvailable <: AbstractLinkState end
struct LinkUnavailable <: AbstractLinkState end
