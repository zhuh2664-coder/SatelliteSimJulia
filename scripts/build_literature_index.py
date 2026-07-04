#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
SatelliteSimJulia 文献综述筛选脚本

从本地论文库 (satellite_security_papers.csv, ~15800 篇) 筛选与
SatelliteSimJulia 项目相关的论文, 按 10 个技术层级板块分类,
输出结构化 JSON 供后续生成 Markdown 综述和汇报 PPT。

用法:
    python3 build_literature_index.py
输出:
    docs/literature/_data.json   (结构化筛选结果)
    docs/literature/_stats.txt   (统计摘要)
"""

import csv
import json
import os
import re
import sys
from collections import Counter, defaultdict

# ---------------------------------------------------------------------------
# 路径配置
# ---------------------------------------------------------------------------
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.dirname(SCRIPT_DIR)
CSV_PATH = os.path.normpath(os.path.join(
    PROJECT_DIR, "..", "全球有哪些期刊或者会议", "索引与报告",
    "satellite_security_papers.csv"))
OUT_DIR = os.path.join(PROJECT_DIR, "docs", "literature")
JSON_OUT = os.path.join(OUT_DIR, "_data.json")
STATS_OUT = os.path.join(OUT_DIR, "_stats.txt")


# ---------------------------------------------------------------------------
# CSV 读取 (手工处理 title 含逗号的问题)
# ---------------------------------------------------------------------------
# 列顺序: tags, source, year, title, ref, ni_sub_tags, ni_cluster,
#         ni_cluster_label, lg_cluster, lg_cluster_label, pf_category,
#         cr_category, ni_sbert_cluster, ni_sbert_label, ni_is_security,
#         cr_kw_category, cr_sbert_cluster, cr_sbert_label, pf_sbert_cluster,
#         pf_sbert_label, pf_is_perf, lg_sbert_cluster, lg_sbert_label, lg_is_ml
# 共 24 列。title 在第 4 列(索引3),若该行有额外逗号, title 会跨越多列。
# 重建策略: 固定前3列 + 后20列, 中间所有列拼成 title。

NUM_COLS = 24
HEAD_COLS = 3      # tags, source, year
TAIL_COLS = 20     # ref 之后的所有列
TITLE_MIN_START = 3  # title 起始索引


def parse_row(raw_fields):
    """把一行拆分后的字段数组重建为标准 24 列记录。"""
    n = len(raw_fields)
    if n == NUM_COLS:
        fields = raw_fields
    elif n > NUM_COLS:
        # title 跨越多列: 前 3 列 + 中间 (n-23) 列拼成 title + 后 20 列
        head = raw_fields[:HEAD_COLS]
        title_parts = raw_fields[TITLE_MIN_START:n - TAIL_COLS]
        tail = raw_fields[n - TAIL_COLS:]
        title = ",".join(title_parts)
        fields = head + [title] + tail
    else:
        # 列数不足, 用空串补齐
        fields = raw_fields + [""] * (NUM_COLS - n)
    return {
        "tags": fields[0].strip(),
        "source": fields[1].strip(),
        "year": fields[2].strip(),
        "title": fields[3].strip(),
        "ref": fields[4].strip(),
        "ni_sub_tags": fields[5].strip(),
        "ni_cluster": fields[6].strip(),
        "ni_cluster_label": fields[7].strip(),
        "lg_cluster": fields[8].strip(),
        "lg_cluster_label": fields[9].strip(),
        "pf_category": fields[10].strip(),
        "cr_category": fields[11].strip(),
        "ni_sbert_label": fields[14].strip(),
        "cr_kw_category": fields[15].strip(),
        "cr_sbert_label": fields[17].strip(),
        "pf_sbert_label": fields[19].strip(),
        "lg_sbert_label": fields[22].strip(),
    }


def load_papers():
    papers = []
    with open(CSV_PATH, "r", encoding="utf-8", newline="") as f:
        reader = csv.reader(f)
        header = next(reader, None)
        for row in reader:
            if not row or len(row) < 4:
                continue
            rec = parse_row(row)
            if rec["title"]:
                papers.append(rec)
    return papers


# ---------------------------------------------------------------------------
# 板块定义: 每个板块用 title 关键词 + 分类字段交叉过滤
# ---------------------------------------------------------------------------
# rel_tier: 三档相关性。tier1=核心(关键词强匹配), tier2=相关(分类标签命中),
#           tier3=借鉴(相邻领域, 用于补足不足板块)

def kw_match(title_lower, keywords):
    """标题中是否任一关键词 (允许子串)。"""
    return any(k in title_lower for k in keywords)


def tag_match(rec, tag_keywords):
    """分类字段 (ni_sub_tags / ni_cluster_label / pf_category) 是否命中。"""
    blob = " ".join([
        rec.get("ni_sub_tags", ""),
        rec.get("ni_cluster_label", ""),
        rec.get("pf_category", ""),
        rec.get("lg_cluster_label", ""),
        rec.get("ni_sbert_label", ""),
    ]).lower()
    return any(k in blob for k in tag_keywords)


# 各板块的过滤规则。每个规则返回 (命中布尔, 相关性档位 'tier1'/'tier2'/'tier3')
SECTIONS = [
    # ---------------------------------------------------------------- 板块1
    {
        "id": "01",
        "name": "轨道传播层",
        "module": "src/orbit",
        "tier1_title_kw": [
            "propagat", "sgp4", "tle", "two-body", "twobody", "two body",
            "walker", "orbit determ", "orbital elemen", "kepler",
            "orbit propag", "constellation design", "constellation generat",
            "j2 ", "j4 ", "orbit predict", "orbit mechan",
        ],
        "tier2_tag_kw": [
            "轨道星座仿真", "a-轨道", "轨道", "walker",
        ],
        "exclude_title_kw": [],  # 不排除
    },
    # ---------------------------------------------------------------- 板块2
    {
        "id": "02",
        "name": "ISL/GSL 链路评估层",
        "module": "src/link",
        "tier1_title_kw": [
            "inter-satellite", "inter satellite", "isl", "isll",
            "ground-satellite", "ground to satellite", "gsl",
            "free space optic", "free-space optic", "optical link",
            "laser link", "laser inter", "satellite link", "feeder link",
            "los ", "line-of-sight", "elevation angle",
        ],
        "tier2_tag_kw": ["e-星间链路", "星间链路", "isl", "星地链路"],
        "exclude_title_kw": [],
    },
    # ---------------------------------------------------------------- 板块3
    {
        "id": "03",
        "name": "拓扑策略层",
        "module": "src/net",
        "tier1_title_kw": [
            "topology", "+grid", "plus grid", "mesh topology",
            "constellation topology", "network topology",
            "snapshot", "time-evolving topology", "time varying topology",
            "inter-satellite link assignment", "link assignment",
            "link reassignment", "isl topology", "isl pattern",
            "robustness", "degree distribution", "betweenness", "churn",
        ],
        "tier2_tag_kw": ["拓扑"],
        "require_strong_sat_in_title": True,
    },
    # ---------------------------------------------------------------- 板块4
    {
        "id": "04",
        "name": "路由算法层",
        "module": "src/net",
        "tier1_title_kw": [
            "routing", "dijkstra", "shortest path", "shortest-path",
            "ecmp", "load balanc", "load-balanc", "segment routing",
            "multipath", "multi-path", "traffic engineer", "path comput",
            "forwarding", "sdn", "software-defined",
        ],
        "tier2_tag_kw": ["路由", "satellite routing", "卫星路由"],
        "exclude_title_kw": [],
    },
    # ---------------------------------------------------------------- 板块5
    {
        "id": "05",
        "name": "流量/容量/时延层",
        "module": "src/metrics + src/traffic",
        "tier1_title_kw": [
            # 流量工程/容量 (要求与卫星词共现, 见 classify_paper 的强卫星词过滤)
            "traffic engineer", "traffic model", "traffic scheduling",
            "traffic delivery", "traffic diffusion", "traffic aware",
            "load balanc", "load-balanc", "load balancing",
            "network capacity", "system capacity", "throughput analy",
            "throughput optim", "capacity region", "capacity optim",
            "latency distribution", "latency predict", "latency model",
            "end-to-end latency", "e2e latency", "rtt", "round-trip",
            "congestion control", "queue", "queuing", "buffer sizing",
            "utilization", "bottleneck", "max-flow", "maximum flow",
            "link utilization",
        ],
        "tier2_tag_kw": [
            "资源分配", "高通量卫星", "卫星通信系统", "卫星路由",
            "capacity", "throughput",
        ],
        # 流量/容量板块需限定卫星上下文, 排除纯蜂窝/地面网
        "require_sat_context": True,
        # 额外: 标题也必须含强卫星词 (收紧)
        "require_strong_sat_in_title": True,
    },
    # ---------------------------------------------------------------- 板块6 (放宽)
    # 可微优化/AD 在卫星领域论文稀少, tier1 严格匹配 AD/gradient 关键词。
    # tier3 作为"借鉴领域": 卫星网络/轨道/通信的端到端/学习优化 (与可微精神相通)。
    #   要求标题同时含 (优化方法词) AND (强卫星词) AND (网络/轨道/通信领域词),
    #   排除纯遥感/图像应用。
    {
        "id": "06",
        "name": "可微优化层",
        "module": "src/opt",
        "tier1_title_kw": [
            "differentiab", "autodiff", "automatic differentiat",
            "gradient descent", "gradient-based", "end-to-end optim",
            "enzyme", "zygote", "forwarddiff", "reverse-mode",
            "surrogate model", "surrogate-based",
        ],
        "tier2_tag_kw": [],
        "tier3_title_kw": [  # 借鉴: 卫星领域的端到端/学习优化
            "end-to-end optim", "end-to-end learning", "end to end optim",
            "joint optim", "joint optimization", "trajectory optim",
            "surrogate", "data-driven",
            "machine learning argument", "neural network",
            "deep learning", "deep reinforcement",
            "reinforcement learning",
        ],
        "tier3_domain_kw": [  # tier3 还需命中网络/轨道/通信领域词
            "routing", "topology", "constellation", "leo",
            "orbit", "trajectory", "resource alloc", "power alloc",
            "beamform", "spectrum", "throughput", "latency",
            "satellite network", "isl", "coverage", "handover",
            "星间", "星地", "路由", "资源分配", "覆盖",
        ],
        "require_sat_context": True,
    },
    # ---------------------------------------------------------------- 板块7
    # PINN 严格 tier1; tier2 要求标题含 neural/learning + 强卫星词, 且
    #   标题应与"建模/传播/估计/动力学"相关 (排除纯分类/检测应用)。
    {
        "id": "07",
        "name": "PINN / 神经传播层",
        "module": "src/opt (NN layers)",
        "tier1_title_kw": [
            "pinn", "physics-informed", "physics informed",
            "neural operator", "deeponet", "neural ode", "neural ordinary",
            "fourier neural", "operator learning",
            "neural network propagat", "neural propagat",
            "neural surrogate", "scientific machine learning",
        ],
        "tier2_tag_kw": [],
        # tier2 借鉴: 卫星动力学/轨道/姿态的神经网络建模
        "tier2_title_kw": [
            "neural", "deep learning", "learning-based",
        ],
        "tier2_domain_kw": [  # tier2 还需命中领域词
            "orbit", "trajectory", "attitude", "dynamics",
            "propagat", "estimat", "orbit determ", "thermal",
        ],
        "require_sat_context": True,
    },
    # ---------------------------------------------------------------- 板块8
    {
        "id": "08",
        "name": "AI 编排 / LLM Agent 层",
        "module": "src/lab",
        "tier1_title_kw": [
            "large language", "llm", "gpt", "language model",
            "generative ai", "ai agent", "autonomous agent",
            "tool use", "orchestrat", "copilot", "foundation model",
        ],
        "tier2_tag_kw": ["multi agent", "agent"],
        "require_sat_context": True,
    },
    # ---------------------------------------------------------------- 板块9
    {
        "id": "09",
        "name": "切换 / 移动性层",
        "module": "src/link + src/net",
        "tier1_title_kw": [
            "handover", "handoff", "hand-off", "mobility",
            "beam hopping", "beam-hopping", "beam switch",
            "access selection", "user association", "channel assignment",
            "satellite selection", "gateway switch",
        ],
        "tier2_tag_kw": ["切换", "移动性", "handover"],
        "require_sat_context": False,
    },
    # ---------------------------------------------------------------- 板块10
    {
        "id": "10",
        "name": "TCP / 传输层",
        "module": "外接 (ns-3/解析模型)",
        "tier1_title_kw": [
            "tcp", "congestion control", "bbr", "cubic", "transport layer",
            "quic", "hybla", "mptcp", "pep", "performance enhancing",
            "rtt", "round-trip", "window",
        ],
        "tier2_tag_kw": ["tcp", "传输层", "congestion"],
        "require_sat_context": False,
    },
]

# 卫星上下文关键词 (用于 require_sat_context 的板块二次过滤)
SAT_CONTEXT_KW = [
    "satellite", "leo", "geo", "meo", "constellation", "space",
    "orbit", "starlink", "oneweb", "iridium", "isl", "spacecraft",
    "earth observation", "remote sensing", "gnss", "downlink", "uplink",
    "feeder link", "satcom", "non-terrestrial", "aerial", "haps",
    "卫星", "星地", "星座", "星间",
]


# 强卫星词 (标题中出现即认定是卫星领域论文, 而非任意含卫星上下文)
STRONG_SAT_KW = [
    "satellite", "constellation", "starlink", "oneweb", "iridium",
    "leo ", "geo ", "meo ", "gso ", "ngso", "spacecraft", "space-based",
    "satcom", "earth observation", "remote sensing",
    "卫星", "星座", "星地", "星间", "航天器",
]


def has_sat_context(rec):
    """标题 + 分类字段是否含卫星上下文。"""
    title_l = rec["title"].lower()
    if any(k in title_l for k in SAT_CONTEXT_KW):
        return True
    blob = " ".join([
        rec.get("ni_sub_tags", ""), rec.get("ni_cluster_label", ""),
        rec.get("pf_category", ""), rec.get("lg_cluster_label", ""),
    ]).lower()
    return any(k in blob for k in [
        "leo", "卫星", "星座", "星地", "星间", "satellite", "space",
        "轨道", "高通量", "isl", "非陆地", "non-terrestrial",
    ])


def title_has_strong_sat(title_l):
    """标题是否含强卫星词 (用于收紧 tier3/相关领域)。"""
    return any(k in title_l for k in STRONG_SAT_KW)


def classify_paper(paper, matched_ids):
    """把论文归入板块, 返回 [(section_id, tier), ...]。"""
    title_l = paper["title"].lower()
    results = []

    for sec in SECTIONS:
        sid = sec["id"]
        tier = None

        # tier1: 标题强关键词
        if kw_match(title_l, sec.get("tier1_title_kw", [])):
            tier = "tier1"
        # tier2: 板块7 专用双词逻辑 (方法词 AND 领域词)
        elif "tier2_title_kw" in sec and \
                kw_match(title_l, sec["tier2_title_kw"]) and \
                kw_match(title_l, sec.get("tier2_domain_kw", [])):
            tier = "tier2"
        # tier2 (通用): 分类标签命中 + 标题含强卫星词
        elif "tier2_title_kw" not in sec and \
                tag_match(paper, sec.get("tier2_tag_kw", [])) and \
                title_has_strong_sat(title_l) and \
                any(k in title_l for k in sec.get("tier1_title_kw", []) +
                    sec.get("tier2_tag_kw", [])):
            tier = "tier2"
        # tier3: 借鉴领域, 要求 方法词 AND 强卫星词 AND 领域词 三重命中
        elif "tier3_title_kw" in sec and \
                kw_match(title_l, sec["tier3_title_kw"]) and \
                title_has_strong_sat(title_l) and \
                kw_match(title_l, sec.get("tier3_domain_kw", [""])) :
            tier = "tier3"

        if tier:
            # 卫星上下文过滤
            if sec.get("require_sat_context") and not has_sat_context(paper):
                continue
            # 强卫星词过滤 (进一步收紧宽泛板块)
            if sec.get("require_strong_sat_in_title") and \
                    not title_has_strong_sat(title_l):
                continue
            results.append((sid, tier))

    return results


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
def main():
    if not os.path.exists(CSV_PATH):
        sys.exit(f"CSV 不存在: {CSV_PATH}")

    os.makedirs(OUT_DIR, exist_ok=True)
    print(f"读取论文库: {CSV_PATH}")
    papers = load_papers()
    print(f"共载入 {len(papers)} 篇论文")

    # 全局年份分布
    year_counter = Counter(p["year"] for p in papers if p["year"])
    source_counter = Counter(p["source"] for p in papers)

    # 分类
    section_papers = defaultdict(list)  # section_id -> [paper dict with tier]
    paper_seen = set()

    for p in papers:
        matches = classify_paper(p, None)
        for sid, tier in matches:
            key = (sid, p["title"], p["year"])
            section_papers[sid].append({
                "title": p["title"],
                "year": p["year"],
                "source": p["source"],
                "ref": p["ref"],
                "tags": p["tags"],
                "ni_sub_tags": p["ni_sub_tags"],
                "tier": tier,
            })
            paper_seen.add(p["title"])

    # 每个板块内去重 (同标题同年只留一次, 取最高 tier)
    # 对 tier2/tier3 (相关/借鉴) 论文限定近5年 (>=2021) 以聚焦时效性;
    # tier1 核心论文全量保留。
    tier_rank = {"tier1": 3, "tier2": 2, "tier3": 1}
    RECENT_YEAR = 2021
    final_sections = {}
    for sid, items in section_papers.items():
        dedup = {}
        for it in items:
            # 相关/借鉴论文限近5年
            if it["tier"] in ("tier2", "tier3"):
                try:
                    if int(it["year"]) < RECENT_YEAR:
                        continue
                except (ValueError, TypeError):
                    continue
            k = (it["title"].lower().strip(), it["year"])
            if k not in dedup or tier_rank[it["tier"]] > tier_rank[dedup[k]["tier"]]:
                dedup[k] = it
        # 排序: tier 降序 -> 年份降序
        sorted_items = sorted(
            dedup.values(),
            key=lambda x: (-tier_rank[x["tier"]], -int(x["year"] or "0"))
        )
        final_sections[sid] = sorted_items

    # 构造元信息
    sections_meta = []
    for sec in SECTIONS:
        sid = sec["id"]
        items = final_sections.get(sid, [])
        tier_counts = Counter(it["tier"] for it in items)
        sections_meta.append({
            "id": sid,
            "name": sec["name"],
            "module": sec["module"],
            "total": len(items),
            "tier1": tier_counts.get("tier1", 0),
            "tier2": tier_counts.get("tier2", 0),
            "tier3": tier_counts.get("tier3", 0),
        })

    output = {
        "meta": {
            "csv_path": CSV_PATH,
            "total_papers_in_db": len(papers),
            "total_unique_matched": len(paper_seen),
            "year_distribution": dict(list(sorted(
                year_counter.items(),
                key=lambda x: -(int(x[0]) if x[0].isdigit() else 0)
            )[:30])),
            "source_distribution": dict(source_counter.most_common()),
        },
        "sections_meta": sections_meta,
        "sections": {sid: items for sid, items in final_sections.items()},
    }

    with open(JSON_OUT, "w", encoding="utf-8") as f:
        json.dump(output, f, ensure_ascii=False, indent=2)
    print(f"结构化数据已写出: {JSON_OUT}")

    # 统计摘要
    with open(STATS_OUT, "w", encoding="utf-8") as f:
        f.write("SatelliteSimJulia 文献综述筛选统计\n")
        f.write("=" * 50 + "\n\n")
        f.write(f"数据库总论文数: {len(papers)}\n")
        f.write(f"去重后命中的独立论文数: {len(paper_seen)}\n\n")
        f.write("各板块论文数:\n")
        f.write("-" * 50 + "\n")
        for sm in sections_meta:
            f.write(
                f"  板块{sm['id']} {sm['name']}: "
                f"共 {sm['total']} 篇 "
                f"(核心★ {sm['tier1']} / 相关☆ {sm['tier2']} / 借鉴 {sm['tier3']})\n"
            )
        f.write("\n数据源分布:\n")
        for src, cnt in source_counter.most_common():
            f.write(f"  {src}: {cnt}\n")
    print(f"统计摘要已写出: {STATS_OUT}")

    # 控制台速览
    print("\n各板块论文数:")
    for sm in sections_meta:
        flag = "✅" if sm["total"] >= 20 else "⚠️ "
        print(f"  {flag} 板块{sm['id']} {sm['name']}: {sm['total']} 篇 "
              f"(核心{sm['tier1']}/相关{sm['tier2']}/借鉴{sm['tier3']})")


if __name__ == "__main__":
    main()
