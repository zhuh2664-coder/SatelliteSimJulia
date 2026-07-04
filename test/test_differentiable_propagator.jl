# test/test_differentiable_propagator.jl
# 可微 SGP4 传播器测试：验证双向梯度（ForwardDiff + Zygote）

using Test
import ForwardDiff
import SatelliteToolboxSgp4
using LinearAlgebra: dot, norm
using SatelliteSimJulia: propagate_with_gradient, constellation_gradient, smooth_step, smooth_abs

const D2R = π / 180
const REV_DAY_TO_RAD_MIN = 2π / (24 * 60)

# ── 测试 TLE（VANGUARD 1） ──
const LINE1 = "1 00005U 58002B   00179.78495062  .00000023  00000-0  28098-4 0  4753"
const LINE2 = "2 00005  34.2682 331.5174 1859667 331.7664  19.3264 10.82419157413667"
const TEST_TLE = SatelliteToolboxSgp4.read_tle(LINE1, LINE2; verify_checksum = false)

# ── 辅助：有限差分对照 ──
function fd_jacobian(f, x::Vector{Float64}; h = 1e-6)
    y0 = f(x)
    n, m = length(x), length(y0)
    J = zeros(m, n)
    for i in 1:n
        xp, xm = copy(x), copy(x)
        xp[i] += h; xm[i] -= h
        J[:, i] = (f(xp) .- f(xm)) / (2h)
    end
    return J
end

function fd_gradient(loss_fn, params::Vector{Float64}; h = 1e-6)
    g = zeros(length(params))
    l0 = loss_fn(params)
    for i in eachindex(params)
        p, m = copy(params), copy(params)
        p[i] += h; m[i] -= h
        g[i] = (loss_fn(p) - loss_fn(m)) / (2h)
    end
    return g
end

# ── 测试 1: ForwardDiff 雅可比 vs 有限差分 ──
@testset "ForwardDiff 雅可比 vs 有限差分" begin
    J_ad = propagate_with_gradient(TEST_TLE, 60.0, mode=:forward)
    
    # 用有限差分计算 3×7 雅可比
    tle = TEST_TLE
    epoch = SatelliteToolboxSgp4.tle_epoch(tle)
    
    function f_params(x)
        sgp4d = SatelliteToolboxSgp4.sgp4_init(epoch, x[1], x[2], x[3], x[4], x[5], x[6], x[7])
        r, _ = SatelliteToolboxSgp4.sgp4!(sgp4d, 60.0)
        return [r[1], r[2], r[3]]
    end
    
    x0 = [tle.mean_motion*REV_DAY_TO_RAD_MIN, tle.eccentricity, tle.inclination*D2R,
          tle.raan*D2R, tle.argument_of_perigee*D2R, tle.mean_anomaly*D2R, tle.bstar]
    J_fd = fd_jacobian(f_params, x0)
    
    max_rel = maximum(abs.(J_ad .- J_fd) ./ (abs.(J_fd) .+ 1e-12))
    @test max_rel < 1e-4
    @test !any(isnan, J_ad)
    @test !any(isinf, J_ad)
    println("  ForwardDiff vs 有限差分: 最大相对误差 = $(max_rel)")
end

# ── 测试 2: ForwardDiff 梯度 vs 有限差分 ──
@testset "ForwardDiff 梯度 vs 有限差分" begin
    loss_fn(r) = r[1]^2 + r[2]^2 + r[3]^2
    
    grad_ad = propagate_with_gradient(TEST_TLE, 60.0, mode=:forward, loss_fn=loss_fn)
    
    tle = TEST_TLE
    epoch = SatelliteToolboxSgp4.tle_epoch(tle)
    
    function f_loss(x)
        sgp4d = SatelliteToolboxSgp4.sgp4_init(epoch, x[1], x[2], x[3], x[4], x[5], x[6], x[7])
        r, _ = SatelliteToolboxSgp4.sgp4!(sgp4d, 60.0)
        return r[1]^2 + r[2]^2 + r[3]^2
    end
    
    x0 = [tle.mean_motion*REV_DAY_TO_RAD_MIN, tle.eccentricity, tle.inclination*D2R,
          tle.raan*D2R, tle.argument_of_perigee*D2R, tle.mean_anomaly*D2R, tle.bstar]
    grad_fd = fd_gradient(f_loss, x0)
    
    max_rel = maximum(abs.(grad_ad .- grad_fd) ./ (abs.(grad_fd) .+ 1e-12))
    @test max_rel < 1e-4
    @test !any(isnan, grad_ad)
    println("  ForwardDiff vs 有限差分: 最大相对误差 = $(max_rel)")
