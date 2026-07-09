# SatelliteSim 游戏开发计划（Godot 4）

> **已冻结（2026-07-09）** — 非仿真主线，本周不做。进度表见同目录 `STATUS.md`（亦冻结）。主线现状：[`../CURRENT.md`](../CURRENT.md)。

> 目标：基于 `SatelliteSimCore/Lab` 物理仿真，做一个 LEO 卫星星座 3D 沙盒游戏。
> 后端：Julia WebSocket 服务（已就绪）。前端：Godot 4 客户端。
> 状态：**计划阶段**，等待审核后开始实施。

---

## 1. 选型：为什么是 Godot 4

| 候选 | 优势 | 劣势 | 决定 |
|---|---|---|---|
| **Unity 6** | 生态最大、C# 强 | macOS Editor 启动慢、WS 在 Editor 下不稳、需要 Hub 中介 | ❌ |
| **Godot 4** | 单文件 ~240MB、免安装、内置 WebSocket、GDScript 简洁、原生 3D 节点 | 生态较小、3D 不及 UE | ✅ **采用** |
| **Unreal 5** | 顶级 3D 表现 | 10GB+ 安装、Blueprint 学习曲线陡、对原型过度 | ❌ |
| **Three.js (Web)** | 0 安装、浏览器即开 | 不是游戏引擎、无场景/资源系统 | 备选 |
| **GLMakie (Julia)** | 纯 Julia、零外部依赖 | 非引擎、无交互编辑 | 已落地 `scripts/desktop_sandbox.jl` |

**核心论点**：Godot 是**真游戏引擎**里最轻的，内置 WS 客户端（`WebSocketPeer`），GDScript 写起来像 Python，3D 节点系统成熟。

---

## 2. 架构（沿用 5 端点协议）

```
[Godot 客户端]  ←WebSocket (ws://127.0.0.1:8080)→  [SatelliteSimServer (Julia)]
  GDScript / 前端                                    Julia / 后端
  godot-sandbox/                                     src/server/
```

**复用已有**（不改）：
- Julia 端 `src/server/` 5 个 endpoint（list/describe/start/stop + frame 推流）
- 协议 JSON 结构（`frame`, `isl_pairs`, `isl_avail`, `positions`）
- 14 个 Walker 星座 catalog

**新建**：
- `godot-sandbox/` — Godot 4 客户端工程
- `docs/GAME_PLAN.md` — 本文档

---

## 3. 里程碑

| ID | 任务 | 验证 | 状态 |
|---|---|---|---|
| **M0** | Godot 4 装到 Mac | 启动 Godot.app 看到 Project Manager | ✅ 已完成 |
| **M1** | Godot 项目骨架 + 5 个 GDScript | `godot-sandbox/project.godot` + 脚本可被 Godot 加载 | ⏳ |
| **M2** | WebSocketPeer 客户端 + 解析 JSON | 收到 `list_constellations_response`，下拉框填充 14 星座 | ⏳ |
| **M3** | 3D 场景：地球 + 卫星散点 + 轨道线 | iridium 选完后看到 66 颗点动起来 | ⏳ |
| **M4** | ISL 实时连线 | 132 条候选边中可用边变绿/不可用灰 | ⏳ |
| **M5** | uGUI 风格控制面板（星座下拉、开始/停止、速度滑块、状态、HUD） | 与 Unity 版本功能等价 | ⏳ |
| **M6** | 摄像机轨道控制（鼠标拖动旋转） | 鼠标交互流畅 | ⏳ |
| **M7** | 14 星座回归 + 性能验证 | Iridium 60fps 流畅、OneWeb 1584 颗需优化 | ⏳ |

每个 M 都是**可独立验证、可回滚**的增量。

---

## 4. 文件结构

