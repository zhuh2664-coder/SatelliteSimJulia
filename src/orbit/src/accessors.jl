# ===== 裸数组便利访问函数 =====
#
# 解决痛点：positions[:, end, :] 可读性差（后人不明白是"最后一步"还是别的）。
# 这些函数让裸数组也能像嵌套类型那样自解释，同时保持裸数组的性能。
#
# 设计原则（来自 Nathan Reed + Julia 社区）：
#   - 自由函数，不 mutate
#   - 返回视图或轻量包装，不复制数据
#   - 命名反映意图

export position_at_instant, positions_at_last, satellite_positions, n_satellites, n_timesteps

"""
    n_satellites(positions) -> Int

位置矩阵中的卫星数量（第一维大小）。
"""
n_satellites(positions::AbstractArray{<:Real,3})::Int = size(positions, 1)

"""
    n_timesteps(positions) -> Int

位置矩阵中的时间步数（第二维大小）。
"""
n_timesteps(positions::AbstractArray{<:Real,3})::Int = size(positions, 2)

"""
    position_at_instant(positions, time_index) -> AbstractMatrix{<:Real}

取某个时刻所有卫星的位置（N×3 矩阵）。
替代难读的 `positions[:, time_index, :]`。
"""
function position_at_instant(positions::AbstractArray{<:Real,3}, time_index::Int)::AbstractMatrix{<:Real}
    return @view positions[:, time_index, :]
end

"""
    positions_at_last(positions) -> AbstractMatrix{<:Real}

取最后一步所有卫星的位置（N×3 矩阵）。
替代反复出现的 `positions[:, end, :]`。
"""
positions_at_last(positions::AbstractArray{<:Real,3})::AbstractMatrix{<:Real} = position_at_instant(positions, size(positions, 2))

"""
    satellite_positions(positions, sat_index) -> AbstractMatrix{<:Real}

取某颗卫星在所有时间步的位置（T×3 矩阵）。
替代 `positions[sat_index, :, :]`——命名明确"这是单颗卫星的轨迹"。
"""
function satellite_positions(positions::AbstractArray{<:Real,3}, sat_index::Int)::AbstractMatrix{<:Real}
    return @view positions[sat_index, :, :]
end
