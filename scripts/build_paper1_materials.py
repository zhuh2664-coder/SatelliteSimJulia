#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
第一篇论文写作素材库生成器

为 Sprint 2 的可微优化闭环论文准备完整写作素材,输出:
  docs/literature/论文1_素材库_可微优化.md

12 节结构:定位/贡献/标题/Related Work/Motivation/Methodology/
          Experiment/Figure/Baseline/Reviewer/Timeline/引用附录

数据来源:_data.json (板块 06 + 跨板块) + _citations_06_*.bib (BibTeX key)
不修改 src/ 代码,可重复运行(幂等)。
"""

import json
import os
import re
import glob

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.dirname(SCRIPT_DIR)
OUT_DIR = os.path.join(PROJECT_DIR, "docs", "literature")
JSON_IN = os.path.join(OUT_DIR, "_data.json")
MD_OUT = os.path.join(OUT_DIR, "论文1_素材库_可微优化.md")


def clean_title(t):
    return re.sub(r"^\s*\d+\.\s*", "", t).strip()


def load_bib_keys():
    """加载所有板块的 BibTeX key 映射 (title_lower → key)。"""
    title_to_key = {}
    for bib in sorted(glob.glob(os.path.join(OUT_DIR, "_citations_*.bib"))):
        with open(bib, "r", encoding="utf-8") as f:
            content = f.read()
        # 解析每个条目
        entries = re.findall(
            r"@\w+\{([^,]+),\s*title\s*=\s*\{([^}]+)\}", content)
        for key, title in entries:
            t = re.sub(r"[^\w\s]", "", title.lower())[:60]
            title_to_key[t] = key
    return title_to_key


def get_key(title_to_key, title):
    t = re.sub(r"[^\w\s]", "", clean_title(title).lower())[:60]
    return title_to_key.get(t, "??_missing")


# ---------------------------------------------------------------------------
# 各节内容生成
# ---------------------------------------------------------------------------
def section_1_positioning():
    return """## §1 论文定位与投稿目标

### 1.1 候选 Venue 对比

| Venue | 类型 | Scope 匹配度 | IF/排名 | 审稿周期 | 录用率 | 推荐度 |
|-------|------|-------------|---------|----------|--------|--------|
| **INFOCOM** | 会议(CCF-A) | ⭐⭐⭐ 网络系统 | CCF-A 顶会 | 5 月(审稿→会) | ~20% | 🥇 **首选** |
| **IEEE Trans. on Networking** | 期刊(CCF-A) | ⭐⭐⭐ 网络+优化 | IF ~3.4 | 6-12 月 | ~15% | 🥈 备选 |
| **IEEE JSAC** | 期刊(CCF-A) | ⭐⭐ 需特刊吻合 | IF ~9.4 | 8 月 | ~15%(特刊) | 🥉 看特刊 |
| **NeurIPS** | 会议(CCF-A) | ⭐⭐ 偏 ML 需强 ML 卖点 | ML 顶会 | 6 月 | ~25% | ⚠️ ML 功底要求高 |

### 1.2 推荐:INFOCOM(首选)+ Trans. Networking(被拒转投)

**核心理由——创新点是真空白**:

```
查证:可微物理仿真(DiffTALES/Brax/MJX)∩ LEO 星座优化
  ├─ 可微物理仿真:成熟(流体/机器人/热)
  ├─ LEO 星座优化:传统方法成熟(网格/GA/RL)
  └─ 两者交叉(可微 LEO):✅ 真空白
     (板块06严格可微论文仅17篇,且无端到端网络优化先例)
```

→ 创新点强、故事性好,**宜快速抢占话语权**(首个可微 LEO),会议优先。

### 1.3 场景推演(关键变量:创新强度 vs 实验风险)

**场景 A:4 周内实验顺利(覆盖率提升 ≥3%,梯度正确)**
→ 创新强 + 数据漂亮 → INFOCOM 更优(快速发表,抢占话语权)

**场景 B:实验有风险(覆盖率提升 1-2% 或梯度不稳)**
→ 需补充实验/扩展方法 → Trans. Networking 更优(期刊宽容,可加 ablation 补强)

**场景 C:创新被质疑(与现有可微仿真太像)**
→ 需深度论证区别 → Trans. Networking 更优(期刊允许长篇 Related Work)

**判断**:场景 A 概率最大(真空白 + 基础设施已有),故推荐 INFOCOM。

### 1.4 投稿策略(推荐路径)

```
策略 B(推荐):会议直投 → 被拒转期刊
  ├─ Sprint 2(4 周)完成实验 + 13 页 INFOCOM 投稿
  ├─ 若录用 → 直接发表(5 个月),抢占"首个可微 LEO"
  └─ 若被拒 → 用 reviewer 意见改进,作为"新投稿"投 Trans. Networking
              (非"扩展版",无自我抄袭问题)

策略 A(备选):期刊直投 Trans. Networking
  ├─ 优势:周期可控、可详尽展开实验
  └─ 风险:慢(6-12 月),失去话语权先发优势

⚠️ 策略 C(不推荐):INFOCOM → Trans. 扩展版
  └─ IEEE 期刊对扩展版要求 ≥30% 新增内容,本题目扩展空间有限,自我抄袭风险高
```

**推荐**:策略 B(会议直投 → 被拒转期刊)。最坏情况 6 个月后转投期刊,与策略 A 时间相当;
最好情况 5 个月发表 CCF-A,收益最高、风险最低。

### 1.5 前置可行性验证(降低 Sprint 2 风险)

INFOCOM 推演成立的前提:**4 周内实验能跑通**。建议:

```
Sprint 1 末(对标验证阶段)追加 1-2 周"梯度可行性验证":
  ├─ 只跑 Iridium-66 小规模,验证 Enzyme 对 J2 可微
  ├─ 验证 Adam 在 66 卫星收敛
  └─ 通过 → 全力 Sprint 2 投 INFOCOM
     失败 → 调整方法(换 Zygote / 换 loss)再决策 venue
```
"""


def section_2_contributions():
    return """## §2 核心贡献(Contributions 草稿)

### 2.1 三条核心贡献(写作时可直接用)

