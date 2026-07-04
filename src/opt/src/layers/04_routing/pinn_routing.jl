# ===== PINN 路由 — 类型定义 + 推理 + 训练 =====

export PINNRouting, fit_pinn_routing, predict_latency

"""
    PINNRouting{M, P, S}

用预训练 PINN 模型替代 Dijkstra 做路由预测。

区别于传统路由算法:
  - PINNRouting 的预测延迟完全可微
  - 推理速度 O(1)（模型前向传播）, 与星座规模无关

字段:
  - model: Lux 神经网络 (见 pinn_model.jl)
  - params: 训练好的权重
  - state: Lux 状态 (testmode)
  - y_mean, y_std: 训练标签归一化参数
  - sats_per_plane, n_planes: 星座结构（用于特征编码）
"""
struct PINNRouting{M, P, S}
    model::M
    params::P
    state::S
    y_mean::Float64
    y_std::Float64
    sats_per_plane::Int
    n_planes::Int
end

"""
    predict_latency(alg::PINNRouting, adj, src, dst) -> Float64

PINN 前向传播预测延迟（ms）。
输入: 邻接矩阵 + (src, dst) + 星座结构
输出: 预测延迟（完全可微）
"""
function predict_latency(alg::PINNRouting, adj::Matrix{Float64}, src::Int, dst::Int)::Float64
    x = encode_routing_features(adj, src, dst, alg.sats_per_plane, alg.n_planes)
    y_pred_norm, _ = alg.model(x, alg.params, alg.state)
    # 反归一化
    latency_ms = y_pred_norm[1] * alg.y_std + alg.y_mean
    return max(Float64(latency_ms), 0.0)
end

# ===== 训练接口 =====

"""
    fit_pinn_routing(adj_matrix, src_list, dst_list, latency_list;
                     hidden_dim=64, epochs=200, lr=0.001, verbose=true) -> PINNRouting

训练一个 PINN 路由模型。

参数:
  - adj_matrix: N×N 邻接矩阵 (距离/延迟), Inf 表示无边
  - src_list: 源卫星 ID 列表
  - dst_list: 目标卫星 ID 列表
  - latency_list: 对应的 Dijkstra 延迟 (ms)

返回:
  - 训练好的 PINNRouting 实例
"""
function fit_pinn_routing(
    adj_matrix::Matrix{Float64},
    src_list::Vector{Int},
    dst_list::Vector{Int},
    latency_list::Vector{Float64};
    hidden_dim::Int=64,
    epochs::Int=200,
    lr::Float64=0.001,
    sats_per_plane::Int=72,
    n_planes::Int=6,
    λ_sym::Float64=0.1,
    λ_tri::Float64=0.1,
    λ_phys::Float64=0.1,
    use_physics::Bool=true,
    verbose::Bool=true,
)::PINNRouting
    N = size(adj_matrix, 1)
    n_samples = length(src_list)

    # ── 特征编码 ──
    X = zeros(Float64, 12, n_samples)
    Y = zeros(Float64, 1, n_samples)

    # 物理约束特征（仅在启用时计算）
    X_rev = use_physics ? zeros(Float64, 12, n_samples) : zeros(Float64, 0, 0)
    X_AB = use_physics ? zeros(Float64, 12, n_samples) : zeros(Float64, 0, 0)
    X_BC = use_physics ? zeros(Float64, 12, n_samples) : zeros(Float64, 0, 0)
    phys_lower_ms = use_physics ? zeros(Float64, n_samples) : zeros(Float64, 0)

    rng = Random.default_rng()
    min_edge_km = use_physics ? minimum(filter(isfinite, adj_matrix)) : 0.0
    SPEED_OF_LIGHT_KM_S = SatelliteSimCore.SPEED_OF_LIGHT_KM_S

    for k in 1:n_samples
        s, d = src_list[k], dst_list[k]
        X[:, k] = encode_routing_features(adj_matrix, s, d, sats_per_plane, n_planes)
        Y[1, k] = latency_list[k]

        if use_physics
            X_rev[:, k] = encode_routing_features(adj_matrix, d, s, sats_per_plane, n_planes)

            mid = rand(rng, 1:N)
            while mid == s || mid == d
                mid = rand(rng, 1:N)
            end
            X_AB[:, k] = encode_routing_features(adj_matrix, s, mid, sats_per_plane, n_planes)
            X_BC[:, k] = encode_routing_features(adj_matrix, mid, d, sats_per_plane, n_planes)

            hop = bfs_hop_count(adj_matrix, s, d)
            phys_lower_ms[k] = max(0.0, min_edge_km * hop / SPEED_OF_LIGHT_KM_S * 1000)
        end
    end

    # 归一化标签
    y_mean = mean(Y)
    y_std = max(std(Y), 1e-8)
    Y_norm = (Y .- y_mean) ./ y_std
    phys_lower_norm = use_physics ? (phys_lower_ms .- y_mean) ./ y_std : zeros(Float64, 0)

    # 构建模型
    model = create_pinn_model(12, hidden_dim)
    params, state = Lux.setup(rng, model)

    opt_state = Optimisers.setup(Optimisers.Adam(lr), params)

    for epoch in 1:epochs
        # 前向 + 损失计算
        y_pred, _ = model(X, params, state)
        loss_data = mean((y_pred .- Y_norm) .^ 2)
        if use_physics
            y_pred_rev, _ = model(X_rev, params, state)
            y_pred_ab, _ = model(X_AB, params, state)
            y_pred_bc, _ = model(X_BC, params, state)
            loss_sym = mean((y_pred .- y_pred_rev) .^ 2)
            loss_tri = mean(max.(0.0, y_pred .- (y_pred_ab .+ y_pred_bc)))
            loss_phys = mean(max.(0.0, phys_lower_norm .- y_pred))
            loss = loss_data + λ_sym * loss_sym + λ_tri * loss_tri + λ_phys * loss_phys
        else
            loss = loss_data
        end

        # 梯度（Zygote）
        grads = Zygote.gradient(p -> begin
            yp, _ = model(X, p, state)
            ld = mean((yp .- Y_norm) .^ 2)
            if use_physics
                ypr, _ = model(X_rev, p, state)
                ypa, _ = model(X_AB, p, state)
                ypb, _ = model(X_BC, p, state)
                ld += λ_sym * mean((yp .- ypr) .^ 2)
                ld += λ_tri * mean(max.(0.0, yp .- (ypa .+ ypb)))
                ld += λ_phys * mean(max.(0.0, phys_lower_norm .- yp))
            end
            return ld
        end, params)[1]

        Optimisers.update!(opt_state, params, grads)

        if epoch % 50 == 0 && verbose
            println("epoch $epoch | loss: $(round(Float64(loss), digits=6))")
        end
    end

    return PINNRouting(model, params, state, y_mean, y_std, sats_per_plane, n_planes)
end

"""
    mse_loss(y_pred, y_true) -> Float64

均方误差损失。
"""
function mse_loss(y_pred::AbstractArray, y_true::AbstractArray)::Float64
    return mean((y_pred .- y_true) .^ 2)
end
