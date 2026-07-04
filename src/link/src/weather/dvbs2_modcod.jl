# ===== DVB-S2/S2X MODCOD 表 + ACM =====
#
# 实现 DVB-S2 (ETSI EN 302 307) 的 MODCOD 查找表：
# SNR 阈值 → 调制 + 码率 → 频谱效率 → 有效容量
#
# ACM (Adaptive Coding & Modulation): 每个时间步按当前 SNR 选最高可用 MODCOD。
#
# 新增于 2026-07-04（Phase 4 - B3）。

export
    Modulation,
    ModcodEntry,
    DVB_S2_MODCODS,
    select_modcod,
    spectral_efficiency,
    effective_capacity_mbps,
    acm_capacity_mbps

# ════════════════════════════════════════════════════════════
# 调制类型
# ════════════════════════════════════════════════════════════

"""DVB-S2 调制方式。"""
struct Modulation
    name::String
    bits_per_symbol::Float64  # 频谱效率的调制分量
end

const QPSK = Modulation("QPSK", 2.0)
const _8PSK = Modulation("8PSK", 3.0)
const _16APSK = Modulation("16APSK", 4.0)
const _32APSK = Modulation("32APSK", 5.0)

# ════════════════════════════════════════════════════════════
# MODCOD 条目
# ════════════════════════════════════════════════════════════

"""
    ModcodEntry

DVB-S2 MODCOD 条目。

# 字段
- `id::Int`: MODCOD 编号
- `modulation::Modulation`: 调制方式
- `code_rate::Rational`: 码率（如 1/2, 3/4）
- `es_n0_threshold_db::Float64`: 所需 Es/N₀ 阈值（dB，PER=1e-5）
- `spectral_efficiency::Float64`: 频谱效率（bit/symbol，含码率）
"""
struct ModcodEntry
    id::Int
    modulation::Modulation
    code_rate::Rational
    es_n0_threshold_db::Float64
    spectral_efficiency::Float64
end

# ════════════════════════════════════════════════════════════
# DVB-S2 MODCOD 表（28 档，按 Es/N₀ 升序）
# 阈值来自 ETSI EN 302 307 Table 5 (PER=1e-5, ideal)
# ════════════════════════════════════════════════════════════

const DVB_S2_MODCODS = ModcodEntry[
    # QPSK (1/4 ~ 3/4)
    ModcodEntry(1,  QPSK,    1//4, -2.35, 0.4901),
    ModcodEntry(2,  QPSK,    1//3, -1.24, 0.6566),
    ModcodEntry(3,  QPSK,    2//5, -0.30, 0.7894),
    ModcodEntry(4,  QPSK,    1//2,  1.00, 0.9888),
    ModcodEntry(5,  QPSK,    3//5,  2.23, 1.1884),
    ModcodEntry(6,  QPSK,    2//3,  3.10, 1.3220),
    ModcodEntry(7,  QPSK,    3//4,  4.03, 1.4876),
    ModcodEntry(8,  QPSK,    4//5,  4.68, 1.5852),
    ModcodEntry(9,  QPSK,    5//6,  5.18, 1.6533),
    # 8PSK (3/4 ~ 5/6)
    ModcodEntry(10, _8PSK,   3//5,  5.50, 1.7656),
    ModcodEntry(11, _8PSK,   2//3,  6.62, 1.9634),
    ModcodEntry(12, _8PSK,   3//4,  7.91, 2.2196),
    ModcodEntry(13, _8PSK,   5//6,  9.35, 2.4612),
    # 16APSK (2/3 ~ 9/10)
    ModcodEntry(14, _16APSK, 2//3,  8.97, 2.6460),
    ModcodEntry(15, _16APSK, 3//4, 10.21, 2.9766),
    ModcodEntry(16, _16APSK, 4//5, 11.03, 3.1740),
    ModcodEntry(17, _16APSK, 5//6, 11.61, 3.3260),
    ModcodEntry(18, _16APSK, 8//9, 12.89, 3.5552),
    ModcodEntry(19, _16APSK, 9//10,13.13, 3.5960),
    # 32APSK (3/4 ~ 9/10)
    ModcodEntry(20, _32APSK, 3//4, 12.73, 3.7256),
    ModcodEntry(21, _32APSK, 4//5, 13.64, 3.9680),
    ModcodEntry(22, _32APSK, 5//6, 14.28, 4.1470),
    ModcodEntry(23, _32APSK, 8//9, 15.69, 4.4200),
    ModcodEntry(24, _32APSK, 9//10,16.05, 4.4760),
]

# ════════════════════════════════════════════════════════════
# MODCOD 选择
# ════════════════════════════════════════════════════════════

"""
    select_modcod(snr_db; modcod_table) -> Union{Nothing,ModcodEntry}

按 SNR 选最高可用 MODCOD。

# 算法
- Es/N₀ ≈ SNR - 10log₁₀(频谱效率)（近似，对 QPSK 1/4）
- 简化：直接用 SNR 比较 Es/N₀ 阈值（因为 SNR = Es/N₀ + 10log₁₀(η)，η=频谱效率）
- 严格做法：对每个 MODCOD 算 Es/N₀ = SNR - 10log₁₀(η)，与阈值比
- 这里用简化：SNR_db 直接当 Es/N₀ + 10log₁₀(η) 近似，找最高 η 使 Es/N₀ >= 阈值

# 返回
- 最高可用 MODCOD，或 nothing（SNR 低于最低 MODCOD，链路中断）
"""
function select_modcod(
    snr_db::Float64;
    modcod_table::Vector{ModcodEntry} = DVB_S2_MODCODS,
)::Union{Nothing,ModcodEntry}
    # SNR = Es/N₀ + 10log₁₀(η)，η = 频谱效率
    # Es/N₀ = SNR - 10log₁₀(η)
    # 对每个 MODCOD 检查 Es/N₀ 是否 >= 阈值
    best = nothing
    for mc in modcod_table
        η = mc.spectral_efficiency
        es_n0 = snr_db - 10 * log10(η)
        if es_n0 >= mc.es_n0_threshold_db
            best = mc  # 取最后一个满足的（最高阶）
        end
    end
    return best
end

"""
    spectral_efficiency(modcod::ModcodEntry) -> Float64

返回 MODCOD 的频谱效率（bit/symbol）。
"""
spectral_efficiency(modcod::ModcodEntry) = modcod.spectral_efficiency

"""
    effective_capacity_mbps(modcod::ModcodEntry, symbol_rate_mbaud) -> Float64

按 MODCOD 的频谱效率和符号率算有效容量（Mbps）。

容量 = 频谱效率 × 符号率
"""
function effective_capacity_mbps(modcod::ModcodEntry, symbol_rate_mbaud::Float64)::Float64
    return modcod.spectral_efficiency * symbol_rate_mbaud
end

"""
    acm_capacity_mbps(snr_db, symbol_rate_mbaud; modcod_table) -> Float64

ACM 容量：按当前 SNR 选最高可用 MODCOD，算有效容量。
如果 SNR 低于最低 MODCOD，返回 0（链路中断）。

这是 ACM 的核心：动态适应信道质量，最大化吞吐。
"""
function acm_capacity_mbps(
    snr_db::Float64,
    symbol_rate_mbaud::Float64;
    modcod_table::Vector{ModcodEntry} = DVB_S2_MODCODS,
)::Float64
    mc = select_modcod(snr_db; modcod_table = modcod_table)
    mc === nothing && return 0.0
    return effective_capacity_mbps(mc, symbol_rate_mbaud)
end
