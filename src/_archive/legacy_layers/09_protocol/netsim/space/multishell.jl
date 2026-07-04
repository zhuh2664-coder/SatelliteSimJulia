"""
    multishell.jl — 多层星座仿真 (Multi-Shell)

Starlink 5 壳层构型:
  Shell 1: 550km, 53°, 72×22=1584
  Shell 2: 540km, 53.2°, 72×22=1584
  Shell 3: 570km, 70°, 36×20=720
  Shell 4: 560km, 97.6°, 12×12=144
  Shell 5: 560km, 97.6°, 6×12=72

每壳层是一个独立的 Walker 星座。跨壳层 ISL 只在特定条件下建立。
"""
struct ShellConfig
    id::UInt8
    alt_km::Float64
    inc_deg::Float64
    planes::Int
    sats_per_plane::Int
    phase_factor::Int
end

struct MultiShellConstellation
    shells::Vector{ShellConfig}
    total_sats::Int
    shell_offsets::Vector{Int}  # 每壳层在总 pos 矩阵中的起始索引
end

function MultiShellConstellation(configs::Vector{ShellConfig})
    offsets = [1]
    for i in 2:length(configs)
        prev = configs[i-1]
        push!(offsets, offsets[end] + prev.planes * prev.sats_per_plane)
    end
    total = sum(c.planes * c.sats_per_plane for c in configs)
    MultiShellConstellation(configs, total, offsets)
end

"""生成多层星座的 pos 矩阵"""
function generate_multishell_pos(configs::Vector{ShellConfig}, t_steps::Int)::Array{Float64,3}
    msc = MultiShellConstellation(configs)
    total = msc.total_sats
    pos = zeros(Float64, total, t_steps, 3)

    for (si, cfg) in enumerate(configs)
        n = cfg.planes * cfg.sats_per_plane
        start_idx = msc.shell_offsets[si]
        r = 6371.0 + cfg.alt_km
        inc = cfg.inc_deg * pi / 180

        idx = 0
        for p in 0:cfg.planes-1
            raan = Float64(p) / cfg.planes * 360.0 * pi / 180
            for s in 0:cfg.sats_per_plane-1
                idx += 1
                global_idx = start_idx + idx - 1
                ma0 = (Float64(s)/cfg.sats_per_plane*360 +
                       Float64(cfg.phase_factor*p)/cfg.sats_per_plane*360) % 360
                for t in 1:t_steps
                    ma = (ma0 + (t-1)*360.0/5400.0) * pi / 180
                    x_in = r*cos(ma); y_in = r*sin(ma)
                    pos[global_idx,t,1] = x_in*cos(raan) - y_in*cos(inc)*sin(raan)
                    pos[global_idx,t,2] = x_in*sin(raan) + y_in*cos(inc)*cos(raan)
                    pos[global_idx,t,3] = y_in*sin(inc)
                end
            end
        end
    end
    pos
end

"""同一壳层内卫星 ID 范围"""
function shell_range(msc::MultiShellConstellation, shell_id::UInt8)::UnitRange{Int}
    for (si, cfg) in enumerate(msc.shells)
        if cfg.id == shell_id
            start = msc.shell_offsets[si]
            return start : (start + cfg.planes*cfg.sats_per_plane - 1)
        end
    end
    1:0
end

"""跨壳层距离 (km) — 用于判断是否可建 ISL"""
function cross_shell_distance(pos::AbstractArray{Float64,3}, t::Int,
                               i::Int, j::Int)::Float64
    sqrt(sum((pos[i,t,:] - pos[j,t,:]).^2))
end

"""语义地址中提取壳层"""
function shell_from_addr(addr::SemanticAddress)::UInt8
    addr.shell
end

"""跨壳层 ISL 代价 (比同壳层大)"""
function cross_shell_cost(shell_a::UInt8, shell_b::UInt8)::Float64
    shell_a == shell_b ? 1.0 : 5.0  # 跨壳层代价 5×
end

# Shell 配置常量
const STARLINK_SHELLS = [
    ShellConfig(1, 550, 53.0, 72, 22, 1),
    ShellConfig(2, 540, 53.2, 72, 22, 1),
    ShellConfig(3, 570, 70.0, 36, 20, 1),
    ShellConfig(4, 560, 97.6, 12, 12, 1),
    ShellConfig(5, 560, 97.6, 6, 12, 1),
]

"""从 pos 矩阵构建跨壳层 Contact Plan"""
function build_multishell_contacts(pos::AbstractArray{Float64,3},
                                    msc::MultiShellConstellation, t_steps::Int)
    cp = ContactPlan("multishell")
    n = size(pos, 1)
    c = 299792.458

    for t in 1:t_steps
        st = (t-1)*1.0
        for i in 1:n, j in (i+1):n
            d = sqrt(sum((pos[i,t,:] - pos[j,t,:]).^2))
            # 同壳层: 1500km 门限; 跨壳层: 2000km (距离更远但可连)
            max_dist = 1500.0
            if !same_shell(msc, i, j)
                # 跨壳层 ISL 门限更大但代价更高
                max_dist = 2000.0
            end
            if d < max_dist
                delay = d / c
                add_contact!(cp, UInt32(i), UInt32(j), st, st+1.0, delay, 1e9)
                add_contact!(cp, UInt32(j), UInt32(i), st, st+1.0, delay, 1e9)
            end
        end
    end
    cp
end

function same_shell(msc::MultiShellConstellation, i::Int, j::Int)::Bool
    for cfg in msc.shells
        n = cfg.planes * cfg.sats_per_plane
        start_i = findfirst(s -> s == cfg.id, [s.id for s in msc.shells])
        start = msc.shell_offsets[start_i]
        r = start : (start + n - 1)
        if i in r && j in r; return true; end
    end
    false
end

"""打印多层星座信息"""
function print_multishell(msc::MultiShellConstellation)
    println("多层星座: $(length(msc.shells)) 壳层, 总计 $(msc.total_sats) 颗卫星")
    for (i, cfg) in enumerate(msc.shells)
        n = cfg.planes * cfg.sats_per_plane
        r = msc.shell_offsets[i]
        println("  Shell $(cfg.id): $(n)颗 = $(cfg.planes)×$(cfg.sats_per_plane), " *
                "$(cfg.alt_km)km, $(cfg.inc_deg)° [ID $(r):$(r+n-1)]")
    end
end