> **Contribution 1(方法)**:我们提出首个端到端可微的 LEO 星座仿真流水线,
> 将可微 J2 轨道传播、软 ISL/覆盖松弛、Adam 优化整合为统一框架,
> 实现对 Walker 星座参数(F:总卫星数 / P:轨道面数 / i:倾角 / alt:高度)
> 的梯度优化。**[由 §7 主实验 + §7 传播器精度实验证明]**

> **Contribution 2(系统)**:我们识别并解决了 LEO 仿真可微化的三大障碍——
> (a) SGP4 数值表不可微(用解析 J2 替代);
> (b) ISL 拓扑选择是离散决策(用 sigmoid 软阈值近似);
> (c) 覆盖率是阶跃函数(用 noisy-OR + soft sigmoid 松弛)。
> 三个松弛均通过梯度数值正确性验证(相对有限差分误差 < 1e-4)。
> **[由 §6 Methodology + §7 Ablation 证明]**

> **Contribution 3(实证)**:在 Starlink-1584 等真实规模星座上,
> 端到端梯度优化相较 Walker 均匀分布参数基线,
> 覆盖率提升 ≥3%、优化耗时 < 10 分钟(对比网格搜索 O(N⁶) 数小时)。
> 我们进一步证明优化结果对 SGP4 truth 传播器仍成立(误差 < 10%)。
> **[由 §7 主实验 + §7 Scaling + §7 传播器精度证明]**

### 2.2 可选 Contribution 4(若实验充分)

> **Contribution 4(可扩展性)**:框架的多重分派架构支持热插拔传播器/松弛策略,
> 我们展示 J2/SGP4/HPOP 三种传播器和 4 种覆盖松弛策略的组合实验,
> 为后续 PINN 传播器扩展奠定基础。**[由 §7 Ablation 证明]**

### 2.3 主 Contribution 定位(深化推演)

**问题**:3-4 条 contribution,哪个是论文的"主 contribution"?这决定 abstract/intro 的重心。

**逐条推演(若单独作为主 contribution 的强弱)**:

| Contribution | 作为主 contribution 的故事 | Reviewer 易质疑点 | 单独支撑力 |
|--------------|---------------------------|-------------------|-----------|
| **C1 方法**(端到端可微流水线) | "首个把可微物理仿真引入 LEO 网络" | "与 DiffTALES/Brax 区别?" → 需 C2 技术深度 + C3 实证撑 | ⭐⭐⭐ 强(交叉创新,护城河) |
| **C2 系统**(三大可微性障碍解决) | "解决 LEO 仿真特有的可微性障碍" | "只是 sigmoid 松弛,不够新" → 偏 incremental | ⭐⭐ 中(技术细节,难独立成文) |
| **C3 实证**(覆盖率提升 ≥3%) | "梯度优化比网格搜索快 100×" | "3% 提升幅度小" → 需 C1 范式创新提故事 | ⭐⭐ 中(幅度小,需范式包装) |

**核心判断——这篇论文的真正护城河是什么?**

```
不是 C3(3% 幅度小,zero-order 也能做到类似效果)
不是 C2(三大障碍是技术细节,sigmoid/noisy-OR 不是新发明)
而是 C1(端到端可微 ∩ LEO 网络优化 = 交叉创新,领域首个)
```

**结论:主 Contribution = C1(端到端可微范式),C2 + C3 是支撑**

### 2.4 推演对写作的影响(可操作建议)

| 写作要素 | 推演结论 → 具体做法 |
|---------|---------------------|
| **Abstract 首句** | 强调 "first end-to-end differentiable"(已做到,§3.3) |
| **Intro contribution 顺序** | C1 主(详写 2-3 句)、C2 次主(技术深度)、C3 支撑(实证) |
| **Related Work 重心** | 重点论证 C1 与现有可微仿真(DiffTALES/Brax)的区别(§4.1 已铺垫) |
| **如果时间紧,先做哪个实验** | 优先做能证明 C1 的实验 → 见 §7 实验优先级 |
| **Rebuttal 策略** | 若 reviewer 质疑 C1"不够新",用 C2 三大障碍 + C3 实证反击 |

**一句话定位**:这篇论文卖的不是"3% 提升",而是"**可微优化范式首次进入 LEO 星座设计**"。
3% 是范式可行性的证据,不是核心卖点。这个定位决定了整篇论文的叙事框架。
"""


def section_3_title_abstract():
    return """## §3 Title & Abstract 候选

### 3.1 三个候选标题(含推演)

| # | 标题 | 关键词覆盖 | 检索性 | 记忆性 | 评价 |
|---|------|-----------|--------|--------|------|
| 1 | Differentiable LEO Constellation Optimization:End-to-End Gradient-based Coverage Tuning | Differentiable + LEO + Coverage | ⭐⭐⭐ | ⭐⭐ | 副标题过长,抓不住核心 |
| 2 | **DiffLEO**:End-to-End Differentiable Simulation for LEO Constellation Coverage Optimization | DiffLEO + Differentiable + LEO + Coverage | ⭐⭐⭐ | ⭐⭐⭐ 命名 | ✅ **推荐** |
| 3 | Gradient-based Walker Constellation Design with Differentiable J2 Propagation | Gradient + Walker + J2 | ⭐⭐ | ⭐ | 过度强调 J2(实现细节),弱化端到端创新 |

### 3.2 推荐标题(标题 2 变体)

```
DiffLEO: End-to-End Differentiable Simulation for
         LEO Constellation Coverage Optimization
```

**推荐理由**:
1. **"DiffLEO" 命名** → 易记忆,易被后续论文引用("DiffLEO showed that...")
2. **"End-to-End Differentiable Simulation"** → 准确点出系统本质(替代弱化的 "Framework")
3. **"LEO Constellation Coverage Optimization"** → 精确锁定问题域 + 完整关键词覆盖
4. 长度适中(15 词),适合 INFOCOM 13 页格式

### 3.3 Abstract 草稿(英文,~185 词,匹配 DiffLEO 标题)

