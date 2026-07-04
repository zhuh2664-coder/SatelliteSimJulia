using Distributions

"""
    随机变量 — ns-3 RandomVariableStream 复现

支持均匀/指数/正态/常数分布。
底层用 Distributions.jl。
"""
abstract type RandomVariable end

mutable struct UniformRandom <: RandomVariable
    rng::Distributions.Uniform
    UniformRandom(min=0.0, max=1.0) = new(Uniform(min, max))
end
Base.rand(r::UniformRandom) = rand(r.rng)

mutable struct ExponentialRandom <: RandomVariable
    rng::Distributions.Exponential
    ExponentialRandom(mean=1.0) = new(Exponential(mean))
end
Base.rand(r::ExponentialRandom) = rand(r.rng)

mutable struct NormalRandom <: RandomVariable
    rng::Distributions.Normal
    NormalRandom(mean=0.0, std=1.0) = new(Normal(mean, std))
end
Base.rand(r::NormalRandom) = rand(r.rng)

mutable struct ConstantRandom <: RandomVariable
    val::Float64
end
Base.rand(r::ConstantRandom) = r.val
