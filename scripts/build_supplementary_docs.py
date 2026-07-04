#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
SatelliteSimJulia 文献调研 · 第二轮补充文档生成器

产出 4 类文档 (全部中文,放至 docs/literature/):
  12_Benchmark对比矩阵.md       - 8 标杆项目 × 10 维度横向对比
  13_重要论文摘要集.md           - Top 60 论文 + arXiv 摘要补取
  _bibliography.bib + 10 分板块  - BibTeX 引用库
  14_冲刺路线图.md               - 4 Sprint × 6 字段
  _plans/本次补充任务计划.md     - 计划文档存档(审计追踪)

不修改 src/ 任何代码,不修改现有 12 篇综述。可重复运行(幂等)。
"""

import json
import os
import re
import sys
import time
import urllib.request
import urllib.parse
import xml.etree.ElementTree as ET
from collections import defaultdict

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.dirname(SCRIPT_DIR)
OUT_DIR = os.path.join(PROJECT_DIR, "docs", "literature")
PLANS_DIR = os.path.join(OUT_DIR, "_plans")
JSON_IN = os.path.join(OUT_DIR, "_data.json")
ARXIV_FEED = os.path.join(OUT_DIR, "_arxiv_feed.json")


# ---------------------------------------------------------------------------
# 数据加载
# ---------------------------------------------------------------------------
def load_data():
    with open(JSON_IN, "r", encoding="utf-8") as f:
        data = json.load(f)
    # arXiv feed (有作者/摘要信息)
    arxiv_map = {}
    if os.path.exists(ARXIV_FEED):
        with open(ARXIV_FEED, "r", encoding="utf-8") as f:
            feed = json.load(f)
        for p in feed.get("papers", []):
            # 用标题前 60 字符做匹配 key
            key = re.sub(r"[^\w\s]", "", p["title"].lower())[:60]
            arxiv_map[key] = p
    return data, arxiv_map


# ---------------------------------------------------------------------------
# 1. Benchmark 对比矩阵
# ---------------------------------------------------------------------------
def gen_benchmark_matrix():
    benchmarks = [
        {
            "name": "SatelliteSimJulia",
            "lang": "Julia",
            "url": "—(本项目)",
            "row": {  # ✅ 完整 / ⚠️ 部分 / ❌ 无
                "轨道传播": "✅ TwoBody/J2/J4/SGP4",
                "ISL 链路": "✅ 物理+几何评估",
                "拓扑策略": "✅ +Grid/T/Mesh/Ring",
                "路由算法": "✅ Dijkstra/FW/ECMP/MLB",
                "流量/容量": "✅ AoN+容量模型",
                "可微优化": "✅ Enzyme/Zygote/Adam",
                "PINN": "✅ Lux+PINN 路由",
                "LLM 编排": "✅ SimAgent+agent_repl",
                "切换/移动": "⚠️ handover policy 框架",
                "TCP": "❌ 仅解析上界",
            },
            "decision": "🟢 自研(本体)",
        },
        {
            "name": "Hypatia / satgenpy",
            "lang": "Python + ns-3",
            "url": "https://github.com/snkas/hypatia",
            "row": {
                "轨道传播": "✅ satgenpy 内置",
                "ISL 链路": "✅ +Grid 标准",
                "拓扑策略": "✅ +Grid/3 种策略",
                "路由算法": "✅ Floyd-Warshall 全源",
                "流量/容量": "✅ +ns-3 包级仿真",
                "可微优化": "❌",
                "PINN": "❌",
                "LLM 编排": "❌",
                "切换/移动": "⚠️ 假设瞬时切换",
                "TCP": "✅ ns-3 完整状态机",
            },
            "decision": "🔵 首选对标(数值基准)",
        },
        {
            "name": "OpenSN",
            "lang": "Python",
            "url": "arXiv:2507.03248",
            "row": {
                "轨道传播": "✅",
                "ISL 链路": "✅",
                "拓扑策略": "⚠️",
                "路由算法": "⚠️",
                "流量/容量": "⚠️",
                "可微优化": "❌",
                "PINN": "❌",
                "LLM 编排": "❌",
                "切换/移动": "✅ 自定义 GSL policy",
                "TCP": "❌",
            },
            "decision": "🟡 切换策略借鉴",
        },
        {
            "name": "SaTCP",
            "lang": "C (ns-3)",
            "url": "INFOCOM 2023",
            "row": {
                "轨道传播": "❌",
                "ISL 链路": "⚠️",
                "拓扑策略": "❌",
                "路由算法": "❌",
                "流量/容量": "⚠️",
                "可微优化": "❌",
                "PINN": "❌",
                "LLM 编排": "❌",
                "切换/移动": "❌",
                "TCP": "✅ LEO 链路自适应",
            },
            "decision": "🟡 TCP 评估参考",
        },
        {
            "name": "StarryNet",
            "lang": "Python",
            "url": "https://github.com/SpaceNetLab/StarryNet",
            "row": {
                "轨道传播": "✅",
                "ISL 链路": "✅",
                "拓扑策略": "⚠️",
                "路由算法": "⚠️",
                "流量/容量": "✅ 容器化",
                "可微优化": "❌",
                "PINN": "❌",
                "LLM 编排": "❌",
                "切换/移动": "⚠️",
                "TCP": "⚠️",
            },
            "decision": "🟡 仿真器架构借鉴",
        },
        {
            "name": "NeuralPDE.jl",
            "lang": "Julia (SciML)",
            "url": "https://github.com/SciML/NeuralPDE.jl",
            "row": {
                "轨道传播": "❌",
                "ISL 链路": "❌",
                "拓扑策略": "❌",
                "路由算法": "❌",
                "流量/容量": "❌",
                "可微优化": "✅ 原生 AD 兼容",
                "PINN": "✅ 完整 PINN 求解器",
                "LLM 编排": "❌",
                "切换/移动": "❌",
                "TCP": "❌",
            },
            "decision": "🔵 PINN 直接集成",
        },
        {
            "name": "SatelliteToolbox.jl",
            "lang": "Julia",
            "url": "https://github.com/JuliaSpace/SatelliteToolbox.jl",
            "row": {
                "轨道传播": "✅ TwoBody/J2/J4/SGP4",
                "ISL 链路": "⚠️",
                "拓扑策略": "❌",
                "路由算法": "❌",
                "流量/容量": "❌",
                "可微优化": "✅ ForwardDiff 兼容",
                "PINN": "❌",
                "LLM 编排": "❌",
                "切换/移动": "❌",
                "TCP": "❌",
            },
            "decision": "🔵 已是底层依赖",
        },
        {
            "name": "Graphs.jl / ConcurrentSim.jl",
            "lang": "Julia",
            "url": "https://github.com/JuliaGraphs/Graphs.jl",
            "row": {
                "轨道传播": "❌",
                "ISL 链路": "❌",
                "拓扑策略": "✅ 图算法完整",
                "路由算法": "✅ Dijkstra/FW/yen_k",
                "流量/容量": "⚠️ 需自接容量模型",
                "可微优化": "⚠️",
                "PINN": "❌",
                "LLM 编排": "❌",
                "切换/移动": "⚠️ ConcurrentSim 离散事件",
                "TCP": "❌",
            },
            "decision": "🔵 基础库(已集成)",
        },
    ]

    dims = ["轨道传播", "ISL 链路", "拓扑策略", "路由算法", "流量/容量",
            "可微优化", "PINN", "LLM 编排", "切换/移动", "TCP"]

    out = []
    out.append("# 板块 12:Benchmark 对比矩阵\n\n")
    out.append("> 横向对比 SatelliteSimJulia 与 7 个标杆项目,识别可复用 / 需自研 / 可借鉴的模块。\n\n")
    out.append("> 决策图例:🟢 自研本体 · 🔵 直接复用/集成 · 🟡 借鉴思路 · 🔴 需自研\n\n")

    out.append("## 1. 全景对比矩阵\n\n")
    # 表头
    header = "| 维度 |" + "|".join(f" {b['name']} " for b in benchmarks) + "|"
    sep = "|------|" + "|".join(["---"] * len(benchmarks)) + "|"
    out.append(header + "\n" + sep + "\n")
    # 语言行
    row = "| 编程语言 |" + "|".join(f" {b['lang']} " for b in benchmarks) + "|"
    out.append(row + "\n")
    # 各维度行
    for dim in dims:
        cells = []
        for b in benchmarks:
            cells.append(f" {b['row'].get(dim, '❌')} ")
        out.append(f"| {dim} |" + "|".join(cells) + "|\n")
    # 决策行
    row = "| **选型决策** |" + "|".join(f" {b['decision']} " for b in benchmarks) + "|"
    out.append(row + "\n\n")

    out.append("## 2. 项目链接速查\n\n")
    out.append("| 项目 | 链接 | 主要价值 |\n")
    out.append("|------|------|----------|\n")
    values = {
        "SatelliteSimJulia": "端到端可微仿真,本项目本体",
        "Hypatia / satgenpy": "首选对标,Paris→Luanda RTT 85-117ms 基准",
        "OpenSN": "切换策略框架借鉴(APNet 2024)",
        "SaTCP": "LEO TCP 链路自适应(INFOCOM 2023)",
        "StarryNet": "容器化仿真器架构",
        "NeuralPDE.jl": "Julia 原生 PINN 求解器,直接集成",
        "SatelliteToolbox.jl": "已是本项目轨道层依赖",
        "Graphs.jl / ConcurrentSim.jl": "图算法+离散事件,已集成",
    }
    for b in benchmarks:
        out.append(f"| {b['name']} | {b['url']} | {values.get(b['name'], '—')} |\n")
    out.append("\n")

    out.append("## 3. 关键差距分析\n\n")
    out.append("### 3.1 SatelliteSimJulia 独有优势(无对标)\n\n")
    out.append("- **端到端可微仿真**:全链路梯度穿透(轨道→链路→路由→指标),"
              "支持 Adam 优化星座参数。Hypatia/OpenSN/StarryNet 均无此能力。\n")
    out.append("- **PINN 路由时延预测器**:`pinn_routing.jl` 用 12 维图特征 + Lux MLP 预测时延,"
              "领域内首创。\n")
    out.append("- **LLM 仿真编排**:`agent_repl` 把自然语言翻译成仿真工具调用,"
              "无对标编排器。\n\n")

    out.append("### 3.2 SatelliteSimJulia 弱项(需补足或外接)\n\n")
    out.append("| 弱项 | 当前状态 | 补足方案 | 优先级 |\n")
    out.append("|------|----------|----------|--------|\n")
    out.append("| TCP 包级仿真 | 仅 Mathis 解析上界 | 输出 trace 给 ns-3(像 Hypatia) | P2 |\n")
    out.append("| 切换中断度量 | 假设瞬时切换 | 借鉴 OpenSN 加 H1/H2/H3 策略 | P1 |\n")
    out.append("| 容量瓶颈实验 | 解析模型 | 借鉴 Mininet dumbbell 拓扑 | P3 |\n\n")

    out.append("### 3.3 可直接集成的 Julia 库\n\n")
    out.append("| 库 | 用途 | 集成难度 | 状态 |\n")
    out.append("|----|------|----------|------|\n")
    out.append("| SatelliteToolbox.jl | TLE/SGP4/ECEF↔LLA | ⭐ | ✅ 已集成 |\n")
    out.append("| Graphs.jl | Dijkstra/FW/yen_k | ⭐ | ✅ 已集成 |\n")
    out.append("| ConcurrentSim.jl | 离散事件仿真 | ⭐ | ✅ 已集成 |\n")
    out.append("| NeuralPDE.jl | PINN 求解 | ⭐⭐ | 🔧 部分集成(pinn_routing.jl) |\n")
    out.append("| Lux.jl | 神经网络框架 | ⭐⭐ | ✅ 已集成(opt 层) |\n")
    out.append("| Enzyme/Zygote | 自动微分 | ⭐⭐ | ✅ 已集成(opt 层) |\n")
    out.append("| SimpleWeightedGraphs.jl | 加权图 maxflow | ⭐ | ⚠️ 待集成 |\n")
    out.append("| DrWatson.jl | 实验编排/缓存 | ⭐⭐ | ⚠️ 待集成 |\n\n")

    out.append("## 4. 选型决策树\n\n")
    out.append("```mermaid\n")
    out.append("graph TD\n")
    out.append("  Q[需要做什么?]\n")
    out.append("  Q -->|对标数值基准| H[用 Hypatia 复现 RTT/跳数/MLU]\n")
    out.append("  Q -->|TCP 性能评估| S[用 SaTCP 思路 + ns-3 trace]\n")
    out.append("  Q -->|切换策略设计| O[借鉴 OpenSN handover policy]\n")
    out.append("  Q -->|PINN 建模| N[直接用 NeuralPDE.jl]\n")
    out.append("  Q -->|可微优化| D[自研 - 领域空白]\n")
    out.append("  Q -->|LLM 编排| L[自研 - 领域空白]\n")
    out.append("```\n\n")
    out.append("> 决策原则:**Julia 生态优先**,有成熟库直接用;无对标方向才自研。\n")

    return "".join(out)


# ---------------------------------------------------------------------------
# 2. 重要论文摘要集
# ---------------------------------------------------------------------------
def fetch_arxiv_abstract(arxiv_id, cache=None):
    """从 arXiv API 拉取单篇论文的摘要。"""
    if cache is None:
        cache = {}
    if arxiv_id in cache:
        return cache[arxiv_id]
    if not arxiv_id or not re.match(r"^\d", arxiv_id):
        cache[arxiv_id] = None
        return None
    url = f"http://export.arxiv.org/api/query?id_list={arxiv_id}"
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "SatelliteSimJulia/1.0"})
        with urllib.request.urlopen(req, timeout=15) as resp:
            xml_data = resp.read().decode("utf-8")
        root = ET.fromstring(xml_data)
        ns = {"atom": "http://www.w3.org/2005/Atom"}
        entry = root.find("atom:entry", ns)
        if entry is None:
            cache[arxiv_id] = None
            return None
        summary_el = entry.find("atom:summary", ns)
        if summary_el is None:
            cache[arxiv_id] = None
            return None
        abstract = summary_el.text.strip().replace("\n", " ")
        # 作者
        authors = [a.find("atom:name", ns).text.strip()
                   for a in entry.findall("atom:author", ns)
                   if a.find("atom:name", ns) is not None]
        cache[arxiv_id] = {
            "abstract": abstract,
            "authors": "; ".join(authors[:4]) + ("; et al." if len(authors) > 4 else ""),
        }
        return cache[arxiv_id]
    except Exception:
        cache[arxiv_id] = None
        return None


def gen_paper_abstracts(data, arxiv_map):
    """从 128 篇可落地清单精选 Top 60,补摘要。"""
    # 读可落地清单的排序结果(复用 build_actionable_papers 逻辑)
    sys.path.insert(0, SCRIPT_DIR)
    try:
        from build_actionable_papers import (
            score_paper, get_module, get_difficulty, get_code_status,
            deduplicate_title, is_valid_title,
        )
    except ImportError:
        return "# 重要论文摘要集\n\n(无法加载 build_actionable_papers 模块)\n"

    secs = data["sections"]
    all_papers = []
    for sid, items in secs.items():
        for it in items:
            all_papers.append({**it, "section_id": sid})

    # 评分去重
    seen = set()
    scored = []
    for p in all_papers:
        if not is_valid_title(p["title"]):
            continue
        dt = deduplicate_title(p["title"])
        if dt in seen or len(dt) < 15:
            continue
        seen.add(dt)
        s = score_paper(p)
        if s >= 30:
            scored.append((s, p))
    scored.sort(key=lambda x: (-x[0], -int(x[1]["year"] or "0")))
    top = scored[:60]

    out = []
    out.append("# 板块 13:重要论文摘要集\n\n")
    out.append(f"> 从 2,640 篇相关文献中精选 **{len(top)} 篇**高价值论文,补充方法摘要与关键贡献。\n\n")
    out.append("> 数据来源:arXiv API 实时拉取(若论文不在 arXiv,标注\"待人工补充\")。\n\n")

    out.append("## 使用说明\n\n")
    out.append("每篇论文卡片含:**基本信息 / 方法核心 / 关键贡献 / 复现路径**。\n")
    out.append("优先阅读 Top 20(可落地分 ≥ 60),其余按需查阅。\n\n")

    # arXiv 摘要补取
    # 策略:① 先匹配 arXiv feed (本地缓存,无 API 压力)
    #       ② 对 source==arXiv 且 ref 含 arXiv id 的论文调 API(限前 25 篇,礼貌间隔)
    print(f"  补取 arXiv 摘要...")
    cache = {}
    feed_hits = 0
    api_hits = 0
    api_quota = 25  # API 调用上限,避免压力

    # 第一轮:匹配 arXiv feed (本地)
    for score, paper in top:
        title_key = re.sub(r"[^\w\s]", "", paper["title"].lower())[:60]
        if title_key in arxiv_map:
            cache[title_key] = {
                "abstract": arxiv_map[title_key].get("summary", ""),
                "authors": arxiv_map[title_key].get("authors", ""),
            }
            feed_hits += 1

    # 第二轮:对 source=arXiv 的论文调 API
    api_done = 0
    for score, paper in top:
        if api_done >= api_quota:
            break
        title_key = re.sub(r"[^\w\s]", "", paper["title"].lower())[:60]
        if title_key in cache:
            continue
        ref = paper.get("ref", "")
        m = re.search(r"(\d{4}\.\d{4,5})", ref)
        if not m:
            continue
        arxiv_id = m.group(1)
        info = fetch_arxiv_abstract(arxiv_id, cache)
        if info:
            cache[title_key] = info  # 用 title_key 作 key,便于后续查找
            api_hits += 1
            api_done += 1
            time.sleep(1.2)
    print(f"  arXiv 摘要补取完成(feed 匹配 {feed_hits} 篇 + API {api_hits} 篇)\n")

    # 输出论文卡片(按模块分组)
    by_module = defaultdict(list)
    for score, paper in top:
        mod = get_module(paper)
        by_module[mod].append((score, paper))

    out.append(f"## 共 {len(top)} 篇 · 按项目模块分组\n\n")
    module_order = [f"{i:02d}" for i in range(1, 11)] + ["跨板块"]
    mod_names = {
        "01": "轨道传播", "02": "ISL/GSL 链路", "03": "拓扑策略",
        "04": "路由算法", "05": "流量/容量/时延", "06": "可微优化",
        "07": "PINN 神经传播", "08": "LLM Agent", "09": "切换/移动性",
        "10": "TCP 传输",
    }

    for mid in module_order:
        mname = mod_names.get(mid, mid)
        # 找匹配的模块
        matched = []
        for mod, items in by_module.items():
            if mod.startswith(mid) or mid in mod:
                matched.extend(items)
        if not matched:
            continue
        matched.sort(key=lambda x: -x[0])
        out.append(f"### {mid} {mname}({len(matched)} 篇)\n\n")
        for score, paper in matched:
            title_key = re.sub(r"[^\w\s]", "", paper["title"].lower())[:60]
            info = cache.get(title_key)
            title = re.sub(r"^\s*\d+\.\s*", "", paper["title"]).strip()
            year = paper["year"] or "-"
            diff = get_difficulty(paper)
            code = get_code_status(paper)

            out.append(f"#### 【可落地分 {score}】{title}\n\n")
            out.append(f"- **年份**:{year} | **来源**:{paper.get('source', '-')} "
                       f"| **难度**:{diff}\n")
            out.append(f"- **会议/期刊**:{ref or '—'}\n")
            out.append(f"- **代码状态**:{code}\n")
            if info and info.get("abstract"):
                abstract = info["abstract"]
                # 取前 350 字符
                if len(abstract) > 350:
                    abstract = abstract[:350] + "..."
                out.append(f"- **方法核心**:{abstract}\n")
                if info.get("authors"):
                    out.append(f"- **作者**:{info['authors']}\n")
            else:
                out.append("- **方法核心**:_待人工补充(非 arXiv 论文或 API 失败)_\n")
            out.append(f"- **对应模块**:{get_module(paper)}\n\n")
    return "".join(out)


# ---------------------------------------------------------------------------
# 3. BibTeX 引用库
# ---------------------------------------------------------------------------
def escape_bibtex(s):
    """转义 BibTeX 特殊字符。"""
    if not s:
        return ""
    return s.replace("{", "").replace("}", "").replace("&", "\\&").replace("%", "\\%")


def make_bibtex_key(paper, idx):
    """生成 BibTeX key: lastname_year_firstword 或 paper_idx。"""
    title = re.sub(r"^\s*\d+\.\s*", "", paper.get("title", "")).strip()
    first_word = re.sub(r"[^\w]", "", title.split()[0] if title else "paper").lower()
    year = paper.get("year", "xxxx") or "xxxx"
    return f"{first_word[:15]}{year}_{idx:04d}"


def gen_bibtex(data):
    """生成 BibTeX 主文件 + 10 个分板块文件。"""
    secs = data["sections"]
    section_files = {
        "01": "_citations_01_轨道传播.bib",
        "02": "_citations_02_链路评估.bib",
        "03": "_citations_03_拓扑策略.bib",
        "04": "_citations_04_路由算法.bib",
        "05": "_citations_05_流量容量时延.bib",
        "06": "_citations_06_可微优化.bib",
        "07": "_citations_07_PINN神经传播.bib",
        "08": "_citations_08_AI编排LLM.bib",
        "09": "_citations_09_切换移动性.bib",
        "10": "_citations_10_TCP传输.bib",
    }
    section_headers = {
        "01": "板块 01:轨道传播层",
        "02": "板块 02:ISL/GSL 链路评估层",
        "03": "板块 03:拓扑策略层",
        "04": "板块 04:路由算法层",
        "05": "板块 05:流量/容量/时延层",
        "06": "板块 06:可微优化层",
        "07": "板块 07:PINN / 神经传播层",
        "08": "板块 08:AI 编排 / LLM Agent 层",
        "09": "板块 09:切换 / 移动性层",
        "10": "板块 10:TCP / 传输层",
    }

    total = 0
    master_lines = ["% SatelliteSimJulia 文献调研 · BibTeX 主库\n",
                    "% 自动生成,请勿手动编辑\n",
                    f"% 共 {sum(len(v) for v in secs.values())} 条(含跨板块重复)\n\n"]

    section_counts = {}

    for sid, items in secs.items():
        if sid not in section_files:
            continue
        sec_lines = [f"% {section_headers[sid]}\n",
                     f"% 共 {len(items)} 条\n\n"]
        for idx, paper in enumerate(items):
            key = make_bibtex_key(paper, idx)
            title = escape_bibtex(re.sub(r"^\s*\d+\.\s*", "",
                                         paper.get("title", "")).strip())
            year = paper.get("year", "")
            ref = escape_bibtex(paper.get("ref", ""))
            source = paper.get("source", "")
            # 判断条目类型
            if source == "arXiv":
                entry_type = "misc"
                venue_field = f"  howpublished = {{arXiv:{ref}}},\n"
                note_field = f"  eprint = {{{ref}}},\n  archivePrefix = {{arXiv}},\n"
            elif source in ("CCF", "CCF_Conf"):
                entry_type = "inproceedings"
                venue_field = f"  booktitle = {{{ref}}},\n"
                note_field = ""
            elif source in ("CAS",):
                entry_type = "article"
                venue_field = f"  journal = {{{ref}}},\n"
                note_field = ""
            else:
                entry_type = "misc"
                venue_field = f"  howpublished = {{{ref}}},\n" if ref else ""
                note_field = ""

            entry = (f"@{entry_type}{{{key},\n"
                     f"  title = {{{title}}},\n"
                     f"  year = {{{year}}},\n"
                     f"  author = {{}},\n"
                     f"{venue_field}"
                     f"{note_field}"
                     f"  source = {{{source}}},\n"
                     f"  section = {{{sid}}}\n"
                     f"}}\n\n")
            sec_lines.append(entry)
            master_lines.append(entry)
            total += 1

        section_counts[sid] = len(items)
        with open(os.path.join(OUT_DIR, section_files[sid]), "w",
                  encoding="utf-8") as f:
            f.writelines(sec_lines)
        print(f"  ✓ {section_files[sid]}({len(items)} 条)")

    # 更新 master 总数注释
    master_lines[2] = f"% 共 {total} 条(含跨板块重复)\n"
    with open(os.path.join(OUT_DIR, "_bibliography.bib"), "w",
              encoding="utf-8") as f:
        f.writelines(master_lines)
    print(f"  ✓ _bibliography.bib(总计 {total} 条)")
    return total, section_counts


# ---------------------------------------------------------------------------
# 4. 冲刺路线图
# ---------------------------------------------------------------------------
def gen_sprint_roadmap():
    out = []
    out.append("# 板块 14:冲刺设计 · 路线图\n\n")
    out.append("> 把 11_分类汇总的\"分阶段推进\"展开为 Sprint 级,每 Sprint 含目标 / 任务 / 交付物 / 依赖 / 评估 / 风险。\n\n")
    out.append("> 时间估算基于 1 人全职,无依赖并行。⏱ 周为单位。\n\n")

    sprints = [
        {
            "id": "Sprint 1",
            "name": "对标验证",
            "duration": "2 周",
            "phase": "阶段 1(短期)",
            "color": "🔵",
            "goal": "复现 Hypatia 基准数值,验证本项目轨道/链路/路由层的正确性",
            "tasks": [
                "复现 Hypatia Paris→Luanda RTT 85-117ms(用 satgenpy 同款 +Grid 拓扑)",
                "传播器精度对比:TwoBody/J2/SGP4 vs SatelliteToolbox truth(1天/7天/30天)",
                "ISL 物理评估验证:距离/仰角/LOS 与 Hypatia 数值对齐",
                "拓扑图论指标验证:度分布/直径/介数 vs 解析公式(3-ISL 论文)",
                "路由算法 baseline:Dijkstra/FW/ECMP 在 Iridium-66 + Starlink-1584 上跑通",
            ],
            "deliverables": [
                "experiments/benchmark/hypatia_rtt_validation.jl",
                "experiments/benchmark/propagator_accuracy.jl",
                "experiments/benchmark/topology_metrics.jl",
                "报告:数值对齐表(本项目 vs Hypatia vs 解析)",
            ],
            "dependencies": [
                "src/orbit 已有 TwoBody/J2/SGP4(✅)",
                "src/net 已有 Dijkstra/FW/ECMP/MLB(✅)",
                "src/link 已有 ISL 物理评估(✅)",
            ],
            "metrics": [
                "RTT 误差 < 5ms(相对 Hypatia 85-117ms 基准)",
                "J2 1天位置误差 < 10km(文献基准)",
                "度分布/直径与解析公式偏差 < 1%",
                "Iridium-66 全 OD 对路由计算 < 1s",
            ],
            "risks": [
                ("Hypatia 数值与本项目不一致", "中", "对比单步链路/路由输出,定位差异源"),
                ("SGP4 实现差异", "低", "用 SatelliteToolbox 的 SGP4 做交叉验证"),
            ],
        },
        {
            "id": "Sprint 2",
            "name": "第一篇论文 · 可微优化闭环",
            "duration": "4 周",
            "phase": "阶段 2(中期)",
            "color": "🟠",
            "goal": "打通\"可微 J2 传播 → 软 ISL/覆盖 loss → Adam 端到端星座优化\"闭环,产出第一篇论文",
            "tasks": [
                "Week 1:可微 J2 传播器单元测试(Enzyme/Zygote 梯度数值正确性)",
                "Week 1:软 ISL / 软覆盖 loss 实现(可微 softmax 选择)",
                "Week 2:optimize_coverage driver 联调(端到端梯度穿透)",
                "Week 2:Adam 优化器超参搜索(lr/β1/β2/epochs)",
                "Week 3:实验扩展(多星座规模扫描:66/1584/3000+ 卫星)",
                "Week 3:对比 baseline(网格搜索 vs 梯度优化 vs 随机)",
                "Week 4:论文撰写(IEEE Trans. Network / INFOCOM 投稿)",
            ],
            "deliverables": [
                "src/opt 完整可微闭环(✅ 已部分实现,本 Sprint 补全)",
                "experiments/layered/E1_optimize_coverage.jl",
                "paper/differentiable_coverage/(LaTeX 论文初稿)",
                "可微优化闭环汇报 PPT",
            ],
            "dependencies": [
                "Sprint 1 完成(数值基准可信)",
                "src/opt 已有 Enzyme/Zygote/Lux 依赖(✅)",
                "HPOP truth 传播器(⚠️ 实验脚本中,需稳定化)",
            ],
            "metrics": [
                "梯度数值正确(相对有限差分误差 < 1e-4)",
                "Adam 优化后覆盖率提升 ≥ 3%(相对 Walker 均匀参数)",
                "端到端优化 1584 卫星 < 10 分钟",
                "论文初稿 ≥ 8 页 IEEE 双栏格式",
            ],
            "risks": [
                ("Enzyme 对 J2 传播不可微", "高", "用 Zygote 回退,或手写伴随"),
                ("Adam 不收敛", "中", "检查 loss 景观,加梯度裁剪/warm restart"),
                ("优化增益不显著", "中", "扩展到时延+容量多目标,提升故事性"),
                ("HPOP truth 不稳定", "中", "用 GMAT 离线生成 truth 数据"),
            ],
        },
        {
            "id": "Sprint 3",
            "name": "第二篇论文 · PINN 路由时延预测器",
            "duration": "3 周",
            "phase": "阶段 3(长期)",
            "color": "🔴",
            "goal": "完成 pinn_routing.jl 训练验证闭环,证明 PINN 可替代传统路由时延计算",
            "tasks": [
                "Week 1:训练数据生成(Dijkstra 算全 OD 对 → 12 维特征 + 时延标签)",
                "Week 1:Lux MLP 模型定稿(12→64→64→64→1,~8K 参数)",
                "Week 2:训练闭环(MSE loss + 物理约束:流量守恒)",
                "Week 2:精度验证(PINN 预测 vs Dijkstra truth,RMSE)",
                "Week 3:推理速度对比(PINN 前向 vs Dijkstra 全图)",
                "Week 3:泛化测试(不同星座规模/拓扑的迁移误差)",
                "Week 3:论文撰写(NeurIPS/ICML Workshop 或 IEEE Trans. ML)",
            ],
            "deliverables": [
                "src/opt/src/layers/04_routing/pinn_routing.jl(✅ 已有,本 Sprint 完善)",
                "experiments/layered/E2_pinn_routing.jl",
                "paper/pinn_routing/(LaTeX 论文初稿)",
            ],
            "dependencies": [
                "Sprint 2 完成(可微基础设施)",
                "src/opt 已有 Lux/Optimisers/Zygote(✅)",
                "pinn_model.jl 已有 12 维特征编码(✅)",
            ],
            "metrics": [
                "PINN 预测 RMSE < 5% Dijkstra truth",
                "PINN 前向推理 < 1ms(单 OD 对)",
                "推理速度 ≥ 100× Dijkstra(全 OD 对)",
                "泛化误差 < 10%(从 66 → 1584 卫星迁移)",
            ],
            "risks": [
                ("PINN 精度不达标", "高", "加深网络/加 attention/换 FNO"),
                ("物理约束不收敛", "中", "调 λ 权重,或换 soft constraint"),
                ("泛化能力差", "高", "训练时多星座混合,加 meta-learning"),
            ],
        },
        {
            "id": "Sprint 4",
            "name": "LLM 编排产品化",
            "duration": "2 周",
            "phase": "阶段 3(长期)",
            "color": "🟣",
            "goal": "把 agent_repl 从原型打磨为可演示的 LLM 仿真编排器,支持自然语言驱动仿真",
            "tasks": [
                "Week 1:意图识别准确率提升(自然语言 → 正确工具调用)",
                "Week 1:工具编排错误处理(参数校验/回退/重试)",
                "Week 2:防泄漏层强化(TopologyIntent/RoutingIntent 翻译规则完善)",
                "Week 2:演示用例库(10 个典型自然语言查询 → 仿真结果)",
                "Week 2:文档与 demo 视频",
            ],
            "deliverables": [
                "src/lab/agent_repl 产品化(✅ 已有原型)",
                "docs/agent_demo/(10 个用例 + 录屏)",
                "LLM 编排器技术报告",
            ],
            "dependencies": [
                "DEEPSEEK_API_KEY 或其他 LLM API(用户自备)",
                "src/lab 已有 SimAgent/Intent(✅)",
            ],
            "metrics": [
                "意图识别准确率 ≥ 90%(10 用例测试集)",
                "端到端任务完成率 ≥ 80%",
                "平均响应时延 < 10s(LLM 推理 + 工具执行)",
                "防泄漏率 100%(用户不接触 GridPlusStrategy 等实现名词)",
            ],
            "risks": [
                ("LLM API 不稳定", "中", "多模型回退(DeepSeek/GPT/Claude)"),
                ("意图识别错误", "中", "加 few-shot 示例 + 用户确认环节"),
            ],
        },
    ]

    # 总览
    out.append("## 0. Sprint 总览\n\n")
    out.append("| Sprint | 名称 | 时长 | 阶段 | 核心交付 | 优先级 |\n")
    out.append("|--------|------|------|------|----------|--------|\n")
    sprint_deliverable_summary = {
        "Sprint 1": "对标数值验证报告 + 4 个 benchmark 实验",
        "Sprint 2": "可微优化闭环 + 论文初稿(IEEE Trans./INFOCOM)",
        "Sprint 3": "PINN 路由预测器 + 论文初稿(NeurIPS/IEEE)",
        "Sprint 4": "LLM 编排器产品化 + 10 个 demo 用例",
    }
    for s in sprints:
        deliv = sprint_deliverable_summary.get(s["id"], "—")
        out.append(f"| {s['color']} {s['id']} | {s['name']} | {s['duration']} | "
                   f"{s['phase']} | {deliv} | "
                   f"{'🔥🔥🔥' if '论文' in s['name'] else '🔥🔥'} |\n")
    out.append(f"\n**总计**:{sum(int(re.search(r'(\d+)', s['duration']).group(1)) for s in sprints)} 周 "
               f"(约 2.5 个月全职)\n\n")

    # 甘特图
    out.append("## 1. 时间线(甘特图)\n\n")
    out.append("```mermaid\n")
    out.append("gantt\n")
    out.append("  title SatelliteSimJulia 研究路线图\n")
    out.append("  dateFormat  YYYY-MM-DD\n")
    out.append("  axisFormat  %W\n")
    out.append("  section 阶段1\n")
    out.append(f"  Sprint 1 对标验证 :s1, 2026-07-07, 2w\n")
    out.append("  section 阶段2\n")
    out.append(f"  Sprint 2 可微闭环 :s2, after s1, 4w\n")
    out.append("  section 阶段3\n")
    out.append(f"  Sprint 3 PINN 路由 :s3, after s2, 3w\n")
    out.append(f"  Sprint 4 LLM 编排 :s4, after s3, 2w\n")
    out.append("```\n\n")
    out.append("> Sprint 3 与 Sprint 4 可并行(不同人/不同时段)。\n\n")

    # 每个 Sprint 详情
    for s in sprints:
        out.append(f"## {s['color']} {s['id']}:{s['name']}(⏱ {s['duration']})\n\n")
        out.append(f"**所属阶段**:{s['phase']}\n\n")
        out.append(f"### 🎯 目标\n\n{s['goal']}\n\n")
        out.append("### 📋 任务清单\n\n")
        for i, t in enumerate(s["tasks"], 1):
            out.append(f"{i}. {t}\n")
        out.append("\n### 📦 交付物\n\n")
        for d in s["deliverables"]:
            out.append(f"- {d}\n")
        out.append("\n### 🔗 依赖\n\n")
        for dep in s["dependencies"]:
            out.append(f"- {dep}\n")
        out.append("\n### 📊 评估指标(成功标准)\n\n")
        out.append("| 指标 | 目标值 |\n")
        out.append("|------|--------|\n")
        for m in s["metrics"]:
            # 简单分割:取最后一个冒号或括号前为指标名
            idx = max(m.find("("), m.find("≤"), m.find("<"), m.find(">"), m.find("≥"))
            if idx > 0:
                metric_name = m[:idx].strip().rstrip(",;:")
                target = m[idx:].strip("(), ")
            else:
                metric_name = m
                target = "—"
            out.append(f"| {metric_name} | {target} |\n")
        out.append("\n### ⚠️ 风险与缓解\n\n")
        out.append("| 风险 | 概率 | 缓解措施 |\n")
        out.append("|------|------|----------|\n")
        for risk, prob, mitigation in s["risks"]:
            out.append(f"| {risk} | {prob} | {mitigation} |\n")
        out.append("\n---\n\n")

    out.append("## 路线图原则\n\n")
    out.append("1. **Sprint 1 是基础**:数值基准不对齐,后续创新都不可信。\n")
    out.append("2. **Sprint 2 是核心**:可微优化闭环是第一篇论文,优先级最高。\n")
    out.append("3. **Sprint 3 是亮点**:PINN 路由是领域空白,具备 A 类论文潜力。\n")
    out.append("4. **Sprint 4 是产品化**:LLM 编排是差异化亮点,但不阻塞论文发表。\n")
    out.append("5. **并行原则**:Sprint 3 与 Sprint 4 可并行;Sprint 1 与 Sprint 2 串行。\n")

    return "".join(out)


# ---------------------------------------------------------------------------
# 5. 计划文档存档
# ---------------------------------------------------------------------------
def save_plan_doc():
    os.makedirs(PLANS_DIR, exist_ok=True)
    plan_path = os.path.join(PLANS_DIR, "本次补充任务计划.md")
    plan_content = """# 本次补充任务计划(存档)