```
Low Earth Orbit (LEO) mega-constellations (e.g., Starlink, OneWeb) require
careful tuning of Walker parameters (number of satellites F, planes P,
inclination i, altitude alt) to maximize coverage and minimize latency.
Existing constellation design relies on grid search or heuristic optimization,
which scale poorly as F grows to thousands. We present DiffLEO, the first
end-to-end differentiable simulation pipeline for LEO constellation
optimization. DiffLEO makes the entire chain—from orbit propagation,
inter-satellite link (ISL) topology selection, to coverage computation—
differentiable, enabling gradient-based optimization (Adam) of Walker
parameters. We resolve three key non-differentiability obstacles: (i) SGP4
numerical tables are non-differentiable (replaced by analytical J2
propagation); (ii) ISL topology selection is discrete (relaxed via sigmoid
soft thresholds); (iii) coverage is a step function (relaxed via noisy-OR
and soft sigmoid). On Starlink-scale constellations (1584 satellites),
DiffLEO improves coverage by ≥3% over Walker-uniform baselines in under
10 minutes, versus hours for grid search. We validate gradient correctness
against finite differences (relative error < 1e-4) and confirm optimized
parameters remain valid under high-precision SGP4 truth propagation.
```

### 3.4 Keywords(6 个,匹配新标题)

```
DiffLEO, LEO satellite constellation, end-to-end differentiable simulation,
gradient-based optimization, Walker constellation design, coverage optimization
```
"""


def section_4_related_work(data, title_to_key):
    """§4 Related Work:5 子方向,每方向论文+对比分析"""
    secs = data["sections"]

    # 从各板块筛选代表作
    def pick_papers(items, keywords, n=8):
        out = []
        for p in items:
            tl = p["title"].lower()
            if any(k in tl for k in keywords):
                out.append(p)
            if len(out) >= n:
                break
        return out

    # 子方向 1: 可微物理仿真(跨领域借鉴)
    diff_sim_kw = ["differentiab", "autodiff", "gradient", "surrogate"]
    diff_sim = []
    for sid in ["06", "01"]:
        diff_sim.extend(pick_papers(secs[sid], diff_sim_kw, n=5))

    # 子方向 2: LEO 星座设计优化
    const_opt_kw = ["constellation design", "walker", "shell", "orbit design"]
    const_opt = pick_papers(secs["01"], const_opt_kw, n=8)

    # 子方向 3: 自动微分在天体力学
    ad_orbit_kw = ["orbit determ", "state estimat", "tracking", "orbital predict",
                   "orbit predict", "tle", "ephemeris"]
    ad_orbit = pick_papers(secs["01"], ad_orbit_kw, n=8)

    # 子方向 4: 卫星网络覆盖优化(传统 baseline)
    coverage_kw = ["coverage", "optimization", "constellation"]
    coverage = pick_papers(secs["01"], coverage_kw, n=8)

    # 子方向 5: 端到端可微优化范式(跨领域)
    e2e_kw = ["end-to-end", "joint optim", "gradient descent"]
    e2e = pick_papers(secs["06"], e2e_kw, n=8)

    def render_papers(papers, max_n=6):
        lines = []
        for p in papers[:max_n]:
            key = get_key(title_to_key, p["title"])
            title = clean_title(p["title"])[:70]
            lines.append(f"  - \\cite{{{key}}} — {p['year']} · {title}")
        return "\n".join(lines)

    return f"""## §4 Related Work 深度分析

按 5 个子方向分组,每方向列代表作并给出"本工作与上述的区别"。

### 4.1 可微物理仿真(跨领域借鉴)

**代表作**(从板块 06 + 01):
{render_papers(diff_sim)}

**子方向小结**:可微物理仿真在流体力学(DiffTALES)、机器人(Brax/MJX)、热仿真等
领域已成熟,核心思路是用解析公式替代数值表 + 软阈值松弛离散决策。

**本工作的区别**:我们是首个将可微物理仿真范式应用到 LEO 卫星网络覆盖优化的工作。
与流体/机器人可微仿真不同,我们需要处理卫星网络特有的离散拓扑选择(ISL)和
阶跃覆盖率函数,提出 R1-R4 四种松弛策略。

### 4.2 LEO 星座设计与 Walker 参数优化

**代表作**(板块 01):
{render_papers(const_opt)}

**子方向小结**:传统星座设计依赖网格搜索(对 F/P/i/alt 4 维参数枚举)、
遗传算法、或启发式规则。计算复杂度 O(N^k)(k=参数维度),F=1584 时数小时。

**本工作的区别**:我们用梯度优化替代网格搜索,复杂度从 O(N^k) 降至 O(N·T·iter)
(T=时间步,iter=优化迭代数),在 F=1584 时 < 10 分钟。

### 4.3 自动微分在天体力学

**代表作**(板块 01):
{render_papers(ad_orbit)}

**子方向小结**:卫星轨道确定/状态估计中,扩展卡尔曼滤波(EKF)需 Jacobian,
传统做法是数值差分。近年 ForwardDiff/Enzyme 等自动微分工具使解析 Jacobian 可得。

**本工作的区别**:我们不只对轨道传播求 Jacobian,而是把整个"传播→链路→覆盖→loss"
链路端到端可微化,实现 loss 对 Walker 参数 F/P/i/alt 的梯度。

### 4.4 端到端可微优化范式

**代表作**(板块 06):
{render_papers(e2e)}

**子方向小结**:端到端可微优化在通信(MU-MIMO 预编码)、光学、热设计等领域已应用,
核心是"前向仿真 + 反向梯度 + Adam 优化"三件套。

**本工作的区别**:我们首次将该范式应用于 LEO 星座网络,且解决了卫星特有的
可微性障碍(SGP4 数值表、离散 ISL、阶跃覆盖)。

### 4.5 卫星网络覆盖优化(传统 baseline)

**代表作**(板块 01):
{render_papers(coverage)}

**子方向小结**:卫星网络覆盖优化传统方法包括:整数线性规划(ILP)、模拟退火、
强化学习(近期)。这些方法或需离散化(损失精度),或采样效率低(RL)。

**本工作的区别**:梯度优化提供连续参数空间的精确下降方向,相较 ILP 不需离散化,
相较 RL 采样效率高数个量级。
"""


def section_5_motivation():
    return """## §5 Motivation 与问题定义

### 5.1 痛点论证(为什么需要可微优化)