end

# ── 测试 3: ForwardDiff vs Zygote 双向对比 ──
@testset "ForwardDiff vs Zygote 双向一致" begin
    loss_fn(r) = r[1]^2 + r[2]^2 + r[3]^2
    
    grad_fd = propagate_with_gradient(TEST_TLE, 60.0, mode=:forward, loss_fn=loss_fn)
    grad_zyg = propagate_with_gradient(TEST_TLE, 60.0, mode=:reverse, loss_fn=loss_fn)
    
    # 跳过 ∂loss/∂Ω₀（精确值为 0，数值噪声导致表观误差爆炸）
    # 检查所有非零分量的相对误差
    non_zero = abs.(grad_fd) .> 1e-6
    if any(non_zero)
        rel_errs = abs.(grad_fd[non_zero] .- grad_zyg[non_zero]) ./ (abs.(grad_fd[non_zero]) .+ 1e-12)
        @test all(rel_errs .< 1e-4)
        println("  ForwardDiff vs Zygote: 非零分量最大相对误差 = $(maximum(rel_errs))")
    end
    
    # 验证整体：梯度方向应该一致（余弦相似度 ≈ 1）
    cos_sim = dot(grad_fd, grad_zyg) / (norm(grad_fd) * norm(grad_zyg) + 1e-12)
    @test cos_sim > 0.999
    println("  梯度余弦相似度 = $(cos_sim)")
end

# ── 测试 4: 整星座 Zygote 反向模式梯度（用 Starlink TLE） ──
@testset "整星座梯度（Starlink TLE，10颗星）" begin
    # 读前 10 颗 Starlink
    lines = readlines(joinpath(@__DIR__, "..", "data", "tle", "celestrak", "starlink_gp_latest.tle"))
    tles = SatelliteToolboxSgp4.TLE[]
    for i in 1:min(10, length(lines)÷3)
        l1 = strip(lines[3i-1]); l2 = strip(lines[3i])
        tle = SatelliteToolboxSgp4.read_tle(l1, l2; verify_checksum=false)
        push!(tles, tle)
    end
    
    t_min = 60.0
    loss_fn(pos) = sum(abs2, pos)
    
    # Zygote 反向模式
    grad_zyg = constellation_gradient(tles, t_min, loss_fn, mode=:reverse)
    @test length(grad_zyg) == 7 * length(tles)
    @test !any(isnan, grad_zyg)
    @test !any(isinf, grad_zyg)
    
    # ForwardDiff 对比
    grad_fd = constellation_gradient(tles, t_min, loss_fn, mode=:forward)
    nonzero = abs.(grad_fd) .> 1e-10
    if any(nonzero)
        max_err = maximum(abs.(grad_zyg[nonzero] .- grad_fd[nonzero]) ./ (abs.(grad_fd[nonzero]) .+ 1e-12))
        @test max_err < 1e-4
        println("  整星座(10颗)双向梯度最大相对误差 = $(max_err)")
    end
end

# ── 测试 5: 光滑函数可微性 ──
@testset "光滑近似函数" begin
    # smooth_step：sigmoid 近似
    @test smooth_step(-10.0; k=20.0) < 1e-8
    @test smooth_step(0.0; k=20.0) ≈ 0.5
    @test smooth_step(10.0; k=20.0) > 1 - 1e-8
    
    # ForwardDiff 通过 smooth_step
    ds = ForwardDiff.derivative(x -> smooth_step(x; k=20.0), 0.0)
    @test ds ≈ 5.0  # k/4
    
    # smooth_abs
    @test smooth_abs(0.0) ≈ sqrt(1/20)
    ds = ForwardDiff.derivative(x -> smooth_abs(x), 0.0)
    @test abs(ds) < 1e-6
end

println("\n✅ 所有可微 SGP4 传播测试通过")