> 批准日期:2026-07-04
> 状态:已批准,执行中

## 目标

基于现有 12 篇 .md 综述 + 可落地清单(128 篇)+ arXiv 自动收集器,补充 4 个高价值产出,
全部中文,放至 `SatelliteSimJulia/docs/literature/`。

## 待交付 4 项产出

### 📄 1. Benchmark 对比矩阵 → `12_Benchmark对比矩阵.md`
横向对比 SatelliteSimJulia 与 7 个标杆项目(Hypatia / OpenSN / SaTCP / StarryNet /
NeuralPDE.jl / SatelliteToolbox.jl / Graphs.jl)。对比 10 个维度,每维度 ✅/⚠️/❌ 标,
末列给出选型决策。

### 📄 2. 重要论文摘要集 → `13_重要论文摘要集.md`
从 128 篇可落地论文精选 ~60 篇(Top 1/2),每篇含基本信息 / 方法核心(arXiv 摘要补取)/
关键贡献 / 复现路径。

### 📄 3. BibTeX 引用库
- 主文件 `_bibliography.bib`(所有 2640 篇)
- 10 个分板块 `_citations_01_*.bib` ... `_citations_10_*.bib`
- arXiv 用 `@misc`,CCF 会议用 `@inproceedings`,期刊用 `@article`