**痛点 1:参数空间巨大**
LEO 星座设计参数至少 6 维:
- F(总卫星数):24 ~ 30000+
- P(轨道面数):1 ~ 80
- i(倾角):0° ~ 180°(常见 30°-100°)
- alt(高度):340km ~ 1200km
- e(偏心率):0 ~ 0.05
- Ω₀(初始 RAAN 分布)

网格搜索对 6 维参数即使每维 10 个值,也需 10⁶ = 100 万次仿真。F=1584 单次仿真 ~30s,
总计 ~1 年。

**痛点 2:传统优化方法效率低**
- 网格搜索:O(N^k),F=1584 时数小时~数天
- 遗传算法:需上百代进化,每代评估种群
- 强化学习:需百万步交互,训练慢且收敛不稳

**痛点 3:无梯度信息**
传统方法全是 zero-order(只用 loss 值),忽略了一阶梯度信息。
一阶方法(Adam)在低维(6 维)参数空间通常收敛快 100× 以上。

### 5.2 形式化问题定义

```
给定:
  - 用户分布 D = {(lat_j, lon_j, w_j)}  (j = 1..M, w_j = 权重)
  - 时间窗 [0, T]
  - Walker 约束:F, P 必须满足 P | F

求:
  θ* = argmin_θ  L(θ; D, T)

其中 θ = (F, P, i, alt, e, Ω₀)
损失函数:
  L(θ) = α · Coverage_loss(θ) + β · Latency_loss(θ) + γ · Capacity_loss(θ)

约束:
  - F mod P == 0  (Walker 均匀性,通过参数化保证)
  - alt ∈ [340, 1200] km  (LEO 范围)
  - i ∈ [0°, 180°]
```

### 5.3 可微性挑战与解决(对应 Contribution 2)

| 障碍 | 不可微原因 | 本工作解决 |
|------|-----------|------------|
| **SGP4 数值表** | 含大气模型查表、分支 | 用解析 J2 一阶长期摄动替代 |
| **ISL 拓扑选择** | "距离 < 阈值?" 是离散布尔 | sigmoid 软阈值 + 温度退火 |
| **覆盖率** | "卫星可见?" 是阶跃函数 | noisy-OR + soft sigmoid 松弛 |
| **Walker F,P 约束** | 整数约束 | 参数化为 P_real × round,梯度穿透 |
"""


def section_6_methodology():
    return """## §6 Methodology 设计(基于 src/opt 实际实现)

### 6.1 系统架构:5 层可微管线

```
Walker 参数 θ = (F, P, i, alt, e, Ω₀)
    │
    ▼  [Layer 1: 可微 J2 轨道传播]  ← propagator_j2_differentiable.jl
位置 r(t) ∈ R^{N×T×3}  (N = F 颗卫星, T = 时间步数)
    │
    ▼  [Layer 2: 软 ISL 拓扑]  ← soft_isl.jl
软邻接矩阵 Ã(t) ∈ R^{N×N}  (sigmoid 软阈值)
    │
    ▼  [Layer 3: 链路 + 路由]  ← differentiable_routing.jl
软路由时延 d(p) ∈ R^M  (M = 用户数)
    │
    ▼  [Layer 4: 软覆盖]  ← coverage.jl
软覆盖率 c_j ∈ [0,1]^M  (noisy-OR 聚合)
    │
    ▼  [Layer 5: 复合 Loss]  ← loss.jl
L(θ) = α·Coverage_loss + β·Latency_loss + γ·Capacity_loss
    │
    ▼  Enzyme/Zygote 反向传播
∇_θ L  →  Adam 更新 θ  ← adam.jl
```

### 6.2 各层数学公式(实际实现)

**Layer 1: 可微 J2 传播**(基于 Bate-Mueller-White / Vallado 教科书)

J2 一阶长期摄动漂移率(全部解析,ForwardDiff 透明):

```
J2 = 1.0826261732367e-3  (EGM96)
n = sqrt(μ / a³)                       # 平均运动
p = a(1 - e²)                          # 半通径
factor = (3/2) · J2 · n · (R_⊕/p)²

Ω̇ = -factor · cos(i)                   # RAAN 漂移
ω̇ = factor · (5cos²i - 1)/2            # 近地点进动
Ṁ = n + factor · √(1-e²) · (3cos²i-1)/2  # 平近点角漂移

# 时刻 t 的轨道根数
Ω(t) = Ω₀ + Ω̇·t
M(t) = M₀ + Ṁ·t
```

**Layer 2: 软 ISL 拓扑**

```
# 硬阈值(不可微):
A[i,j] = dist(i,j) < d_thresh ? dist(i,j) : Inf

# 软阈值(可微,sigmoid):
σ(z) = 1/(1 + e^(-z))
soft_mask(i,j) = σ((d_thresh - dist(i,j)) / τ)   # τ = 温度
Ã[i,j] = dist(i,j) · soft_mask(i,j)              # τ→0 时 → 硬阈值
```

**Layer 4: 软覆盖(R1-R4 四种松弛,coverage.jl 实际实现)**

```
# R1: SoftCoverage — 仰角阈值软化
z = (elevation - min_el) / τ
soft_visible = 1/(1 + e^(-z))

# R2: NoisyORCoverage — 多卫星聚合(替代 any/硬或)
P(covered) = 1 - Π_j (1 - soft_visible_j)

# R3: LeakyRevisit — 重访间隔软化(可选)
# R4: LogSumExpMax — 软最大值(替代 hard max)
LSE(x; τ) = τ · log(Σ e^(x_i/τ))
```

**Layer 5: Adam 优化**(Kingma & Ba, 2015;Enzyme 反向模式)

```
m_t = β₁·m_{t-1} + (1-β₁)·g_t          # 一阶矩
v_t = β₂·v_{t-1} + (1-β₂)·g_t²         # 二阶矩
m̂ = m_t / (1-β₁^t)                      # 偏差修正
v̂ = v_t / (1-β₂^t)
θ_{t+1} = θ_t - lr · m̂ / (√v̂ + ε)

默认:lr=0.01, β₁=0.9, β₂=0.999, ε=1e-8
验证速度:28 ms/step (24 颗卫星, Enzyme 反向)
```

