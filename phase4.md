# SatelliteSimJulia Phase 4：Server Adapter 边界收敛

## 背景与起点

Phase 3 已将根包收敛为日常 Lab 编排门面，并明确剩余的 Server、Distributed、Security、Opt、Viz 将在后续 adapter/package 阶段分别处理。

本阶段优先处理 `SatelliteSimServer`：它是外部 WebSocket 入口，当前同时直接依赖 `SatelliteSimCore`、`SatelliteSimNet` 和 `SatelliteSimLab`。这使传输层同时承担 JSON/WebSocket 协议、会话状态、星座解析、传播、拓扑与链路评估职责。

## 目标

把 Server 固化为**传输与会话 adapter**，将仿真准备和逐帧领域计算收敛为 `SatelliteSimLab` 的明确 adapter API。

目标依赖方向：

```text
WebSocket / JSON request
        ↓
SatelliteSimServer (protocol, session lifecycle, streaming transport)
        ↓
SatelliteSimLab (server-facing simulation/stream adapter)
        ↓
Core / Net / Link / Orbit / Foundation
```

Server 保留协议 DTO、会话标识和推送节奏；不再自行编排 Walker 生成、传播、拓扑、ISL/GSL/coverage 计算。

## 现状审计（2026-07-09）

- `src/server/src/sessions.jl` 直接调用 catalog 解析、Walker 生成、ECEF 传播和 GridPlus 拓扑。
- `src/server/src/streamer.jl` 直接进行 ISL、GSL 与 coverage 的逐帧领域评估。
- `src/server/src/handlers.jl` 直接读取 constellation catalog，同时还调用 Lab 的 AI trace/checkpoint API。
- 当前 `src/server/Project.toml` 声明 `SatelliteSimCore`、`SatelliteSimNet`、`SatelliteSimLab`；其 package test 已覆盖协议、启动/停止、stream frame、传播器和 AI endpoints。

## 实施计划

1. **定义 Lab adapter 契约**
   - 在 `SatelliteSimLab` 中增加专门的、与 HTTP/WebSocket 无关的 streaming simulation facade。
   - 输入使用普通 Julia 数据与 Lab/领域对象；输出使用稳定的模拟快照、星座元数据、帧数据和地面站摘要。
   - 不让 `SatelliteSimLab` 依赖 `SatelliteSimServer` 的 DTO 或 JSON 类型。

2. **迁移 Server 会话和 handler**
   - `SimulationSession` 保存 Lab adapter 的模拟快照，而不是自行保存/构造领域计算输入。
   - `start_session`、`frame_payload` 和 constellation metadata 改为调用 Lab adapter。
   - 保持现有 WebSocket 消息类型、字段、会话语义与错误封装兼容。

3. **收窄 package dependencies**
   - 目标是 Server 的运行时领域依赖仅为 `SatelliteSimLab`；保留 `JSON3`、`StructTypes`、`WebSockets`、`Random` 等传输/运行时依赖。
   - 删除不再需要的 `SatelliteSimCore`、`SatelliteSimNet` 直接依赖和 imports。

4. **验证**
   - 增加 Lab adapter 的直接契约测试。
   - 保持 Server 的协议、帧结构、GSL/coverage、propagator、AI endpoints 测试全绿。
   - 运行独立 package tests、根包测试和 current suite；不在本阶段改变客户端协议。

## 验收条件

```bash
julia --project=src/lab -e 'using Pkg; Pkg.test()'
julia --project=src/server -e 'using Pkg; Pkg.test()'
julia --project=. test/runtests.jl
SATSIM_RUN_CURRENT=1 julia --project=. test/runtests.jl
```

- `SatelliteSimServer` 不再直接 `using SatelliteSimCore` 或 `using SatelliteSimNet`。
- Server 的独立测试可在干净 clone 中通过。
- 现有 5 类 WebSocket 请求及 frame / stream_end 输出字段保持向后兼容。
- AI trace/checkpoint 继续由 `SatelliteSimLab` 明确提供。

## 非本阶段范围

- 不重写 Unity/其他客户端。
- 不修改 WebSocket 协议字段或引入 HTTP API 版本升级。
- 不在本阶段改造 Distributed、Security、Opt 或 Viz；每个包在后续独立 Phase 中处理。