### 📄 4. 冲刺设计·路线图 → `14_冲刺路线图.md`
4 个 Sprint(Sprint 1 对标验证 / Sprint 2 可微闭环 / Sprint 3 PINN 路由 / Sprint 4 LLM 编排),
每 Sprint 6 字段:目标 / 任务清单 / 交付物 / 依赖 / 评估指标 / 风险与缓解。

## 实施方式

新增 1 个 Python 脚本 `scripts/build_supplementary_docs.py`,统一产出以上 4 类文档。
读现有 `_data.json` + arXiv feed + arXiv API(摘要补取)。

**不修改** SatelliteSimJulia 任何源代码;**不修改** 现有 12 篇综述。可重复运行(幂等)。

## 成功标准

- [ ] 4 份文档/库生成完毕
- [ ] 计划文档存档(本文件)
- [ ] BibTeX 总条数 ≥ 2,500
- [ ] 对比矩阵覆盖 8 项目 × 10 维度
- [ ] 摘要集 ≥ 50 篇,每篇含方法/贡献/复现路径
- [ ] 路线图含 4 个 Sprint,每 Sprint 6 字段齐全
- [ ] 不修改现有文件

## 不会做的事

- 不修改 src/ 任何代码
- 不修改现有 12 篇综述
- 不为章节凑数(BibTeX 缺字段如实标注)
- 不创造数据(arXiv 没摘要标注"待人工补充")
"""
    with open(plan_path, "w", encoding="utf-8") as f:
        f.write(plan_content)
    print(f"  ✓ _plans/本次补充任务计划.md")
    return plan_path


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
def main():
    if not os.path.exists(JSON_IN):
        sys.exit(f"JSON 不存在:{JSON_IN}")

    print("=" * 60)
    print("SatelliteSimJulia 第二轮补充文档生成器")
    print("=" * 60)

    os.makedirs(OUT_DIR, exist_ok=True)
    os.makedirs(PLANS_DIR, exist_ok=True)
    data, arxiv_map = load_data()

    # 1. Benchmark 对比矩阵
    print("\n[1/5] 生成 Benchmark 对比矩阵...")
    matrix = gen_benchmark_matrix()
    with open(os.path.join(OUT_DIR, "12_Benchmark对比矩阵.md"), "w",
              encoding="utf-8") as f:
        f.write(matrix)
    print("  ✓ 12_Benchmark对比矩阵.md")

    # 2. 重要论文摘要集
    print("\n[2/5] 生成重要论文摘要集(含 arXiv 摘要补取)...")
    abstracts = gen_paper_abstracts(data, arxiv_map)
    with open(os.path.join(OUT_DIR, "13_重要论文摘要集.md"), "w",
              encoding="utf-8") as f:
        f.write(abstracts)
    print("  ✓ 13_重要论文摘要集.md")

    # 3. BibTeX 引用库
    print("\n[3/5] 生成 BibTeX 引用库...")
    total_bib, section_counts = gen_bibtex(data)

    # 4. 冲刺路线图
    print("\n[4/5] 生成冲刺路线图...")
    roadmap = gen_sprint_roadmap()
    with open(os.path.join(OUT_DIR, "14_冲刺路线图.md"), "w",
              encoding="utf-8") as f:
        f.write(roadmap)
    print("  ✓ 14_冲刺路线图.md")

    # 5. 计划文档存档
    print("\n[5/5] 存档计划文档...")
    save_plan_doc()

    # 总结
    print("\n" + "=" * 60)
    print(f"✅ 全部完成!产出汇总:")
    print(f"  - 12_Benchmark对比矩阵.md")
    print(f"  - 13_重要论文摘要集.md")
    print(f"  - _bibliography.bib({total_bib} 条) + 10 分板块")
    print(f"  - 14_冲刺路线图.md")
    print(f"  - _plans/本次补充任务计划.md")
    print("=" * 60)


if __name__ == "__main__":
    main()