### 6.3 梯度正确性验证(end_to_end_gradient.jl)

三种梯度计算对比:
1. **ForwardDiff** 前向模式(逐参数,基准)
2. **Enzyme** 反向模式(本项目用,高效)
3. **有限差分**(数值基准,central difference)

验证指标:
- `max_relerr_forward_vs_fd`:ForwardDiff vs FD 相对误差(应 < 1e-4)
- `max_relerr_reverse_vs_forward`:Enzyme vs ForwardDiff 相对误差(应 < 1e-6)
- `finite_forward / finite_reverse / finite_fd`:三种梯度是否有限(无 NaN/Inf)

### 6.4 收敛判据(coverage_optimizer.jl ConvergenceReport)

```
连续 convergence_window(默认 10)步 loss 相对变化 < convergence_tol(默认 1e-4)
→ 标记收敛,记录 convergence_step
```
"""


def section_7_experiments():
    return """## §7 Experiment Plan(实验设计)

### 7.0 实验优先级排序(深化推演)

**问题**:5 个实验,4 周内若时间不够,先做哪个?砍哪个?

**逐实验推演——对论文主 contribution(C1 端到端可微范式)的支撑度**:

| 实验 | 支撑哪个 contribution | 不可替代性 | 工作量 | 优先级 |
|------|----------------------|-----------|--------|--------|
| **7.1 主实验**(收敛+覆盖率) | C1 范式可行性 + C3 实证 | 🔴 不可替代(无此则论文无核心数据) | ⭐⭐ 中 | **P0 必做** |
| **7.3 Baseline 对比**(网格/GA/CMA-ES) | C1 范式优越性(快 100×) | 🔴 不可替代(无此则"快"无从对比) | ⭐⭐⭐ 高(需实现 4 个 baseline) | **P0 必做** |
| **7.5 传播器精度**(J2 vs SGP4 truth) | C3 sim-to-real 可信度 | 🟡 重要(挡 reviewer 必问 §10.4) | ⭐ 低 | **P1 强烈建议** |
| **7.4 Scaling**(规模 vs 耗时) | C1 工程可扩展性 | 🟡 加分(证明 6000 卫星可行) | ⭐ 低(改参数即可) | **P1 强烈建议** |
| **7.2 Ablation**(loss 组件) | C2 技术深度 | 🟢 可选(页数紧可砍) | ⭐⭐ 中 | **P2 看页数** |

**Sprint 2 实验执行顺序(基于优先级 + 依赖)**:

```
Week 1(基础):
  └─ 先做 7.5 的"梯度正确性验证"部分(end_to_end_gradient.jl)
     ← 这是所有实验的前提,梯度错则全错

Week 2(核心 P0):
  ├─ 7.1 主实验(Iridium-66 小规模先跑通 → Starlink-1584)
  └─ 7.3 Baseline 对比(先实现随机搜索/网格搜索,CMA-ES/GA 可后补)

Week 3(支撑 P1):
  ├─ 7.5 传播器精度(完整版,用 SGP4 truth 验证优化参数)
  ├─ 7.4 Scaling(扫描 5 个规模)
  └─ 7.3 补全 GA/CMA-ES

Week 4(可选 P2 + 论文):
  ├─ 7.2 Ablation(若页数允许)
  └─ 论文撰写
```

**如果严重延期,砍实验的顺序**(从最后砍起):
1. 砍 7.2 Ablation(P2,不影响主 contribution)
2. 砍 7.4 Scaling 的大规模点(保留 66/1584,砍 3000/6000)
3. **绝不砍** 7.1 主实验 + 7.3 Baseline + 7.5 传播器精度(这三个是论文命脉)

### 7.1 主实验:优化收敛 + 覆盖率提升

| 要素 | 内容 |
|------|------|
| **输入** | 3 个星座规模:Iridium-66 (6×11) / Starlink-1584 (24×66) / 自定义 3000 (30×100) |
| **用户分布** | 全球网格 1000 点 + 人口加权(Gravety Model) |
| **时间窗** | 1 轨道周期(~95 min),T=60s 采样 |
| **输出指标** | (1) 覆盖率提升(% vs Walker 均匀 baseline)<br>(2) Loss 收敛曲线(步数 vs loss)<br>(3) 优化耗时(wall clock) |
| **对标数值** | Walker 均匀参数基线(文献默认);Hypatia 覆盖基准 |
| **预期结论** | 覆盖率提升 ≥ 3%,优化 < 10 分钟(1584 卫星) |
| **代码位置** | `experiments/layered/E1_optimize_coverage.jl` |

### 7.2 Ablation:Loss 组件贡献

| 要素 | 内容 |
|------|------|
| **输入** | 固定星座 Starlink-1584 |
| **变量** | Loss 组合:{coverage} / {coverage+latency} / {coverage+capacity} / 全部 |
| **输出** | 各组合的最终覆盖率 / 时延 / 容量 |
| **预期结论** | 多目标 loss 平衡三者,trade-off 曲线 |
| **代码位置** | `experiments/layered/E1_ablation_loss.jl` |

### 7.3 Baseline 对比:优化算法

| 要素 | 内容 |
|------|------|
| **输入** | 固定星座规模 66/1584 |
| **对比算法** | (1) 网格搜索(5^4=625 点)<br>(2) 随机搜索(500 次)<br>(3) 遗传算法(NSGA-II,100 代)<br>(4) CMA-ES<br>(5) **本项目 Adam(梯度)** |
| **公平性** | 所有算法相同 loss 函数、相同评估预算(evals) |
| **输出** | 收敛曲线(评估次数 vs best loss)、最终覆盖率、wall clock |
| **对标数值** | 文献中网格搜索/遗传算法在星座设计的典型效果 |
| **预期结论** | Adam 收敛快 10-100×,最终覆盖率持平或更优 |
| **代码位置** | `experiments/layered/E1_baseline_comparison.jl` |

### 7.4 Scaling:星座规模 vs 优化耗时

| 要素 | 内容 |
|------|------|
| **输入** | 星座规模扫描:[24, 66, 1584, 3000, 6000] |
| **输出** | (1) 单步梯度耗时 vs N<br>(2) 总优化耗时(wall clock) vs N<br>(3) 内存占用 vs N |
| **预期结论** | 梯度耗时 ~O(N²)(软 ISL 邻接矩阵主导),6000 卫星仍可行 |
| **代码位置** | `experiments/layered/E1_scaling.jl` |

