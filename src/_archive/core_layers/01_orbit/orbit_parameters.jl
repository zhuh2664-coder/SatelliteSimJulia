# 轨道层实验参数生成模块。
#
# 本文件负责把星座设计规格（ConstellationSpec / ShellSpec）中的轨道参数，
# 转换成优化层可识别的 ExperimentParameter 列表。它是“设计参数”到“可微/可优化变量”
# 的桥梁：每个轨道参数都带有 id、单位、取值范围、是否可微以及修改后是否需要重建星座。
#
# 依赖：
#   - ExperimentParameter、VariableMeta、VariableBounds 等类型由参数系统定义。
#   - ConstellationSpec / ShellSpec 由 network_layer/builders.jl 定义。
#   - 本模块只产生参数描述，不直接修改任何卫星或轨道对象。

"""
    orbit_experiment_parameter(id, name, value, unit, description, bounds, differentiable) -> ExperimentParameter

将一个轨道设计变量封装为统一的实验参数对象。

# 参数
- `id::AbstractString`：参数在实验配置中的唯一标识字符串。
- `name::Symbol`：参数语义名，例如 `:altitude_km`。
- `value::T`：参数当前取值。
- `unit::Symbol`：参数单位，例如 `:km`、`:deg`、`:count`。
- `description::AbstractString`：参数中文说明，用于报告与配置解释。
- `bounds::Union{Nothing,VariableBounds{T}}`：取值上下界，`nothing` 表示无上界。
- `differentiable::Bool`：是否可被自动微分或梯度优化器使用。

# 返回值
一个 `ExperimentParameter`，其 `VariableMeta` 标记了参数类别为 `:orbit`，
影响域为 `[:orbit_elements, :orbit_planes, :satellites]`，且修改后需要重建星座（`:rebuild_required`）。
"""
function orbit_experiment_parameter(
    id::AbstractString,
    name::Symbol,
    value::T,
    unit::Symbol,
    description::AbstractString,
    bounds::Union{Nothing,VariableBounds{T}},
    differentiable::Bool,
) where {T}
    return ExperimentParameter(
        VariableMeta(
            Symbol(id),
            name,
            :orbit,
            T,
            unit,
            String(description),
            :config,
            :rebuild_required,
            [:orbit_elements, :orbit_planes, :satellites],
            [:rebuild_required],
        ),
        value,
        bounds,
        differentiable,
    )
end

"""
    design_shell_experiment_parameters(shell) -> Vector{ExperimentParameter}

把单个星座壳层（ShellSpec）的轨道设计参数全部导出为可优化参数。

# 参数
- `shell`：单个星座壳层规格对象，需包含 `id`、`altitude_km`、`inclination_deg`、
  `orbit_count`、`satellites_per_orbit`、`phase_shift` 等字段。

# 返回值
包含 5 个实验参数的向量，覆盖该壳层的轨道高度、倾角、轨道面数、每轨卫星数、相位错位。
其中高度和倾角被标记为可微；卫星数量类参数由于会改变星座结构，标记为不可微。
"""
function design_shell_experiment_parameters(shell)::Vector{ExperimentParameter}
    prefix = "orbit.shell$(shell.id)"
    return ExperimentParameter[
        orbit_experiment_parameter(
            "$(prefix).altitude_km",
            :altitude_km,
            shell.altitude_km,
            :km,
            "轨道高度，决定设计星座壳层的轨道高度",
            VariableBounds(0.0, nothing),
            true,
        ),
        orbit_experiment_parameter(
            "$(prefix).inclination_deg",
            :inclination_deg,
            shell.inclination_deg,
            :deg,
            "轨道倾角，决定设计星座壳层相对赤道的倾斜角",
            VariableBounds(0.0, 180.0),
            true,
        ),
        orbit_experiment_parameter(
            "$(prefix).orbit_count",
            :orbit_count,
            shell.orbit_count,
            :count,
            "轨道面数量，决定这个壳层有多少个轨道面",
            VariableBounds(1, nothing),
            false,
        ),
        orbit_experiment_parameter(
            "$(prefix).satellites_per_orbit",
            :satellites_per_orbit,
            shell.satellites_per_orbit,
            :count,
            "每个轨道面中的卫星数量",
            VariableBounds(1, nothing),
            false,
        ),
        orbit_experiment_parameter(
            "$(prefix).phase_shift",
            :phase_shift,
            shell.phase_shift,
            :none,
            "相邻轨道面之间的卫星相位错位参数",
            VariableBounds(0, nothing),
            false,
        ),
    ]
end

"""
    design_constellation_experiment_parameters(spec::ConstellationSpec) -> Vector{ExperimentParameter}

遍历整个星座规格中所有壳层，汇总全部轨道层实验参数。

# 参数
- `spec::ConstellationSpec`：星座设计规格，通常包含一个或多个 `shells`。

# 返回值
所有壳层实验参数的扁平化向量，顺序与 `spec.shells` 一致。
"""
function design_constellation_experiment_parameters(spec::ConstellationSpec)::Vector{ExperimentParameter}
    return [
        parameter
        for shell in spec.shells
        for parameter in design_shell_experiment_parameters(shell)
    ]
end
