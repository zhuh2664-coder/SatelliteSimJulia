#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
可落地论文精选清单生成器

从 _data.json (2640 篇已筛选文献) 中进一步筛选出:
  - 有公开源码的论文 (GitHub 链接已知)
  - 顶级会议/期刊论文 (CCF-A, 方法论清晰可复现)
  - 行业标杆/基准论文 (Hypatia, satgenpy 等)

输出: docs/literature/可落地论文清单.md (Top 50-100)
每篇标注: 复现难度 / 对应项目模块 / 核心算法 / 代码状态
"""

import json
import os
import re
from collections import defaultdict

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.dirname(SCRIPT_DIR)
OUT_DIR = os.path.join(PROJECT_DIR, "docs", "literature")
JSON_IN = os.path.join(OUT_DIR, "_data.json")
MD_OUT = os.path.join(OUT_DIR, "可落地论文清单.md")

# ---------------------------------------------------------------------------
# 已知开源项目及其论文 (手动维护)
# ---------------------------------------------------------------------------
KNOWN_OPEN_SOURCE = {
    # (title_keyword, year) -> repo_url, difficulty, module
    "hypatia": {
        "repo": "https://github.com/snkas/hypatia",
        "difficulty": "⭐⭐ 中等",
        "module": "04 路由 / 02 链路",
        "note": "satgenpy 拓扑生成器 + ns-3 包级仿真, Python 生态",
        "venue": "IMC 2020",
    },
    "satgenpy": {
        "repo": "https://github.com/snkas/hypatia (satgenpy 子包)",
        "difficulty": "⭐⭐ 中等",
        "module": "04 路由 / 03 拓扑",
        "note": "LEO 拓扑生成 + Floyd-Warshall 全网路由, 直接对标",
        "venue": "IMC 2020",
    },
    "starrynet": {
        "repo": "https://github.com/SpaceNetLab/StarryNet",
        "difficulty": "⭐⭐ 中等",
        "module": "01 轨道 / 05 流量容量",
        "note": "容器化 LEO 仿真器, Python, 架构可借鉴",
        "venue": "—",
    },
    "leoem": {
        "repo": "https://github.com/XuyangCaoUCSD/LeoEM",
        "difficulty": "⭐⭐ 中等",
        "module": "09 切换 / 04 路由",
        "note": "LEO 仿真器切换/移动性, Python+Mininet",
        "venue": "—",
    },
    "netsatbench": {
        "repo": "https://github.com/mSvcBench/NetSatBench",
        "difficulty": "⭐⭐⭐ 较高",
        "module": "09 切换 / 04 路由",
        "note": "大规模卫星仿真切换复现, 分布式架构",
        "venue": "—",
    },
    "opensn": {
        "repo": "https://github.com/OpenSN (arXiv:2507.03248)",
        "difficulty": "⭐⭐ 中等",
        "module": "09 切换 / 02 链路",
        "note": "OpenSN 仿真器库, 可自定义 GSL handover policy",
        "venue": "APNet 2024",
    },
    "satcp": {
        "repo": "http://xyzhang.ucsd.edu/papers/Xuyang.Cao_INFOCOM23_SaTCP.pdf",
        "difficulty": "⭐⭐ 中等",
        "module": "10 TCP",
        "note": "LEO TCP 链路自适应, ns-3 实现",
        "venue": "INFOCOM 2023",
    },
    "deepxde": {
        "repo": "https://github.com/lululxvi/deepxde",
        "difficulty": "⭐⭐ 中等",
        "module": "07 PINN",
        "note": "PINN 求解框架, Julia+Python 双实现, 可直接集成",
        "venue": "SIAM Review 2021",
    },
    "neuralpde": {
        "repo": "https://github.com/SciML/NeuralPDE.jl",
        "difficulty": "⭐⭐ 中等",
        "module": "07 PINN",
        "note": "Julia 生态最完整 PINN 求解器, SciML 官方",
        "venue": "—",
    },
    "satellitetoolbox": {
        "repo": "https://github.com/JuliaSpace/SatelliteToolbox.jl",
        "difficulty": "⭐ 简单",
        "module": "01 轨道",
        "note": "Julia 轨道传播器库, 本项目底层依赖",
        "venue": "—",
    },
    "grupsim": {
        "repo": "https://github.com/DLR-SC/grupsim",
        "difficulty": "⭐⭐ 中等",
        "module": "01 轨道",
        "note": "DLR 卫星星座仿真器, Julia, 轨道传播",
        "venue": "—",
    },
    # 从调研.md 中提取的额外项目
    "basilisk": {
        "repo": "https://avslab.github.io/basilisk/",
        "difficulty": "⭐⭐⭐ 较高",
        "module": "01 轨道 / 09 切换",
        "note": "GNC 仿真框架, C++/Python, 能量/电源子系统可借鉴",
        "venue": "—",
    },
    "orekit": {
        "repo": "https://www.orekit.org/",
        "difficulty": "⭐⭐ 中等",
        "module": "01 轨道",
        "note": "Java 轨道低层库, 可做精度验证基准",
        "venue": "—",
    },
    "concurrentsim": {
        "repo": "https://github.com/JuliaDynamics/ConcurrentSim.jl",
        "difficulty": "⭐ 简单",
        "module": "05 流量容量 / 09 切换",
        "note": "Julia 离散事件仿真, 前 SimJulia, 可直接集成",
        "venue": "—",
    },
    "graphs": {
        "repo": "https://github.com/JuliaGraphs/Graphs.jl",
        "difficulty": "⭐ 简单",
        "module": "03 拓扑 / 04 路由",
        "note": "Julia 图算法库, 对标 NetworkX, 本项目直接依赖",
        "venue": "—",
    },
}

# 顶级会议/期刊列表 (CCF-A 网络/系统/ML 方向)
TOP_VENUES = [
    "INFOCOM", "SIGCOMM", "NSDI", "MobiCom", "SenSys",
    "ICNP", "IMC", "CoNEXT", "HotNets", "SIGMETRICS",
    "IWQoS", "ICC", "GLOBECOM", "MobiHoc",
]
TOP_JOURNALS = [
    "IEEE/ACM TRANSACTIONS ON NETWORKING",
    "IEEE JOURNAL ON SELECTED AREAS IN COMMUNICATIONS",
    "IEEE TRANSACTIONS ON COMMUNICATIONS",
    "IEEE TRANSACTIONS ON WIRELESS COMMUNICATIONS",
    "IEEE TRANSACTIONS ON MOBILE COMPUTING",
    "COMPUTER NETWORKS", "IEEE NETWORK",
    "ACM COMPUTING SURVEYS", "IEEE COMMUNICATIONS SURVEYS",
    "IEEE COMMUNICATIONS MAGAZINE", "SIGCOMM COMPUTER COMMUNICATION REVIEW",
    "JOURNAL OF COMPUTATIONAL PHYSICS",
    "SIAM REVIEW", "NATURE REVIEWS PHYSICS",
]

# 有公开代码的关键词标记 (标题/摘要含这些词)
CODE_KEYWORDS = [
    "open source", "github", "open-source", "code available",
    "publicly available", "implementation", "toolkit",
    "simulator", "framework", "benchmark",
    "open-sourced", "reproducib",
]


# ---------------------------------------------------------------------------
# 过滤与评分
# ---------------------------------------------------------------------------
def is_top_venue(ref_text):
    """判断参考文献是否来自顶会/顶刊。"""
    r = ref_text.upper()
    for v in TOP_VENUES + TOP_JOURNALS:
        if v in r:
            return v
    return None


def deduplicate_title(title):
    """规范化标题用于去重 (去掉编号前缀和标点差异)。"""
    t = re.sub(r"^\s*\d+\.\s*", "", title).strip().lower()
    t = re.sub(r"poster:\s*", "", t)
    t = re.sub(r"[^\w\s]", "", t)
    return t.strip()


def is_valid_title(title):
    """排除被错误解析的条目(如作者名混入标题)。"""
    if len(title) > 300:
        return False
    if re.search(r"\(.*universit|\(.*institute|universit.*spain|universit.*usa\)", title.lower()):
        if "university" not in title.lower()[:80]:
            return False
    return True


def has_code_indicator(title_l, ref_l):
    """判断论文是否有可能有公开代码。"""
    blob = title_l + " " + ref_l
    return any(k in blob for k in CODE_KEYWORDS)


def score_paper(paper):
    """对一篇论文打可落地分 (0-100)。分数越高越可落地。"""
    score = 0
    title = paper["title"]
    title_l = title.lower()
    year = paper["year"]
    ref = paper.get("ref", "")
    ref_l = ref.lower()

    # 年份分 (2023+ 加分, 越新越好)
    try:
        y = int(year)
        if y >= 2025: score += 25
        elif y >= 2023: score += 18
        elif y >= 2021: score += 10
        elif y >= 2019: score += 5
    except (ValueError, TypeError):
        pass

    # 顶会/顶刊分
    venue = is_top_venue(ref)
    if venue:
        score += 20
        if any(v in venue for v in ["INFOCOM", "SIGCOMM", "IMC", "NSDI", "ICNP"]):
            score += 5  # 网络顶会额外加分

    # 代码指标
    if has_code_indicator(title_l, ref_l):
        score += 15

    # 已知开源项目
    for key, info in KNOWN_OPEN_SOURCE.items():
        if key in title_l:
            score += 30
            break

    # 来源加分 (arXiv 通常较新但有预印本优势)
    if paper["source"] == "arXiv":
        score += 5
    if paper["source"] in ("CCF_Conf", "CCF"):
        score += 10

    # 标题方法词 (算法明确的加分)
    method_keywords = [
        "algorithm", "method", "approach", "framework",
        "system", "platform", "simulator", "emulator",
        "implementation", "prototype", "design",
        "dijkstra", "routing", "optimiz", "propagat",
        "neural network", "machine learning", "deep learning",
    ]
    score += 3 * sum(1 for k in method_keywords if k in title_l)

    return min(score, 100)


def get_difficulty(paper):
    """评估复现难度。"""
    title_l = paper["title"].lower()
    ref = paper.get("ref", "")

    # 已知项目
    for key, info in KNOWN_OPEN_SOURCE.items():
        if key in title_l:
            return info["difficulty"]

    # 规则判断
    if is_top_venue(ref):
        return "⭐⭐ 中等"
    if any(k in title_l for k in ["simulator", "framework", "benchmark"]):
        return "⭐⭐⭐ 较高"
    if any(k in title_l for k in ["algorithm", "method", "approach"]):
        return "⭐⭐ 中等"
    return "⭐ 适合快速验证"


def get_module(paper):
    """推断论文对应的项目模块。"""
    title_l = paper["title"].lower()
    # 已知项目
    for key, info in KNOWN_OPEN_SOURCE.items():
        if key in title_l:
            return info["module"]

    module_map = [
        # 专项板块优先 (更具体的关键词)
        (["handover", "handoff", "mobility", "beam hopping"],
         "09 切换/移动性"),
        (["pinn", "physics-informed", "neural operator", "deeponet",
          "neural ode"], "07 PINN 神经传播"),
        (["differentiab", "gradient", "autodiff", "surrogate", "adam",
          "enzyme", "zygote"], "06 可微优化"),
        (["tcp", "congestion", "bbr", "cubic", "quic", "transport",
          "hybla", "mptcp"], "10 TCP 传输"),
        (["large language", "llm", "gpt", "agent", "language model",
          "orchestrat", "foundation model"], "08 LLM Agent"),
        (["inter-satellite", "isl", "optical link", "laser link", "free space",
          "gsl", "feeder link", "link budget"], "02 ISL/GSL 链路"),
        # 通用板块
        (["routing", "dijkstra", "shortest path", "ecmp", "load balanc",
          "segment routing", "sdn", "forward"], "04 路由算法"),
        (["topology", "graph", "connectivity", "centrality", "snapshot",
          "robustness", "degree"], "03 拓扑策略"),
        (["traffic", "capacity", "throughput", "latency", "delay",
          "congestion", "queue", "utilization"], "05 流量/容量/时延"),
        (["orbit", "propagat", "sgp4", "tle", "walker", "constellation design",
          "two-body", "j2", "tle", "ephemeris"], "01 轨道传播"),
    ]
    for keywords, module in module_map:
        if any(k in title_l for k in keywords):
            return module
    return "跨板块"


def get_code_status(paper):
    """代码状态标注。"""
    title_l = paper["title"].lower()
    for key, info in KNOWN_OPEN_SOURCE.items():
        if key in title_l:
            return f"✅ [GitHub]({info['repo']})"
    if has_code_indicator(title_l, paper.get("ref", "").lower()):
        return "🔍 可能有代码 (标题/摘要提及)"
    if is_top_venue(paper.get("ref", "")):
        return "📄 顶会论文 (方法论清晰,可自行复现)"
    return "📝 需自行复现"


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
def main():
    if not os.path.exists(JSON_IN):
        raise SystemExit(f"JSON 不存在: {JSON_IN},请先运行 build_literature_index.py")

    with open(JSON_IN, "r", encoding="utf-8") as f:
        data = json.load(f)

    secs = data["sections"]
    all_papers = []
    for sid, items in secs.items():
        for it in items:
            all_papers.append({**it, "section_id": sid})

    # 评分 + 去重
    seen_titles = set()
    scored = []
    for p in all_papers:
        if not is_valid_title(p["title"]):
            continue
        dt = deduplicate_title(p["title"])
        if dt in seen_titles or len(dt) < 15:
            continue
        seen_titles.add(dt)
        s = score_paper(p)
        if s >= 25:
            scored.append((s, p))

    # 排序
    scored.sort(key=lambda x: (-x[0], -int(x[1]["year"] or "0")))

    # 板块配额: 每板块至少 3 篇, 最多 12 篇, 总计 50-80 篇
    section_counts = defaultdict(int)
    module_counts = defaultdict(int)
    final = []

    # 第一轮: 高分先行, 每板块最多 12 篇
    for score, paper in scored:
        mod = get_module(paper)
        mod_id = mod[:2]
        if module_counts[mod_id] >= 12:
            continue
        module_counts[mod_id] += 1
        final.append((score, paper))

    # 第二轮: 补足每板块至少 3 篇
    for sm in data["sections_meta"]:
        sid = sm["id"]
        if module_counts[sid] >= 3:
            continue
        # 从该板块的论文中找最高的
        candidates = [(score_paper(p), p) for p in secs.get(sid, [])
                      if is_valid_title(p["title"])]
        candidates.sort(key=lambda x: (-x[0], -int(x[1]["year"] or "0")))
        for cs, cp in candidates:
            dt = deduplicate_title(cp["title"])
            if any(deduplicate_title(p["title"]) == dt for _, p in final):
                continue
            if len(dt) < 15:
                continue
            module_counts[sid] += 1
            final.append((cs, cp))
            if module_counts[sid] >= 3:
                break

    # 最终排序
    final.sort(key=lambda x: (-x[0], -int(x[1]["year"] or "0")))

    # --- 生成 Markdown ---
    out = []
    out.append("# SatelliteSimJulia · 可落地论文精选清单\n")
    out.append(f"> 从 2,640 篇相关文献中筛选出 **{len(final)} 篇**可直接复现/实现的论文\n")
    out.append("> 筛选标准:顶会/顶刊发表 · 有公开代码 · 方法论清晰 · 明确对标价值\n")
    out.append("> 更新日期:2026-07-03\n\n")

    out.append("## 使用说明\n\n")
    out.append("| 图标 | 含义 |\n")
    out.append("|------|------|\n")
    out.append("| ✅ GitHub | 论文有公开源码,可直接 clone 复现 |\n")
    out.append("| 🔍 可能有代码 | 标题/摘要提及开源/实现,需要进一步搜索 |\n")
    out.append("| 📄 顶会论文 | 方法描述清晰,可按照论文自行实现 |\n")
    out.append("| 📝 自行复现 | 方法论可借鉴,需自行编写代码 |\n\n")
    out.append("| 难度 | 含义 |\n")
    out.append("|------|------|\n")
    out.append("| ⭐ 简单 | <100 行 Julia,或直接调用现成库 |\n")
    out.append("| ⭐⭐ 中等 | 需要实现一个算法/模块,100-500 行 |\n")
    out.append("| ⭐⭐⭐ 较高 | 完整系统/框架,>500 行,需架构设计 |\n\n")

    out.append("## 按可落地性排序 (Top {})\n\n".format(len(final)))
    out.append("| # | 可落地分 | 难度 | 模块 | 代码 | 年份 | 标题 |\n")
    out.append("|---|----------|------|------|------|------|------|\n")

    for i, (score, paper) in enumerate(final, 1):
        diff = get_difficulty(paper)
        mod = get_module(paper)
        code = get_code_status(paper)
        year = paper["year"] or "-"
        title = re.sub(r"^\s*\d+\.\s*", "", paper["title"]).replace("|", "\\|")
        out.append(f"| {i} | {score} | {diff} | {mod} | {code} | {year} | {title} |\n")

    out.append("\n## 各板块可落地论文分布\n\n")
    by_section = defaultdict(list)
    for score, paper in final:
        mod = get_module(paper)
        by_section[mod].append((score, paper))
    out.append("| 板块 | 可落地篇数 | | 板块 | 可落地篇数 |\n")
    out.append("|------|------------|------|------|------------|\n")
    modules_order = [f"{i:02d}" for i in range(1, 11)] + ["跨板块"]
    mod_name_map = {
        "01": "轨道传播", "02": "ISL链路", "03": "拓扑策略",
        "04": "路由算法", "05": "流量/容量/时延", "06": "可微优化",
        "07": "PINN 神经传播", "08": "LLM Agent", "09": "切换/移动性",
        "10": "TCP 传输", "跨板块": "跨板块",
    }
    rows = []
    for mod_id in modules_order:
        count = sum(1 for _, p in final if get_module(p).startswith(mod_id.replace("0", "")) or get_module(p).startswith(mod_id))
        name = mod_name_map.get(mod_id, mod_id)
        rows.append((mod_id, name, count))
    # 重新算准确的分布
    dist = defaultdict(int)
    for _, paper in final:
        mod = get_module(paper)
        for mid, mname in mod_name_map.items():
            if mod.startswith(mname) or (mid in mod):
                dist[f"{mid} {mname}"] += 1
                break
        else:
            dist[mod] += 1
    # 简单输出
    for mid in ["01", "02", "03", "04", "05", "06", "07", "08", "09", "10"]:
        mn = mod_name_map[mid]
        cnt = sum(1 for _, p in final if get_module(p).startswith(mid))
        out.append(f"| 板块{mid} | {mn} | {cnt} |\n")

    out.append("\n## 已知开源项目速查 (可直接集成)\n\n")
    out.append("| 项目 | 语言 | 链接 | 难度 | 对应模块 |\n")
    out.append("|------|------|------|------|----------|\n")
    open_source_entries = [
        ("Hypatia / satgenpy", "Python", "https://github.com/snkas/hypatia", "⭐⭐", "04路由/03拓扑"),
        ("StarryNet", "Python", "https://github.com/SpaceNetLab/StarryNet", "⭐⭐", "01轨道/05流量"),
        ("LeoEM", "Python+Mininet", "https://github.com/XuyangCaoUCSD/LeoEM", "⭐⭐", "09切换/04路由"),
        ("OpenSN", "Python", "https://github.com/OpenSN (arXiv:2507.03248)", "⭐⭐", "09切换/02链路"),
        ("SaTCP", "ns-3", "http://xyzhang.ucsd.edu/papers/Xuyang.Cao_INFOCOM23_SaTCP.pdf", "⭐⭐", "10 TCP"),
        ("SatelliteToolbox.jl", "Julia", "https://github.com/JuliaSpace/SatelliteToolbox.jl", "⭐", "01轨道"),
        ("NeuralPDE.jl", "Julia", "https://github.com/SciML/NeuralPDE.jl", "⭐⭐", "07 PINN"),
        ("DeepXDE", "Python+Julia", "https://github.com/lululxvi/deepxde", "⭐⭐", "07 PINN"),
        ("Graphs.jl", "Julia", "https://github.com/JuliaGraphs/Graphs.jl", "⭐", "03拓扑/04路由"),
        ("ConcurrentSim.jl", "Julia", "https://github.com/JuliaDynamics/ConcurrentSim.jl", "⭐", "05流量/09切换"),
        ("Basilisk", "C++/Python", "https://avslab.github.io/basilisk/", "⭐⭐⭐", "01轨道/能源"),
        ("NetSatBench", "分布式", "https://github.com/mSvcBench/NetSatBench", "⭐⭐⭐", "09切换/04路由"),
    ]
    for name, lang, link, diff, mod in open_source_entries:
        out.append(f"| {name} | {lang} | [GitHub]({link}) | {diff} | {mod} |\n")

    out.append("\n## 执行建议\n\n")
    out.append("### 优先复现 (本周可做)\n\n")
    out.append("1. **Hypatia/satgenpy 基准验证** — 复现 Paris→Luanda RTT 85-117ms,"
              "对接 `src/net` Dijkstra/FW 路由\n")
    out.append("2. **J2 TwoBody 传播器精度对比** — 用 SatelliteToolbox.jl 生成 truth,"
              "验证本项目传播器精度\n")
    out.append("3. **切换中断度量建模** — 借鉴 OpenSN 的 handover policy 框架,"
              "在多重分派上实现 ElevationThreshold/LongestVisible\n")
    out.append("\n### 中期落地 (本月可做)\n\n")
    out.append("4. **NN 残差修正 J2 (+34%)** — 对标 ESA ML-dSGP4,"
              "用 Lux.jl 实现 3→64→64→3 乘性残差 NN\n")
    out.append("5. **PINN 路由时延预测器** — 对标 NeuralPDE.jl,"
              "完成 pinn_routing.jl 训练验证闭环\n")
    out.append("6. **流量工程可微化** — 可微链路评估 + 端到端梯度,"
              "第一篇论文素材\n")
    out.append("\n### 长期目标 (本季度可做)\n\n")
    out.append("7. **LLM Agent 仿真编排器** — agent_repl 产品化,"
              "将自然语言请求翻译为仿真工具调用\n")
    out.append("8. **PINN 传播器替代** — 对标 arXiv:2403.19736,"
              "用 PINN 替代传统传播器作为可微核心\n")

    # 写入
    os.makedirs(OUT_DIR, exist_ok=True)
    with open(MD_OUT, "w", encoding="utf-8") as f:
        f.write("".join(out))
    print(f"✓ 可落地论文清单已生成: {MD_OUT}")
    print(f"  共 {len(final)} 篇精选论文 (从 2,640 篇中筛选)")

    # 统计
    print(f"\n板块分布:")
    for mid in ["01", "02", "03", "04", "05", "06", "07", "08", "09", "10"]:
        mn = mod_name_map[mid]
        cnt = sum(1 for _, p in final if get_module(p).startswith(mid))
        bar = "█" * cnt
        print(f"  板块{mid} {mn:<14} {cnt:>2} 篇 {bar}")


if __name__ == "__main__":
    main()