### 7.5 传播器精度:可微 J2 vs SGP4 truth

| 要素 | 内容 |
|------|------|
| **输入** | 用 Adam 优化后的 Walker 参数 |
| **输出** | (1) J2 预测位置 vs SGP4 truth 位置 RMSE<br>(2) 用 J2 优化的覆盖率 vs 用 SGP4 truth 算的覆盖率 |
| **对标数值** | J2 1天误差 ~几 km(文献基准) |
| **预期结论** | 优化结果对 truth 传播器仍成立(覆盖率误差 < 10%) |
| **代码位置** | `experiments/layered/E1_propagator_validation.jl` |
"""


def section_8_figures():
    return """## §8 Figure & Table 清单

### 8.1 系统架构图(Figure 1)

| 字段 | 内容 |
|------|------|
| **标题** | Differentiable LEO simulation pipeline architecture |
| **数据来源** | §6.1 系统架构描述 |
| **绘制方法** | LaTeX TikZ(手画框图,体现 5 层管线 + 梯度回传箭头) |
| **传达信息** | 5 层可微管线 + Enzyme 反向梯度 + Adam 闭环 |

### 8.2 梯度正确性验证(Figure 2)

| 字段 | 内容 |
|------|------|
| **标题** | Gradient correctness:ForwardDiff vs Enzyme vs Finite Difference |
| **数据来源** | §6.3 end_to_end_gradient.jl |
| **绘制方法** | matplotlib 散点图(x=有限差分梯度,y=Enzyme 梯度,对数轴) |
| **传达信息** | 三种梯度一致(对角线),证明反向模式正确 |

### 8.3 收敛曲线(Figure 3,主实验核心)

| 字段 | 内容 |
|------|------|
| **标题** | Convergence of Adam on Starlink-1584 constellation |
| **数据来源** | §7.1 主实验 ConvergenceReport.loss_history |
| **绘制方法** | matplotlib 折线图(x=优化步数,y=loss;3 个星座规模 3 条曲线) |
| **传达信息** | 1584 卫星下 ~100 步收敛,< 10 分钟 |

### 8.4 Baseline 对比(Figure 4)

| 字段 | 内容 |
|------|------|
| **标题** | Comparison with grid/random/GA/CMA-ES baselines |
| **数据来源** | §7.3 baseline 对比 |
| **绘制方法** | matplotlib 折线图(x=函数评估次数,y=best loss;5 条曲线) |
| **传达信息** | Adam 收敛快 10-100× |

### 8.5 覆盖率提升柱状图(Figure 5)

| 字段 | 内容 |
|------|------|
| **标题** | Coverage improvement over Walker-uniform baseline |
| **数据来源** | §7.1 主实验最终覆盖率 |
| **绘制方法** | matplotlib 柱状图(3 个星座规模 × {baseline, Adam} 两组柱) |
| **传达信息** | 各规模下 Adam 提升 ≥3% |

### 8.6 Scaling 曲线(Figure 6)

| 字段 | 内容 |
|------|------|
| **标题** | Scaling:gradient step time vs constellation size |
| **数据来源** | §7.4 Scaling 实验 |
| **绘制方法** | matplotlib 双对数图(x=卫星数 N,y=单步耗时;拟合 O(N²) 斜率) |
| **传达信息** | 6000 卫星单步 < 10s,工程可行 |

### 8.7 Loss 组件贡献(Table 1)

| 字段 | 内容 |
|------|------|
| **标题** | Ablation:loss component contributions |
| **数据来源** | §7.2 Ablation |
| **绘制方法** | LaTeX 表格(行=Loss 组合,列=覆盖率/时延/容量) |
| **传达信息** | 多目标 trade-off,各组件独立贡献 |

### 8.8 传播器精度验证(Table 2)

| 字段 | 内容 |
|------|------|
| **标题** | Validation:J2 vs SGP4 truth on optimized parameters |
| **数据来源** | §7.5 传播器精度 |
| **绘制方法** | LaTeX 表格(行=星座,列=J2 RMSE / SGP4 覆盖率 / 差异%) |
| **传达信息** | 优化结果对 truth 仍成立(差异 < 10%) |
"""


def section_9_baselines():
    return """## §9 Baseline 与数值基准

### 9.1 网络层数值基准(来自 Hypatia)

| 指标 | 数值 | 来源 | 用途 |
|------|------|------|------|
| Paris→Luanda RTT(无 ISL) | 117 ms | Hypatia IMC 2020 | 路由层验证 |
| Paris→Luanda RTT(有 ISL) | 85 ms | Hypatia | ISL 增益 |
| Starlink +Grid ISL | 4 ISL/星(2 intra + 2 inter) | Hypatia | 拓扑基线 |
| 路由重算周期 | 100 ms | satgenpy | 时延精度 |

### 9.2 传播器精度基准(来自文献)

| 传播器 | LEO 1天位置误差 | 来源 |
|--------|----------------|------|
| Two-Body | 10s-100s km | Vallado 教科书 |
| J2(本项目用) | 几 km-10s km | SatelliteToolbox 文档 |
| SGP4 | ~1-3 km(近历元) | Wikipedia SGP4 |
| HPOP(数值积分) | 亚米-几米 | STK/GMAT |

### 9.3 优化算法基准

| 算法 | 复杂度 | F=1584 耗时(估) | 来源 |
|------|--------|-----------------|------|
| 网格搜索 | O(N^k) | 数小时~数天 | 传统星座设计 |
| 遗传算法(NSGA-II) | O(pop·gen·eval) | 数小时 | 多目标优化文献 |
| CMA-ES | O(λ·eval) | 数小时 | 进化策略 |
| 强化学习 | O(10^6 steps) | 数小时-数天 | 近期 LEO RL 论文 |
| **Adam(本项目)** | O(N·T·iter) | **< 10 分钟** | 本工作 |

### 9.4 文献报告的覆盖率提升幅度