```
godot-sandbox/
├── project.godot                  # Godot 项目配置
├── scenes/
│   ├── main.tscn                  # 主场景（包含 UI、World、GameBootstrap）
│   └── sandbox.tscn               # 沙盒场景（Camera + Earth）
├── scripts/
│   ├── ws_client.gd               # WebSocketPeer 封装（单例 Autoload）
│   ├── sandbox_world.gd           # 3D 地球/卫星/ISL 节点
│   ├── sandbox_ui.gd              # Control 节点：UI 面板
│   ├── game_bootstrap.gd          # 总控：消息路由、播放控制
│   └── setup_godot.sh             # 创建项目目录骨架
├── README.md                      # 安装 + 运行说明
└── .gitignore
```

---

## 5. 关键 GDScript API 映射

| Unity C# | Godot 4 GDScript | 备注 |
|---|---|---|
| `MonoBehaviour` | `Node` + `_ready/_process` | Godot 的基础类 |
| `[SerializeField]` | `export var` | 暴露到 Inspector |
| `event Action` | `signal` | 信号 |
| `Task.Run` | `Thread` / `WorkerThreadPool` | 后台任务 |
| `ClientWebSocket` | `WebSocketPeer` | 同名，但 Godot 是同步轮询 |
| `LineRenderer` | `MeshInstance3D` + `ImmediateMesh` | 动态线 |
| `Sphere` | `SphereMesh` | 球体 |
| `Canvas` + `uGUI` | `Control` + 各种 `Container` | UI 系统 |
| `Slider` | `HSlider` / `VSlider` | 滑块 |
| `Button` | `Button` | 按钮 |
| `Dropdown` | `OptionButton` | 下拉框 |

---

## 6. 与 Unity 客户端的对比

| 维度 | Unity (unity-scripts/) | Godot (godot-sandbox/) |
|---|---|---|
| 引擎大小 | 10GB+ | 237MB |
| 启动时间 | 30s+ | <2s |
| 脚本语言 | C# | GDScript |
| 通信 | `System.Net.WebSockets` | `WebSocketPeer` |
| JSON 解析 | 自写 MiniJson (200 行) | `JSON.parse_string` 内置 |
| 场景文件 | 手动 YAML | `.tscn` 原生（可手写/编辑器） |
| 3D 渲染 | Built-in RP | Vulkan / GLES3 |
| 物理同步 | 主线程 + Task | `_process` + 信号 |
| 状态 | 已废（WS 兼容性坑） | **正式采用** |

**Unity 客户端 `unity-scripts/` 不删**：作为协议参考实现（已被 Julia e2e_client.jl + Godot 客户端交叉验证），但不再维护。

---

## 7. 风险与缓解

| 风险 | 影响 | 缓解 |
|---|---|---|
| Godot 4 GDScript 类型系统弱 | 重构易出错 | 用 `@tool` + 信号严格化，必要时切 C# Godot |
| 3D 大星座（>500 颗）性能 | 卡顿 | M7 引入 `MultiMeshInstance3D` 做 GPU instancing |
| 协议变更破坏客户端 | 双向回归 | `scripts/e2e_client.jl`（Julia 端）作为协议 oracle，先改协议再改两端 |
| 资源（贴图、模型）来源 | 用户体验 | 地球用程序化经纬线球（无贴图也好看）；卫星/ISL 用纯几何 |
| WebSocket 同步/异步 | Godot 同步轮询需要每帧 poll | 封装在 `ws_client.gd` 单例里，业务层只订阅信号 |

---

## 8. 时间线（预估）

| 阶段 | 内容 | 工时 |
|---|---|---|
| M1-M2 | 骨架 + WS 客户端 | 1h |
| M3-M4 | 3D 渲染 + ISL | 2h |
| M5-M6 | UI + 摄像机 | 1.5h |
| M7 | 回归 + 优化 | 1h |
| 文档 | README + 协议 | 0.5h |
| **合计** | | **~6h** |

---

## 9. 后续展望

- 接入 LLM（第二层实验编排层）做自然语言控制
- 物理参数实时调节（轨道高度、倾角）
- 多星座对比视图
- 真实地球贴图（用户提供后放 `textures/earth.jpg`）
- 跨平台导出（Mac/Win/Linux/Web）

---

**审核后开工**。
