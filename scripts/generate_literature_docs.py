#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
SatelliteSimJulia 文献综述 Markdown 生成脚本

读取 build_literature_index.py 产出的 _data.json, 生成:
  docs/literature/00_总览索引.md
  docs/literature/01_轨道传播层.md ... 10_TCP传输层.md
  docs/literature/11_分类汇总与研究机会.md

每个板块 .md 统一结构:
  1. 定位 (对应项目模块)
  2. 核心问题与关键指标
  3. 文献分类汇总表 (按子主题分组)
  4. 论文清单 (全量表格)
  5. 关键发现与对标基准
  6. 研究空白与本项目切入点
"""

import json
import os
import re
from collections import Counter, defaultdict

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.dirname(SCRIPT_DIR)
OUT_DIR = os.path.join(PROJECT_DIR, "docs", "literature")
JSON_IN = os.path.join(OUT_DIR, "_data.json")

# ---------------------------------------------------------------------------
# 板块元信息: 名称、对应模块、核心问题、关键指标、对标基准、子主题分组规则
# ---------------------------------------------------------------------------
SECTIONS_META = {
    "01": {
        "name": "轨道传播层",
        "module": "`src/orbit`",
        "problem": (
            "如何在长时间尺度上高精度、低成本地预测卫星位置?LEO 卫星轨道受地球扁率(J2)、"
            "大气阻力、日月引力等摄动影响,不同力模型在精度与计算成本间存在巨大权衡。"
            "SatelliteSimJulia 用裸 `Array{Float64,3}` 承载星历,层间按时间片对齐——"
            "传播器精度直接决定下游 ISL/路由/覆盖所有指标的可靠性。"
        ),
        "metrics": [
            "位置误差 RMS / 最大值 (km),相对 truth(数值积分/HPOP)",
            "误差 vs 时长曲线 (1 轨 ~95min / 1 天 / 7 天 / 30 天)",
            "沿迹 / 径向 / 法向三分量误差分解",
            "计算成本 (单步传播耗时,可微性)",
        ],
        "benchmarks": [
            ("Two-Body", "LEO 1 天位置误差 ~10s–100s km"),
            ("J2 / J4", "LEO 1 天 ~几 km–10s km (可微首选)"),
            ("SGP4", "近历元 ~1–3 km,7 天 ~10–25 km,30 天 ~40–100+ km"),
            ("HPOP (数值积分)", "亚米–几米,金标准"),
        ],
        "subtopics": [
            ("传播算法对比", ["propagat", "sgp4", "tle", "two-body", "twobody",
                              "two body", "j2", "j4", "kepler", "numerical integrat"]),
            ("星座设计与生成", ["constellation design", "constellation generat",
                                "walker", "walker-delta", "shell"]),
            ("轨道确定与状态估计", ["orbit determ", "orbit estimat",
                                     "state estimat", "orbit predict", "tracking"]),
            ("星历/TLE 数据源", ["tle", "two-line element", "ephemeris",
                                 "catalog", "space catalog"]),
            ("其他(摄动/机动)", []),
        ],
        "gap": (
            "可微 SGP4/J2 端到端梯度穿透到网络层优化的工作几乎空白;"
            "本项目 `src/opt` 用 Enzyme/Zygote 实现可微 J2 是直接切入点。"
        ),
    },
    "02": {
        "name": "ISL/GSL 链路评估层",
        "module": "`src/link`",
        "problem": (
            "如何评估卫星间(ISL)和星地(GSL)链路的物理可用性与质量?"
            "ISL/GSL 的距离、可见性(LOS)、仰角、方位角、自由空间损耗决定了"
            "哪些链路能建立、容量多大、时延多少。SatelliteSimJulia 的 link 层"
            "消费轨道层的 `Array{Float64,3}` 算出链路质量矩阵,是拓扑/路由的基础。"
        ),
        "metrics": [
            "链路距离 (km) 与传播时延 (ms)",
            "可见性窗口时长 / 仰角时序",
            "自由空间损耗 / 接收功率 / 信噪比",
            "链路可用率 (满足阈值的时间占比)",
            "切换频次 (链路建立/断开次数)",
        ],
        "benchmarks": [
            ("ISL 拓扑", "Starlink 每星 4 条 ISL (+Grid: 2 intra + 2 inter)"),
            ("LEO 仰角阈值", "地面站常用 min_elevation = 10°"),
            ("光 ISL 时延", "每跳 ~5ms (距离 ~1500km / c)"),
        ],
        "subtopics": [
            ("ISL 拓扑与规划", ["inter-satellite link", "isl", "isl topology",
                                "isl pattern", "link assignment", "isl planning"]),
            ("激光/光通信链路", ["laser", "optical link", "free space optic",
                                "fso", "optical inter-satellite"]),
            ("GSL 星地链路与可见性", ["ground-satellite", "ground station",
                                       "gsl", "feeder link", "elevation",
                                       "visibility", "los"]),
            ("链路质量与容量建模", ["link quality", "link budget", "capacity",
                                     "snr", "received power"]),
            ("其他(切换/动态)", []),
        ],
        "gap": (
            "动态激光 ISL 建立时延的量化建模较少(本项目可补充);"
            "可微链路评估(梯度穿透到链路参数优化)是空白。"
        ),
    },
    "03": {
        "name": "拓扑策略层",
        "module": "`src/net`",
        "problem": (
            "如何设计 ISL 连接关系(谁连谁)形成鲁棒、低时延、易路由的时变拓扑?"
            "拓扑策略(+Grid/Mesh/T/Honeycomb/Ring 等)决定了网络的度分布、直径、"
            "连通性、鲁棒性。LEO 拓扑因卫星运动而时变,需处理快照切换与 churn。"
        ),
        "metrics": [
            "度分布 / 平均度",
            "网络直径 / 平均最短路径",
            "连通性比例 / 连通分量数",
            "聚类系数 / 介数中心性 / 代数连通度(Fiedler)",
            "链路 churn 率 (相邻帧边集对称差)",
            "鲁棒性曲线 (删 k% 节点后最大连通簇占比)",
        ],
        "benchmarks": [
            ("+Grid 拓扑", "Starlink 标准 4-ISL 结构"),
            ("3-ISL 拓扑", "南京大学给出直径/跳数解析公式"),
            ("Hypatia", "路由每 100ms 重算一次"),
        ],
        "subtopics": [
            ("拓扑设计与优化", ["topology design", "constellation topology",
                                "topology optim", "demand-aware"]),
            ("时变/快照拓扑", ["snapshot", "time-evolving", "time varying",
                              "dynamic topology", "topology virtual"]),
            ("ISL 拓扑与连接模式", ["isl topology", "isl pattern", "link assignment",
                                    "inter-satellite link", "+grid", "mesh"]),
            ("拓扑分析(图论指标)", ["robustness", "degree distribution",
                                    "betweenness", "connectivity", "centrality",
                                    "churn"]),
            ("其他", []),
        ],
        "gap": (
            "需求感知(demand-aware)拓扑与可微拓扑联合优化是新兴方向;"
            "拓扑 churn 对路由稳定性的量化影响待深入研究。"
        ),
    },
    "04": {
        "name": "路由算法层",
        "module": "`src/net`",
        "problem": (
            "如何在时变 LEO 拓扑上高效计算源-目路径,平衡时延、负载、稳定性?"
            "这是卫星网络最核心、文献最多的方向。从最短路径(Dijkstra/FW)到"
            "ECMP、负载均衡、段路由、强化学习路由,各有 tradeoff。"
        ),
        "metrics": [
            "平均传播时延 (ms) / 跳数",
            "路由 churn (次/小时,路径稳定性)",
            "时延变异系数 CV = std/mean",
            "最大链路利用率 MLU / 负载标准差",
            "计算开销 (单时隙路由计算耗时)",
            "可达性 (不可达 OD 对比例)",
        ],
        "benchmarks": [
            ("Hypatia", "Paris→Luanda RTT 117ms(无 ISL)/85ms(有 ISL)"),
            ("PAM2023", "平均跳数 ~10,churn 频繁但时延增益小"),
            ("GraphSAGE-LEO", "较 Dijkstra 吞吐 +29% (MDPI 2024)"),
            ("OPSPF", "较 OSPF 通信开销 −57%,故障收敛 −82%"),
        ],
        "subtopics": [
            ("最短路径族 (Dijkstra/FW)", ["shortest path", "shortest-path",
                                           "dijkstra", "floyd", "floyd-warshall"]),
            ("负载均衡 / 最小负载", ["load balanc", "load-balanc",
                                    "minimum load", "min-load", "mlb"]),
            ("ECMP / 多路径", ["ecmp", "multipath", "multi-path", "k-shortest",
                              "k shortest"]),
            ("段路由 (SR) / SDN", ["segment routing", " sdn ",
                                  "software-defined", "source routing"]),
            ("强化学习 / ML 路由", ["reinforcement learning", "graph neural",
                                   "gnn", "graph sage", "deep learning",
                                   "machine learning", "learning-based"]),
            ("时变 / 预测式路由", ["predict", "pre-comput", "time-vary",
                                 "temporal", "teg", "snapshot routing"]),
            ("其他路由", ["routing"]),
        ],
        "gap": (
            "可微路由(梯度直接优化路由策略参数)是空白;"
            "PINN 路由时延预测器(本项目 `src/opt` pinn_routing.jl)属首创。"
        ),
    },
    "05": {
        "name": "流量/容量/时延层",
        "module": "`src/metrics` + `src/traffic`",
        "problem": (
            "给定拓扑与路由,如何评估端到端流量分配、链路负载、网络容量与时延分布?"
            "流量层(AoN 分配)把 demand 映射到路径,容量层算瓶颈,时延层出 CDF。"
            "这一层直接产出论文级指标(RTT 分布、MLU、吞吐)。"
        ),
        "metrics": [
            "RTT 分布 CDF (p50/p95/p99)",
            "链路利用率 (平均/最大)、瓶颈链路识别",
            "网络容量 (总吞吐 Gbps)、最大流",
            "时延 vs 星座规模曲线",
            "队列等待时延 / 拥塞丢包率(需容量模型)",
        ],
        "benchmarks": [
            ("Hypatia", "Starlink 跨洲 RTT ~30–50ms"),
            ("LEO 容量", "每 ISL 典型 10–100 Gbps(光)"),
            ("Mathis 公式", "throughput ≤ MSS/(RTT×√p) 给 TCP 上界"),
        ],
        "subtopics": [
            ("流量工程与负载均衡", ["traffic engineer", "load balanc",
                                    "traffic scheduling", "traffic aware",
                                    "traffic delivery", "traffic diffusion"]),
            ("时延分析与建模", ["latency", "delay", "rtt", "round-trip",
                                "end-to-end latency", "e2e latency"]),
            ("容量与吞吐分析", ["capacity", "throughput", "max-flow",
                                "maximum flow", "bottleneck"]),
            ("拥塞与队列建模", ["congestion", "queue", "queuing",
                               "buffer"]),
            ("其他", []),
        ],
        "gap": (
            "端到端可微的流量工程(流量矩阵→梯度→星座参数优化)尚无成熟方案;"
            "PINN 流量预测 + 物理约束(流量守恒)是 A 类潜力方向。"
        ),
    },
    "06": {
        "name": "可微优化层",
        "module": "`src/opt`",
        "problem": (
            "如何让整个仿真流水线(轨道→链路→拓扑→路由→指标)对星座参数可微,"
            "从而用梯度优化(Adam)端到端优化覆盖/时延/容量?这是本项目最核心的创新点,"
            "也是文献最稀少的方向——可微物理仿真在卫星领域几乎空白。"
        ),
        "metrics": [
            "梯度可用性 (能否对 F/walker 参数求导)",
            "优化收敛步数 / 最终 loss",
            "优化后覆盖率 / 时延提升幅度",
            "梯度计算耗时 (前向 vs 反向)",
        ],
        "benchmarks": [
            ("ESA ML-dSGP4", "NN 残差修正 J2,精度提升 34%"),
            ("Enzyme/Zygote", "Julia AD 框架,支持嵌套微分"),
            ("Adam", "lr=3e-3,epochs=30 为常用配置"),
        ],
        "subtopics": [
            ("可微仿真 / AD 核心方法", ["differentiab", "autodiff",
                                        "automatic differentiat", "enzyme",
                                        "zygote", "forwarddiff", "reverse-mode",
                                        "surrogate model"]),
            ("梯度优化应用", ["gradient descent", "gradient-based",
                              "end-to-end optim", "joint optim",
                              "joint optimization"]),
            ("数据驱动建模(借鉴)", ["neural network", "deep learning",
                                    "reinforcement learning", "data-driven",
                                    "surrogate", "machine learning argument"]),
            ("其他(轨迹/资源优化)", []),
        ],
        "gap": (
            "⚠️ 领域空白方向:可微 J2/SGP4 传播 + 软覆盖 loss + Adam 端到端"
            "星座优化的完整闭环尚无先例。本项目 `optimize_coverage` driver 属首创。"
            "本板块严格可微论文仅 17 篇,大量借鉴自卫星领域的 ML 优化工作。"
        ),
    },
    "07": {
        "name": "PINN / 神经传播层",
        "module": "`src/opt` (NN layers)",
        "problem": (
            "能否用物理信息神经网络(PINN)替代传统传播器,既匹配数据又满足运动方程?"
            "PINN 把 PDE 残差作为损失惩罚项,是 SciML 的核心范式。本项目探索两条线:"
            "(1) ML 残差修正 J2;(2) PINN 直接替代传播器。"
        ),
        "metrics": [
            "位置 RMSE (PINN vs 传统传播器 vs truth)",
            "物理约束残差 (运动方程 ‖r̈+μ/r³·r‖)",
            "训练耗时 / 推理耗时(星上部署可行性)",
            "泛化能力 (不同高度/倾角的迁移误差)",
        ],
        "benchmarks": [
            ("Raissi 2019", "PINN 奠基,J. Computational Physics"),
            ("DeepXDE", "Lu Lu 的 PINN 求解框架"),
            ("FNO/DeepONet", "神经算子,分辨率不受限"),
            ("PINN 卫星状态估计", "arXiv:2403.19736,2024 首篇"),
        ],
        "subtopics": [
            ("PINN 核心方法", ["pinn", "physics-informed", "physics informed"]),
            ("神经算子 (DeepONet/FNO)", ["neural operator", "deeponet",
                                          "fourier neural", "operator learning"]),
            ("神经 ODE / 动力学建模", ["neural ode", "neural ordinary",
                                      "neural network propagat",
                                      "neural propagat", "learning dynamics"]),
            ("NN 轨道/姿态/热建模(相关)", ["orbit", "trajectory", "attitude",
                                          "dynamics", "thermal", "estimat"]),
            ("其他 NN 应用", []),
        ],
        "gap": (
            "PINN + 卫星网络路由(0 篇)、PINN + 星上计算(0 篇)、"
            "PINN + 卫星流量预测(0 篇)均为完全空白——本项目 pinn_routing.jl 是"
            "首批探索者,具备 A 类论文潜力。"
        ),
    },
    "08": {
        "name": "AI 编排 / LLM Agent 层",
        "module": "`src/lab` (SimAgent/agent_repl)",
        "problem": (
            "如何用大语言模型(LLM)/Agent 把自然语言请求翻译成仿真工具调用,"
            "实现\"自然语言驱动的卫星仿真\"?本项目 lab 层的 SimAgent + Intent"
            "翻译是这一方向的工程实现。"
        ),
        "metrics": [
            "意图识别准确率 (自然语言 → 正确工具)",
            "工具调用成功率 / 端到端任务完成率",
            "防泄漏率 (用户不接触实现名词)",
            "响应时延 (LLM 推理 + 工具执行)",
        ],
        "benchmarks": [
            ("Foundation Models", "GPT-4/Claude 级工具调用能力"),
            ("LLM 卫星运维", "\"Language models are spacecraft operators\""),
            ("意图防泄漏", "本项目 TopologyIntent/RoutingIntent 设计"),
        ],
        "subtopics": [
            ("LLM 直接应用(卫星)", ["large language", "llm", "gpt",
                                   "language model", "generative ai",
                                   "foundation model"]),
            ("LLM + 卫星网络/运维", ["satellite network", "spacecraft",
                                     "orbit", "constellation", "telecom"]),
            ("多智能体 / Agent 编排", ["agent", "multi-agent", "multi agent",
                                      "orchestrat", "autonomous"]),
            ("其他(联邦微调等)", []),
        ],
        "gap": (
            "LLM 驱动的卫星仿真编排器(本项目 agent_repl)无直接对标;"
            "LLM + 物理仿真工具链集成是新兴交叉点。"
        ),
    },
    "09": {
        "name": "切换 / 移动性层",
        "module": "`src/link` + `src/net`",
        "problem": (
            "卫星相对地面高速运动,地面站-卫星(GSL)和卫星间(ISL)连接频繁切换。"
            "如何度量切换频次、中断时长、乒乓率,并设计低中断切换策略?"
        ),
        "metrics": [
            "切换频次 (次/小时,与可见窗口 5–15 min 相关)",
            "中断时长 CDF (硬切换 = 重算时间)",
            "乒乓率 (反复抖动次数)",
            "路由收敛时间 / SPF 重算次数",
        ],
        "benchmarks": [
            ("Hypatia", "假设瞬时切换(无中断度量,简化)"),
            ("LEO 可见窗口", "5–15 min/次"),
            ("OpenSN", "可自定义 GSL handover policy"),
        ],
        "subtopics": [
            ("GSL/波束切换策略", ["handover", "handoff", "hand-off",
                                  "satellite selection", "access selection",
                                  "user association"]),
            ("波束跳变 (Beam Hopping)", ["beam hopping", "beam-hopping",
                                         "beam switch", "spotbeam"]),
            ("移动性与位置管理", ["mobility", "location management",
                                "paging", "tracking"]),
            ("信道分配 / 接入", ["channel assignment", "channel allocation",
                                "dynamic channel", "access"]),
            ("其他", []),
        ],
        "gap": (
            "切换与路由耦合的中断度量(本项目应单独建模)较少;"
            "可微切换策略优化是空白。"
        ),
    },
    "10": {
        "name": "TCP / 传输层",
        "module": "外接 (ns-3 / 解析模型)",
        "problem": (
            "LEO 高时延带宽积(BDP)、移动性导致的路径变化,使传统 TCP(Cubic/BBR)"
            "性能下降。本项目明确划界:只算到链路容量+时延+丢包假设,输出给 ns-3 做 TCP。"
        ),
        "metrics": [
            "吞吐 (goodput)",
            "RTT / 时延抖动",
            "丢包率 / 重传率",
            "收敛时间 (拥塞窗口稳定)",
        ],
        "benchmarks": [
            ("SaTCP INFOCOM2023", "LEO 链路自适应 TCP"),
            ("LeoTCP arXiv 2025", "LEO 专用 TCP"),
            ("BBR vs Cubic", "卫星实测对比"),
            ("Mathis 上界", "throughput ≤ MSS/(RTT×√p)"),
        ],
        "subtopics": [
            ("TCP 拥塞控制 (BBR/Cubic/Hybla)", ["tcp", "congestion control",
                                                "bbr", "cubic", "hybla",
                                                "congestion window"]),
            ("QUIC / HTTP3 卫星", ["quic", "http/3", "http3"]),
            ("PEP 性能增强代理", ["pep", "performance enhancing", "proxy"]),
            ("MPTCP 多路径", ["mptcp", "multipath tcp"]),
            ("其他传输", ["transport", "rtt", "round-trip"]),
        ],
        "gap": (
            "本项目不自实现 TCP(保持简洁),用解析模型给上界;"
            "与 ns-3 的 trace 接口标准化是工程机会。"
        ),
    },
}


# ---------------------------------------------------------------------------
# 工具函数
# ---------------------------------------------------------------------------
TIER_LABEL = {"tier1": "★核心", "tier2": "☆相关", "tier3": "○借鉴"}


def assign_subtopic(title_l, subtopics):
    """根据标题把论文归入第一个命中的子主题, 兜底归入最后"其他"。"""
    for name, keywords in subtopics:
        if name.startswith("其他"):
            continue
        if any(k in title_l for k in keywords):
            return name
    # 找"其他"组
    for name, _ in subtopics:
        if name.startswith("其他"):
            return name
    return subtopics[-1][0]


def finalize(text):
    """压缩 3+ 连续换行为 2 个 (清理 append('') 导致的冗余空行)。"""
    return re.sub(r"\n{3,}", "\n\n", text)


def fmt_source(src):
    src_map = {"arXiv": "arXiv", "CCF": "CCF", "CCF_Conf": "CCF会议",
               "CAS": "CAS", "Aero": "航天", "IntlSup": "国际供",
               "Sim": "仿真"}
    return src_map.get(src, src)


def clean_title(title):
    """去掉标题开头的论文编号前缀 (如 '224. ', '65. ')。"""
    return re.sub(r"^\s*\d+\.\s*", "", title).strip()


def render_paper_table(items):
    """渲染论文清单表格 (Markdown)。"""
    lines = [
        "| # | 相关性 | 年份 | 来源 | 标题 | arXiv/Ref |",
        "|---|--------|------|------|------|-----------|",
    ]
    for i, it in enumerate(items, 1):
        tier = TIER_LABEL.get(it["tier"], it["tier"])
        year = it["year"] or "-"
        src = fmt_source(it["source"])
        title = clean_title(it["title"]).replace("|", "\\|")
        ref = (it["ref"] or "-").replace("|", "\\|")
        lines.append(f"| {i} | {tier} | {year} | {src} | {title} | {ref} |")
    return "\n".join(lines)


def render_subtopic_summary(items, subtopics):
    """渲染子主题分组汇总表。"""
    groups = defaultdict(list)
    for it in items:
        title_l = it["title"].lower()
        grp = assign_subtopic(title_l, subtopics)
        groups[grp].append(it)

    lines = [
        "| 子主题 | 论文数 | 占比 |",
        "|--------|--------|------|",
    ]
    total = len(items)
    # 按 subtopics 定义的顺序输出
    ordered_names = [name for name, _ in subtopics]
    for name in ordered_names:
        cnt = len(groups.get(name, []))
        pct = f"{cnt/total*100:.1f}%" if total else "-"
        lines.append(f"| {name} | {cnt} | {pct} |")
    return "\n".join(lines), groups


# ---------------------------------------------------------------------------
# 各文档生成
# ---------------------------------------------------------------------------
def gen_overview(data):
    """00_总览索引.md"""
    meta = data["meta"]
    secs_meta = data["sections_meta"]
    out = []
    out.append("# SatelliteSimJulia 文献综述 · 总览索引\n")
    out.append("> 本目录汇总与 SatelliteSimJulia 项目相关的学术文献,按 10 个技术层级板块分类。\n")
    out.append(f"> 数据源:`{meta['csv_path']}`(共 **{meta['total_papers_in_db']:,}** 篇)\n")
    out.append(f"> 去重后命中独立论文:**{meta['total_unique_matched']:,}** 篇\n")
    out.append(f"> 生成日期:2026-07-03\n\n")

    out.append("## 目录与导航\n\n")
    out.append("| 板块 | 名称 | 对应模块 | 论文数 | 文档 |")
    out.append("|------|------|----------|--------|------|")
    names = {s["id"]: s["name"] for s in secs_meta}
    modules = {sid: SECTIONS_META[sid]["module"] for sid in SECTIONS_META}
    fname_map = {
        "01": "01_轨道传播层.md", "02": "02_链路评估层.md",
        "03": "03_拓扑策略层.md", "04": "04_路由算法层.md",
        "05": "05_流量容量时延层.md", "06": "06_可微优化层.md",
        "07": "07_PINN神经传播层.md", "08": "08_AI编排LLM层.md",
        "09": "09_切换移动性层.md", "10": "10_TCP传输层.md",
    }
    for sid in ["01", "02", "03", "04", "05", "06", "07", "08", "09", "10"]:
        sm = next(s for s in secs_meta if s["id"] == sid)
        out.append(f"| {sid} | {sm['name']} | {modules[sid]} | "
                   f"{sm['total']} | [{fname_map[sid]}]({fname_map[sid]}) |")
    out.append(f"| 11 | 分类汇总与研究机会 | 跨板块 | - | [11_分类汇总与研究机会.md](11_分类汇总与研究机会.md) |")
    out.append(f"| 📊 | 汇报 PPT | 全景 | - | [SatelliteSimJulia文献调研汇报.pptx](SatelliteSimJulia文献调研汇报.pptx) |")
    out.append("")

    out.append("## 全景统计\n\n")
    out.append("### 各板块论文数分布\n\n")
    out.append("| 板块 | 总数 | ★核心(tier1) | ☆相关(tier2) | ○借鉴(tier3) |")
    out.append("|------|------|--------------|--------------|--------------|")
    for sm in secs_meta:
        out.append(f"| {sm['id']} {sm['name']} | {sm['total']} | "
                   f"{sm['tier1']} | {sm['tier2']} | {sm['tier3']} |")
    total_all = sum(s["total"] for s in secs_meta)
    out.append(f"| **合计(含跨板块重复)** | **{total_all}** | "
               f"**{sum(s['tier1'] for s in secs_meta)}** | "
               f"**{sum(s['tier2'] for s in secs_meta)}** | "
               f"**{sum(s['tier3'] for s in secs_meta)}** |")
    out.append("")

    out.append("### 数据源分布(全库)\n\n")
    out.append("| 来源 | 论文数 |")
    out.append("|------|--------|")
    for src, cnt in meta["source_distribution"].items():
        out.append(f"| {fmt_source(src)} | {cnt:,} |")
    out.append("")

    out.append("### 年份分布(全库 Top 15)\n\n")
    out.append("| 年份 | 论文数 |")
    out.append("|------|--------|")
    yd = meta["year_distribution"]
    for i, (y, c) in enumerate(yd.items()):
        if i >= 15:
            break
        out.append(f"| {y} | {c:,} |")
    out.append("")

    out.append("## 相关性等级说明\n\n")
    out.append("| 等级 | 标记 | 含义 |")
    out.append("|------|------|------|")
    out.append("| tier1 | ★核心 | 标题强关键词命中,与本板块主题直接相关 |")
    out.append("| tier2 | ☆相关 | 分类标签+卫星上下文命中,主题相关 |")
    out.append("| tier3 | ○借鉴 | 相邻领域,可借鉴方法/思路(限2021年至今) |")
    out.append("")
    out.append("> 注:tier2/tier3 论文为聚焦时效性,仅保留 2021 年及以后的成果;"
              "tier1 核心论文全量保留。\n\n")

    out.append("## 项目背景\n\n")
    out.append("SatelliteSimJulia 是 **LEO 卫星星座仿真 + 可微优化 + AI 适配** 的端到端流水线,"
              "从 Walker 星座生成 → 轨道传播 → ISL/GSL 链路评估 → 拓扑/路由 → 流量/容量 → 指标,"
              "全链路用裸 `Array{Float64,3}` 衔接、用多重分派扩展,并可微分以做梯度优化。"
              "上方叠 AI 适配层,把自然语言翻译成仿真工具调用。\n\n")
    out.append("本综述按项目架构的 10 个技术层级组织文献,每个板块对应 `src/` 下的模块,"
              "便于开发参考与研究空白识别。\n")

    return "\n".join(out)


def gen_section_doc(sid, items, sec_meta):
    """单个板块 .md"""
    info = SECTIONS_META[sid]
    out = []
    out.append(f"# 板块 {sid}:{info['name']}\n")
    out.append(f"> 对应模块:{info['module']} | "
               f"论文数:**{len(items)}** "
               f"(★核心 {sum(1 for x in items if x['tier']=='tier1')} / "
               f"☆相关 {sum(1 for x in items if x['tier']=='tier2')} / "
               f"○借鉴 {sum(1 for x in items if x['tier']=='tier3')})\n\n")

    out.append("## 1. 定位与核心问题\n\n")
    out.append(info["problem"] + "\n\n")

    out.append("### 关键指标\n\n")
    for m in info["metrics"]:
        out.append(f"- {m}")
    out.append("")

    out.append("## 2. 对标基准(可作验证参考)\n\n")
    out.append("| 来源 | 基准数值 |")
    out.append("|------|----------|")
    for name, val in info["benchmarks"]:
        out.append(f"| {name} | {val} |")
    out.append("")

    out.append("## 3. 文献分类汇总\n\n")
    summary_tbl, groups = render_subtopic_summary(items, info["subtopics"])
    out.append(summary_tbl)
    out.append("")

    out.append("## 4. 论文清单(全量)\n\n")
    out.append(f"共 **{len(items)}** 篇,按子主题分组、组内按相关性+年份排序。\n\n")
    # 按子主题分组输出
    ordered_names = [name for name, _ in info["subtopics"]]
    for name in ordered_names:
        sub_items = groups.get(name, [])
        if not sub_items:
            continue
        out.append(f"### {name}({len(sub_items)} 篇)\n\n")
        out.append(render_paper_table(sub_items))
        out.append("")

    out.append("## 5. 关键发现与对标基准\n\n")
    out.append("基于上述文献,本板块的核心发现:\n\n")
    # 简明发现(基于 subtopic 分布)
    top_grp = max(groups.items(), key=lambda x: len(x[1]))[0] if groups else "-"
    out.append(f"- **最集中的子主题**:{top_grp},反映该方向是研究热点。")
    recent = sum(1 for x in items if x["year"] and x["year"].isdigit() and int(x["year"]) >= 2024)
    out.append(f"- **近期活跃度**:2024 年至今共 {recent} 篇,占 {recent/len(items)*100:.0f}%。")
    sources = Counter(fmt_source(x["source"]) for x in items)
    top_src = sources.most_common(1)[0] if sources else ("-", 0)
    out.append(f"- **主要来源**:{top_src[0]}({top_src[1]} 篇)。")
    out.append("")

    out.append("## 6. 研究空白与本项目切入点\n\n")
    out.append(info["gap"] + "\n")

    return "\n".join(out)


def gen_summary_doc(data):
    """11_分类汇总与研究机会.md"""
    secs_meta = data["sections_meta"]
    secs = data["sections"]
    out = []
    out.append("# 分类汇总与研究机会\n\n")
    out.append("> 跨板块视角:研究热点矩阵、空白识别、对 SatelliteSimJulia 的路线图启示。\n\n")

    out.append("## 1. 跨板块论文数总览\n\n")
    out.append("| 板块 | 论文数 | 研究热度 | 文献饱和度 |")
    out.append("|------|--------|----------|------------|")
    for sm in secs_meta:
        heat = "🔥🔥🔥" if sm["total"] >= 400 else (
            "🔥🔥" if sm["total"] >= 150 else "🔥")
        sat = "高度饱和" if sm["total"] >= 400 else (
            "较活跃" if sm["total"] >= 150 else "蓝海/新兴")
        out.append(f"| {sm['id']} {sm['name']} | {sm['total']} | {heat} | {sat} |")
    out.append("")

    out.append("## 2. 研究热度与空白矩阵\n\n")
    out.append("```\n")
    out.append("              论文数(研究热度)\n")
    out.append("               高 ──────────────────▶ 低\n")
    sm_dict = {s["id"]: s["total"] for s in secs_meta}
    bars = [("04", "路由算法", sm_dict["04"]), ("02", "ISL链路", sm_dict["02"]),
            ("09", "切换移动", sm_dict["09"]), ("06", "可微优化", sm_dict["06"]),
            ("07", "PINN神经", sm_dict["07"]), ("05", "流量容量", sm_dict["05"]),
            ("01", "轨道传播", sm_dict["01"]), ("10", "TCP传输", sm_dict["10"]),
            ("08", "LLM Agent", sm_dict["08"]), ("03", "拓扑策略", sm_dict["03"])]
    max_cnt = max(c for _, _, c in bars)
    for sid, name, cnt in bars:
        bar_len = max(1, int(cnt / max_cnt * 30))
        tag = "🔥" if cnt >= 400 else ("⚡" if cnt >= 150 else "🌊")
        out.append(f"  {name}({sid}) {'█'*bar_len} {cnt} {tag}\n")
    out.append("```\n\n")

    out.append("**图例**:🔥 成熟红海(>400篇) · ⚡ 活跃方向(150-400) · 🌊 蓝海/新兴(<150)\n\n")

    out.append("## 3. 三大研究空白(本项目核心创新点)\n\n")
    gaps = [
        ("🥇 可微仿真闭环",
         "板块06",
         "可微 J2/SGP4 传播 → 软 ISL/覆盖 loss → Adam 端到端星座优化的完整闭环,"
         "在卫星领域几乎无先例。严格可微论文仅 17 篇。",
         "`src/opt` 的 `optimize_coverage` driver + Enzyme/Zygote",
         "⭐⭐⭐"),
        ("🥈 PINN + 卫星网络",
         "板块07",
         "PINN + 卫星路由(0篇)、PINN + 星上计算(0篇)、PINN + 流量预测(0篇)均空白。"
         "现有 PINN 卫星工作仅限状态估计。",
         "`src/opt` 的 pinn_routing.jl + pinn_model.jl",
         "⭐⭐⭐"),
        ("🥉 LLM 驱动的仿真编排",
         "板块08",
         "LLM + 卫星仿真工具链集成是新交叉点,无成熟编排器。",
         "`src/lab` 的 SimAgent + agent_repl + Intent 翻译",
         "⭐⭐"),
    ]
    out.append("| 排名 | 空白方向 | 板块 | 空白判断 | 本项目对应 | 价值 |")
    out.append("|------|----------|------|----------|------------|------|")
    for name, sec, desc, impl, val in gaps:
        out.append(f"| {name} | {sec} | {desc[:60]}... | {impl} | {val} |")
    out.append("")
    for name, sec, desc, impl, val in gaps:
        out.append(f"### {name}({sec})\n")
        out.append(f"- **空白判断**:{desc}\n")
        out.append(f"- **本项目实现**:{impl}\n")
        out.append(f"- **价值评级**:{val}\n")

    out.append("## 4. 成熟方向(可直接对标/复现)\n\n")
    out.append("| 板块 | 对标标杆 | 关键数值 | 本项目复现路径 |")
    out.append("|------|----------|----------|----------------|")
    mature = [
        ("04 路由算法", "Hypatia/satgenpy", "Paris→Luanda RTT 85-117ms",
         "`src/net` Dijkstra/FW/ECMP/MLB"),
        ("02 ISL链路", "Hypatia +Grid", "4 ISL/星,时延~5ms/跳",
         "`src/link` ISL 物理评估"),
        ("09 切换移动性", "OpenSN", "可见窗口 5-15 min",
         "`src/link`+`src/net` handover policy 多重分派"),
        ("10 TCP传输", "SaTCP/LeoTCP", "Mathis 上界",
         "解析模型 + ns-3 trace 接口"),
        ("01 轨道传播", "SatelliteToolbox", "J2 1天~10km",
         "`src/orbit` TwoBody/J2/SGP4 对比"),
    ]
    for sec, bench, num, path in mature:
        out.append(f"| {sec} | {bench} | {num} | {path} |")
    out.append("")

    out.append("## 5. 推荐研究路线图\n\n")
    out.append("基于文献饱和度与空白识别,推荐分阶段推进:\n\n")
    out.append("```\n")
    out.append("阶段1(短期,对标验证):\n")
    out.append("  ├─ 复现 Hypatia 基准(RTT/跳数/MLU) → 板块04,05\n")
    out.append("  ├─ 传播器精度对比(TwoBody/J2/SGP4) → 板块01\n")
    out.append("  └─ ISL/拓扑评估验证 → 板块02,03\n\n")
    out.append("阶段2(中期,核心创新):\n")
    out.append("  ├─ ★ 可微 J2 + 软覆盖 loss + Adam 闭环 → 板块06(第一篇论文)\n")
    out.append("  ├─ 切换中断度量建模 → 板块09\n")
    out.append("  └─ 流量工程可微化探索 → 板块05\n\n")
    out.append("阶段3(长期,蓝海突破):\n")
    out.append("  ├─ ★★ PINN 路由时延预测器 → 板块07(第二篇论文)\n")
    out.append("  ├─ ★★ PINN + 星上计算/流量预测 → 板块07(第三篇)\n")
    out.append("  └─ LLM 仿真编排器产品化 → 板块08\n")
    out.append("```\n")

    out.append("## 6. 交叉机会\n\n")
    out.append("| 交叉点 | 涉及板块 | 机会描述 |")
    out.append("|--------|----------|----------|")
    out.append("| 可微路由 | 04 × 06 | 梯度直接优化路由策略参数(本项目 pinn_routing) |")
    out.append("| PINN 传播+优化 | 07 × 06 | PINN 替代传播器,天然可微,端到端优化 |")
    out.append("| LLM + 路由 | 08 × 04 | 自然语言驱动路由策略选择 |")
    out.append("| 切换+可微 | 09 × 06 | 可微切换策略优化(中断最小化) |")
    out.append("| 拓扑+流量 | 03 × 05 | 需求感知拓扑 + 流量联合优化 |")
    out.append("")

    return "\n".join(out)


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
def main():
    if not os.path.exists(JSON_IN):
        raise SystemExit(f"JSON 不存在:{JSON_IN},请先运行 build_literature_index.py")

    with open(JSON_IN, "r", encoding="utf-8") as f:
        data = json.load(f)

    secs = data["sections"]
    secs_meta_list = data["sections_meta"]

    # 文件名映射
    fname_map = {
        "01": "01_轨道传播层.md", "02": "02_链路评估层.md",
        "03": "03_拓扑策略层.md", "04": "04_路由算法层.md",
        "05": "05_流量容量时延层.md", "06": "06_可微优化层.md",
        "07": "07_PINN神经传播层.md", "08": "08_AI编排LLM层.md",
        "09": "09_切换移动性层.md", "10": "10_TCP传输层.md",
    }

    # 生成 00 总览
    overview = finalize(gen_overview(data))
    with open(os.path.join(OUT_DIR, "00_总览索引.md"), "w", encoding="utf-8") as f:
        f.write(overview)
    print(f"✓ 00_总览索引.md")

    # 生成 10 个板块
    for sm in secs_meta_list:
        sid = sm["id"]
        items = secs.get(sid, [])
        if not items:
            print(f"⚠ 板块{sid} 无论文,跳过")
            continue
        sec_meta_obj = next((s for s in secs_meta_list if s["id"] == sid), sm)
        doc = finalize(gen_section_doc(sid, items, sec_meta_obj))
        out_path = os.path.join(OUT_DIR, fname_map[sid])
        with open(out_path, "w", encoding="utf-8") as f:
            f.write(doc)
        print(f"✓ {fname_map[sid]}({len(items)} 篇)")

    # 生成 11 汇总
    summary = finalize(gen_summary_doc(data))
    with open(os.path.join(OUT_DIR, "11_分类汇总与研究机会.md"), "w", encoding="utf-8") as f:
        f.write(summary)
    print(f"✓ 11_分类汇总与研究机会.md")

    print(f"\n全部 Markdown 文档已生成至:{OUT_DIR}")


if __name__ == "__main__":
    main()