| 来源 | 方法 | 覆盖率提升 |
|------|------|-----------|
| 传统网格搜索 | 6 维枚举 | baseline(0%) |
| GA-based 设计 | 遗传算法 | +1-2%(文献零星报告) |
| ML-based 设计 | 强化学习 | +2-3%(近期论文) |
| **本项目目标** | 可微优化 | **≥ 3%** |

> 注:覆盖率提升幅度的绝对值取决于用户分布定义。
> 本项目用"被至少 1 颗卫星可见(min_el=10°)的用户比例"作为覆盖率定义,
> 与 Hypatia/OpenSN 一致,确保可比性。
"""


def section_10_reviewer():
    return """## §10 Reviewer 预判与回应准备

### 10.1 预判 1:与传统优化的公平性

| 字段 | 内容 |
|------|------|
| **质疑** | "Adam 与网格搜索/GA 对比是否公平?评估次数是否对齐?" |
| **严重度** | 🔴 高(几乎必问) |
| **回应** | §7.3 实验设计已对齐:所有算法相同 loss 函数、相同评估预算(evals)。
   主张 Adam 在相同预算下收敛更快(收敛曲线 Figure 4 证明) |

### 10.2 预判 2:局部最优

| 字段 | 内容 |
|------|------|
| **质疑** | "Adam 收敛到局部最优,可能不如全局优化(GA/CMA-ES)?" |
| **严重度** | 🟡 中 |
| **回应** | (1) 用多起点(5-10 个不同初始化)Adam,取最佳;
   (2) 与 CMA-ES(全局)对比,若 Adam 多起点持平则证明局部最优可接受;
   (3) 6 维参数空间不算高维,Adam 通常能找到全局 |

### 10.3 预判 3:梯度数值正确性

| 字段 | 内容 |
|------|------|
| **质疑** | "如何证明 Enzyme 反向梯度正确?可能实现有 bug" |
| **严重度** | 🔴 高 |
| **回应** | §6.3 三梯度对比(ForwardDiff/Enzyme/有限差分)相对误差 < 1e-4,
   Figure 2 散点图对角线证明。这是论文核心,必须充分。 |

### 10.4 预判 4:J2 vs SGP4 精度

| 字段 | 内容 |
|------|------|
| **质疑** | "用 J2 替代 SGP4 优化,结果对真实 SGP4 传播还成立吗?" |
| **严重度** | 🔴 高 |
| **回应** | §7.5 实验:用 J2 优化的参数,再用 SGP4 truth 算覆盖率,
   差异 < 10%。证明 J2 优化的 sim-to-real 迁移可行。 |

### 10.5 预判 5:覆盖率提升幅度小

| 字段 | 内容 |
|------|------|
| **质疑** | "只有 3% 覆盖率提升,有意义吗?Walker 均匀已经很好了" |
| **严重度** | 🟡 中 |
| **回应** | (1) 3% 是全球覆盖率,对应数百万用户;
   (2) 在热点区域(如赤道盲区)提升可达 10-15%;
   (3) 优化还能改善时延/容量(多目标),不仅覆盖率;
   (4) 真正价值是优化"速度"(分钟 vs 小时),不只是幅度 |

### 10.6 预判 6:与 ML 方法的对比

| 字段 | 内容 |
|------|------|
| **质疑** | "为什么不用强化学习?近期 LEO RL 论文很多" |
| **严重度** | 🟡 中 |
| **回应** | (1) RL 需百万步交互,训练慢;
   (2) RL 收敛不稳,需 reward shaping;
   (3) 梯度优化精确利用一阶信息,6 维参数下效率高 100×;
   (4) 可在 Related Work 充分讨论 RL baseline(§4.5) |

### 10.7 预判 7:工程可复现性

| 字段 | 内容 |
|------|------|
| **质疑** | "实验是否开源?参数能否复现?" |
| **严重度** | 🟢 低(但加分) |
| **回应** | (1) 计划开源 SatelliteSimJulia(Julia 生态);
   (2) 论文附 artifact appendix(随机种子、超参、数据);
   (3) 实验脚本 repo 链接 |
"""


def section_11_timeline():
    return """## §11 写作 Timeline(基于 Sprint 2,4 周)

### Week 1:可微闭环联调 + 梯度验证

| 任务 | 交付 | 验收 |
|------|------|------|
| 可微 J2 单元测试 | `test/opt/propagator_j2_test.jl` | ForwardDiff 梯度数值正确 |
| 软 ISL / 软覆盖测试 | `test/opt/coverage_test.jl` | R1-R4 松弛可微 |
| 梯度正确性验证 | `experiments/layered/E0_gradient_check.jl` | **Figure 2 数据**:三梯度 < 1e-4 |

### Week 2:主实验 + Baseline

| 任务 | 交付 | 验收 |
|------|------|------|
| optimize_coverage driver 联调 | `experiments/layered/E1_optimize_coverage.jl` | 1584 卫星收敛 |
| Baseline 对比(网格/随机/GA/CMA-ES) | `E1_baseline_comparison.jl` | **Figure 3, 4, 5 数据** |
| Scaling 实验 | `E1_scaling.jl` | **Figure 6 数据** |

### Week 3:论文初稿

| 任务 | 交付 | 验收 |
|------|------|------|
| 论文框架 + 各 section 草稿 | `paper/differentiable_coverage/main.tex` | 12-15 页初稿 |
| Figure 绘制(用 Week 1-2 数据) | `paper/differentiable/figures/` | Figure 1-6 完成 |
| Related Work + Methodology 完善 | LaTeX | 引用 ≥ 40 篇 |

### Week 4:修订 + 投稿

| 任务 | 交付 | 验收 |
|------|------|------|
| 自审 + 同行预审 | 修订稿 | 解决 §10 所有预判质疑 |
| Ablation + 传播器精度补充 | `E1_ablation.jl` / `E1_propagator_validation.jl` | **Table 1, 2 数据** |
| 投稿 IEEE Trans. Networking | PDF + cover letter | 提交确认 |

