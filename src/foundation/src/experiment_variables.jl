"""
    共享层：实验与优化变量抽象模块

本文件定义仿真实验与可微/可学习链路中使用的变量元数据与两类变量
（系统变量、实验参数）。这些类型用于参数敏感性分析、攻击实验配置以及
后续优化层对容量、瓶颈等目标函数的梯度实验。
"""

"""
    AbstractExperimentVariable

实验变量的抽象基类型。所有可在仿真流程中被采样、观测或优化的变量
（如系统常量、可调参数）均继承自此类型。
"""
abstract type AbstractExperimentVariable end

"""
    VariableMeta

变量的元数据，描述变量的标识、物理含义、来源与验证目标。

# 字段
- `id::Symbol`: 变量唯一标识
- `name::Symbol`: 变量名称
- `namespace::Symbol`: 所属命名空间
- `value_type::DataType`: 取值类型
- `unit::Symbol`: 单位
- `description::String`: 描述
- `source::Symbol`: 数据来源
- `effect_timing::Symbol`: 作用时机
- `physical_verify_targets::Vector{Symbol}`: 物理层验证目标
- `runtime_verify_targets::Vector{Symbol}`: 运行时验证目标
"""
struct VariableMeta
    id::Symbol
    name::Symbol
    namespace::Symbol
    value_type::DataType
    unit::Symbol
    description::String
    source::Symbol
    effect_timing::Symbol
    physical_verify_targets::Vector{Symbol}
    runtime_verify_targets::Vector{Symbol}
end

"""
    VariableBounds{T}

变量上下界约束。

# 字段
- `lower::Union{Nothing,T}`: 下界，`nothing` 表示无下界
- `upper::Union{Nothing,T}`: 上界，`nothing` 表示无上界
"""
struct VariableBounds{T}
    lower::Union{Nothing,T}
    upper::Union{Nothing,T}
end

"""
    SystemVariable{T} <: AbstractExperimentVariable

系统变量，表示仿真中固定或只读的物理/环境量。

# 字段
- `meta::VariableMeta`: 变量元数据
- `value::T`: 当前取值
"""
struct SystemVariable{T} <: AbstractExperimentVariable
    meta::VariableMeta
    value::T
end

"""
    ExperimentParameter{T} <: AbstractExperimentVariable

实验参数，表示可在实验中调节、可能参与梯度优化的变量。

# 字段
- `meta::VariableMeta`: 变量元数据
- `value::T`: 当前取值
- `bounds::Union{Nothing,VariableBounds{T}}`: 取值范围约束
- `differentiable::Bool`: 是否参与可微/梯度优化
"""
mutable struct ExperimentParameter{T} <: AbstractExperimentVariable
    meta::VariableMeta
    value::T
    bounds::Union{Nothing,VariableBounds{T}}
    differentiable::Bool
end

"""
    value(variable::AbstractExperimentVariable)

返回实验变量 `variable` 的当前取值。
"""
value(variable::AbstractExperimentVariable) = variable.value

"""
    setvalue!(variable::ExperimentParameter{T}, next_value::T) where {T}

设置实验参数 `variable` 的取值为 `next_value`，并在存在边界约束时进行校验。

# 参数
- `variable::ExperimentParameter{T}`: 待修改的实验参数
- `next_value::T`: 目标取值

# 返回
- `ExperimentParameter{T}`: 修改后的参数对象

# 依赖
- 读取 `variable.bounds` 的上下界完成就地校验。

# 异常
- 当 `next_value` 超出上下界时抛出 `ArgumentError`。
"""
function setvalue!(variable::ExperimentParameter{T}, next_value::T) where {T}
    if variable.bounds !== nothing
        lower = variable.bounds.lower
        upper = variable.bounds.upper
        # 下界非空时检查取值不小于下界
        lower === nothing || next_value >= lower ||
            throw(ArgumentError("$(variable.meta.id) must be >= $(lower)"))
        # 上界非空时检查取值不大于上界
        upper === nothing || next_value <= upper ||
            throw(ArgumentError("$(variable.meta.id) must be <= $(upper)"))
    end
    variable.value = next_value
    return variable
end