**关键里程碑**:
- Week 1 末:梯度验证通过(Contribution 2 成立)
- Week 2 末:主实验覆盖率提升 ≥ 3%(Contribution 3 成立)
- Week 3 末:论文初稿完成
- Week 4 末:投稿
"""


def section_12_citations(data, title_to_key):
    """§12 附录:核心引用清单(40-50 篇,带 BibTeX key)"""
    secs = data["sections"]

    citations = []

    # 1. 可微/优化核心方法(板块 06 tier1,17 篇)
    for p in [x for x in secs["06"] if x["tier"] == "tier1"][:12]:
        citations.append({
            "key": get_key(title_to_key, p["title"]),
            "title": clean_title(p["title"])[:65],
            "year": p["year"],
            "section": "Related Work §4.1,4.4 / Methodology §6",
            "reason": "可微/梯度优化方法",
        })

    # 2. 星座设计/轨道(板块 01 top)
    for p in secs["01"][:8]:
        citations.append({
            "key": get_key(title_to_key, p["title"]),
            "title": clean_title(p["title"])[:65],
            "year": p["year"],
            "section": "Related Work §4.2,4.3 / Experiment §7",
            "reason": "星座设计/轨道传播 baseline",
        })

    # 3. 路由/网络(板块 04 top,Hypatia 对标)
    for p in secs["04"][:6]:
        citations.append({
            "key": get_key(title_to_key, p["title"]),
            "title": clean_title(p["title"])[:65],
            "year": p["year"],
            "section": "Related Work §4.5 / Baseline §9",
            "reason": "路由算法 baseline",
        })

    # 4. ISL/链路(板块 02 top)
    for p in secs["02"][:5]:
        citations.append({
            "key": get_key(title_to_key, p["title"]),
            "title": clean_title(p["title"])[:65],
            "year": p["year"],
            "section": "Methodology §6.2 / Experiment §7",
            "reason": "ISL 拓扑/链路评估",
        })

    # 5. 切换(板块 09 top,可选)
    for p in secs["09"][:4]:
        citations.append({
            "key": get_key(title_to_key, p["title"]),
            "title": clean_title(p["title"])[:65],
            "year": p["year"],
            "section": "Related Work(扩展)",
            "reason": "切换/移动性(若论文涉及)",
        })

    # 6. PINN/NN(板块 07 top,可选,为后续工作铺垫)
    for p in secs["07"][:5]:
        citations.append({
            "key": get_key(title_to_key, p["title"]),
            "title": clean_title(p["title"])[:65],
            "year": p["year"],
            "section": "Related Work / Future Work",
            "reason": "PINN 神经传播(为第二篇铺垫)",
        })

    lines = ["## §12 附录:核心引用清单\n\n"]
    lines.append(f"共 {len(citations)} 篇核心引用,均对应 `_bibliography.bib` 中的 BibTeX key。\n\n")
    lines.append("| # | BibTeX key | 年份 | 标题 | 引用位置 | 引用理由 |\n")
    lines.append("|---|-----------|------|------|----------|----------|\n")
    for i, c in enumerate(citations, 1):
        lines.append(f"| {i} | `{c['key']}` | {c['year']} | "
                     f"{c['title']} | {c['section']} | {c['reason']} |\n")
    lines.append("\n### 使用说明\n\n")
    lines.append("- LaTeX 中用 `\\cite{key}` 引用,如 `\\cite{" + citations[0]["key"] + "}`\n")
    lines.append("- 完整 BibTeX 条目在 `_bibliography.bib`(共 3020 条)\n")
    lines.append("- 分板块文件 `_citations_06_可微优化.bib` 等便于按需 include\n")
    lines.append("- 写作时如需补充新文献,先用 `scripts/arxiv_collector.py` 抓取,\n"
                 "  再手动添加到 `_bibliography.bib`\n")

    return "".join(lines)


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
def main():
    if not os.path.exists(JSON_IN):
        raise SystemExit(f"JSON 不存在:{JSON_IN}")

    with open(JSON_IN, "r", encoding="utf-8") as f:
        data = json.load(f)

    print("加载 BibTeX key 映射...")
    title_to_key = load_bib_keys()
    print(f"  共 {len(title_to_key)} 个 key 映射")

    print("生成论文素材库...")
    sections = [
        ("§1 论文定位", section_1_positioning()),
        ("§2 核心贡献", section_2_contributions()),
        ("§3 标题摘要", section_3_title_abstract()),
        ("§4 Related Work", section_4_related_work(data, title_to_key)),
        ("§5 Motivation", section_5_motivation()),
        ("§6 Methodology", section_6_methodology()),
        ("§7 Experiment", section_7_experiments()),
        ("§8 Figure", section_8_figures()),
        ("§9 Baseline", section_9_baselines()),
        ("§10 Reviewer", section_10_reviewer()),
        ("§11 Timeline", section_11_timeline()),
        ("§12 引用附录", section_12_citations(data, title_to_key)),
    ]

    out = []
    out.append("# 第一篇论文写作素材库\n\n")
    out.append("> **论文主题**:端到端可微 LEO 星座覆盖优化\n")
    out.append("> (Enzyme/Zygote + 可微 J2 + 软覆盖 loss + Adam)\n\n")
    out.append("> **对应 Sprint**:Sprint 2(可微优化闭环,4 周)\n\n")
    out.append("> **目标 venue**:IEEE Trans. on Networking(首选)/ INFOCOM(备选)\n\n")
    out.append("> **素材库用途**:作为后续撰写 LaTeX 论文的工作台,各 section 可直接拷贝/修改\n\n")
    out.append("> **生成日期**:2026-07-04 · 数据来源:本地 2640 篇文献库 + src/opt 实际实现\n\n")
    out.append("---\n\n")
    out.append("## 目录\n\n")
    for name, _ in sections:
        out.append(f"- [{name}](#{name.lower().replace(' ', '-')})\n")
    out.append("\n---\n\n")

    for name, content in sections:
        out.append(content)
        out.append("\n---\n\n")

    with open(MD_OUT, "w", encoding="utf-8") as f:
        f.write("".join(out))

    print(f"\n✓ 论文素材库已生成:{MD_OUT}")
    # 统计
    total_lines = "".join(out).count("\n")
    cite_count = "".join(out).count("\\cite{")
    print(f"  总行数:{total_lines}")
    print(f"  \\cite 引用数:{cite_count}")


if __name__ == "__main__":
    main()
