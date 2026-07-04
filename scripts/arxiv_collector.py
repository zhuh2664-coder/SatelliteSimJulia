#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
arXiv 论文自动收集系统

用 arXiv API (免费, 无需 API Key) 按 SatelliteSimJulia 项目的研究方向
定时搜索最新论文。产出 docs/literature/_arxiv_feed.json + _arxiv_feed.csv。

用法:
    python3 arxiv_collector.py                    # 默认搜索 + 保存
    python3 arxiv_collector.py --days 7           # 搜最近 7 天 (默认 14)
    python3 arxiv_collector.py --max 100          # 每查询最多取 100 篇 (默认 50)
    python3 arxiv_collector.py --no-save          # 试运行, 只打印不保存

可配合 crontab / launchd 每日自动运行:
    0 8 * * * cd /path/to/SatelliteSimJulia && python3 scripts/arxiv_collector.py --days 1

API 限制: 每次调用间隔 ≥1s, 无总量限制。arXiv ID 格式见输出。
"""

import json
import os
import re
import sys
import time
import urllib.request
import urllib.parse
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone
from collections import defaultdict

# ---------------------------------------------------------------------------
# 路径配置
# ---------------------------------------------------------------------------
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.dirname(SCRIPT_DIR)
OUT_DIR = os.path.join(PROJECT_DIR, "docs", "literature")
JSON_OUT = os.path.join(OUT_DIR, "_arxiv_feed.json")
CSV_OUT = os.path.join(OUT_DIR, "_arxiv_feed.csv")
LOG_OUT = os.path.join(OUT_DIR, "_arxiv_collector.log")

# arXiv API 端点
ARXIV_API = "http://export.arxiv.org/api/query"

# 每个查询的最大结果数 (API 上限 ~2000, 建议 50-100)
MAX_RESULTS = 50
# 默认搜索最近多少天
DEFAULT_DAYS = 14

# ---------------------------------------------------------------------------
# 搜索查询定义: 每查询对应一个研究方向
# ---------------------------------------------------------------------------
QUERIES = [
    # --- 板块1: 轨道传播 ---
    {
        "id": "01_orbit",
        "name": "轨道传播",
        "query": (
            '(ti:satellite OR ti:constellation OR ti:LEO OR ti:orbit) '
            'AND (ti:propagation OR ti:SGP4 OR ti:J2 OR ti:two-body OR ti:orbit determination OR ti:Walker)'
        ),
        "categories": ["cs.NI", "astro-ph.EP", "astro-ph.IM", "eess.SP"],
    },
    # --- 板块2: ISL链路 ---
    {
        "id": "02_link",
        "name": "ISL/GSL 链路",
        "query": (
            '(ti:"inter-satellite link" OR ti:ISL OR ti:"optical link" OR ti:"laser link" '
            'OR ti:"ground station" OR ti:GSL OR ti:"free space optic") '
            'AND (ti:satellite OR ti:LEO OR ti:constellation OR ti:space)'
        ),
        "categories": ["cs.NI", "physics.optics", "astro-ph.IM"],
    },
    # --- 板块3: 拓扑 ---
    {
        "id": "03_topology",
        "name": "拓扑策略",
        "query": (
            '(ti:topology OR ti:constellation OR ti:satellite) '
            'AND (ti:topology OR ti:graph OR ti:connectivity OR ti:robustness) '
            'AND (ti:satellite OR ti:LEO OR ti:constellation)'
        ),
        "categories": ["cs.NI", "cs.IT"],
    },
    # --- 板块4: 路由 ---
    {
        "id": "04_routing",
        "name": "路由算法",
        "query": (
            '(ti:routing OR ti:shortest OR ti:ECMP OR ti:"segment routing" OR ti:SDN) '
            'AND (ti:satellite OR ti:LEO OR ti:constellation OR ti:space)'
        ),
        "categories": ["cs.NI"],
    },
    # --- 板块5: 流量/容量/时延 ---
    {
        "id": "05_traffic",
        "name": "流量/容量/时延",
        "query": (
            '(ti:traffic OR ti:capacity OR ti:throughput OR ti:latency OR ti:delay) '
            'AND (ti:satellite OR ti:LEO OR ti:constellation)'
        ),
        "categories": ["cs.NI", "cs.IT", "cs.PF"],
    },
    # --- 板块6: 可微优化 ---
    {
        "id": "06_differentiable",
        "name": "可微优化",
        "query": (
            '(ti:differentiable OR ti:autodiff OR ti:"gradient descent" OR ti:"gradient-based" '
            'OR ti:surrogate) '
            'AND (ti:satellite OR ti:LEO OR ti:orbit OR ti:constellation)'
        ),
        "categories": ["cs.LG", "cs.NI", "math.OC"],
    },
    # --- 板块7: PINN ---
    {
        "id": "07_pinn",
        "name": "PINN 神经传播",
        "query": (
            '(ti:PINN OR ti:"physics-informed" OR ti:"neural operator" OR ti:DeepONet '
            'OR ti:"neural ODE" OR ti:"scientific machine learning") '
            'AND (ti:satellite OR ti:orbit OR ti:spacecraft OR ti:trajectory '
            'OR ti:dynamics OR ti:propagation OR ti:constellation)'
        ),
        "categories": ["cs.LG", "physics.comp-ph", "astro-ph.EP"],
    },
    # --- 板块8: LLM Agent ---
    {
        "id": "08_llm",
        "name": "LLM/Agent 编排",
        "query": (
            '(ti:"large language" OR ti:LLM OR ti:GPT OR ti:"language model" '
            'OR ti:agent OR ti:orchestrator) '
            'AND (ti:satellite OR ti:LEO OR ti:constellation OR ti:spacecraft '
            'OR ti:network OR ti:simulation)'
        ),
        "categories": ["cs.CL", "cs.NI", "cs.AI", "cs.RO"],
    },
    # --- 板块9: 切换 ---
    {
        "id": "09_handover",
        "name": "切换/移动性",
        "query": (
            '(ti:handover OR ti:handoff OR ti:mobility OR ti:"beam hopping" OR ti:hand-off) '
            'AND (ti:satellite OR ti:LEO OR ti:constellation)'
        ),
        "categories": ["cs.NI", "eess.SP"],
    },
    # --- 板块10: TCP ---
    {
        "id": "10_tcp",
        "name": "TCP 传输",
        "query": (
            '(ti:TCP OR ti:congestion OR ti:BBR OR ti:Cubic OR ti:QUIC OR ti:transport) '
            'AND (ti:satellite OR ti:LEO OR ti:constellation OR ti:space)'
        ),
        "categories": ["cs.NI"],
    },
    # --- 补充: 通用卫星仿真 ---
    {
        "id": "99_general",
        "name": "通用卫星仿真",
        "query": (
            '(ti:"satellite network" OR ti:"LEO constellation" OR ti:"mega-constellation" '
            'OR ti:Starlink OR ti:"satellite simulation" OR ti:"satellite emulation") '
            'AND (ti:simulation OR ti:emulation OR ti:network OR ti:performance)'
        ),
        "categories": ["cs.NI", "cs.PF"],
    },
]


# ---------------------------------------------------------------------------
# arXiv API 客户端
# ---------------------------------------------------------------------------
def fetch_arxiv(query_def, max_results=MAX_RESULTS, days=DEFAULT_DAYS):
    """调用 arXiv API, 返回论文列表。"""
    query_str = query_def["query"]
    cats = query_def.get("categories", ["cs.NI"])
    cat_clause = " OR ".join(f"cat:{c}" for c in cats)
    # 组合查询: 关键词 AND 类别
    full_query = f"({query_str}) AND ({cat_clause})"

    params = {
        "search_query": full_query,
        "start": 0,
        "max_results": max_results,
        "sortBy": "submittedDate",
        "sortOrder": "descending",
    }
    url = ARXIV_API + "?" + urllib.parse.urlencode(params)
    print(f"  查询 {query_def['id']}: {url[:120]}...", end=" ")

    try:
        req = urllib.request.Request(url, headers={"User-Agent": "SatelliteSimJulia/1.0"})
        with urllib.request.urlopen(req, timeout=30) as resp:
            xml_data = resp.read().decode("utf-8")
    except Exception as e:
        print(f"❌ 请求失败: {e}")
        return []

    # 解析 XML
    ns = {
        "atom": "http://www.w3.org/2005/Atom",
        "arxiv": "http://arxiv.org/schemas/atom",
    }
    try:
        root = ET.fromstring(xml_data)
    except ET.ParseError as e:
        print(f"❌ XML 解析失败: {e}")
        return []

    entries = root.findall("atom:entry", ns)
    papers = []
    cutoff = (datetime.now(tz=timezone.utc) - timedelta(days=days)).isoformat()

    for entry in entries:
        title_el = entry.find("atom:title", ns)
        title = title_el.text.strip().replace("\n", " ") if title_el is not None else ""

        summary_el = entry.find("atom:summary", ns)
        summary = summary_el.text.strip().replace("\n", " ") if summary_el is not None else ""

        published_el = entry.find("atom:published", ns)
        published = published_el.text.strip() if published_el is not None else ""

        updated_el = entry.find("atom:updated", ns)
        updated = updated_el.text.strip() if updated_el is not None else ""

        # 过滤: 只保留最近 N 天的
        if published < cutoff:
            continue

        arxiv_id = ""
        id_el = entry.find("atom:id", ns)
        if id_el is not None:
            # 从 http://arxiv.org/abs/2403.19736v1 中提取 ID
            m = re.search(r"arxiv.org/abs/([^\s]+)", id_el.text)
            if m:
                arxiv_id = m.group(1)

        cats = [c.get("term", "") for c in entry.findall("arxiv:primary_category", ns)]
        cat = cats[0] if cats else ""

        authors = [a.find("atom:name", ns).text.strip()
                   for a in entry.findall("atom:author", ns)
                   if a.find("atom:name", ns) is not None]
        authors_str = "; ".join(authors[:5])
        if len(authors) > 5:
            authors_str += "; et al."

        papers.append({
            "arxiv_id": arxiv_id,
            "title": title,
            "authors": authors_str,
            "published": published[:10],
            "updated": updated[:10],
            "category": cat,
            "summary": summary[:300],
            "query_id": query_def["id"],
            "query_name": query_def["name"],
        })

    print(f"✓ {len(papers)} 篇新论文")
    return papers


# ---------------------------------------------------------------------------
# 去重 + 排序
# ---------------------------------------------------------------------------
def deduplicate(papers):
    """按 arxiv_id 去重, 保留首次出现的 query 信息。"""
    seen = {}
    for p in papers:
        aid = p["arxiv_id"]
        if aid not in seen or p["published"] > seen[aid]["published"]:
            seen[aid] = p
    # 按发布日期降序
    return sorted(seen.values(), key=lambda x: x["published"], reverse=True)


# ---------------------------------------------------------------------------
# 保存
# ---------------------------------------------------------------------------
def save_results(papers, query_stats):
    os.makedirs(OUT_DIR, exist_ok=True)

    # JSON
    output = {
        "collected_at": datetime.now(tz=timezone.utc).isoformat(),
        "total_unique": len(papers),
        "query_stats": query_stats,
        "papers": papers,
    }
    with open(JSON_OUT, "w", encoding="utf-8") as f:
        json.dump(output, f, ensure_ascii=False, indent=2)
    print(f"\n✓ JSON 已保存: {JSON_OUT}")

    # CSV
    with open(CSV_OUT, "w", encoding="utf-8", newline="") as f:
        import csv
        writer = csv.writer(f)
        writer.writerow(["arxiv_id", "title", "authors", "published",
                          "category", "query_name", "summary"])
        for p in papers:
            writer.writerow([
                p["arxiv_id"], p["title"], p["authors"],
                p["published"], p["category"], p["query_name"],
                p["summary"],
            ])
    print(f"✓ CSV 已保存: {CSV_OUT}")

    # 追加日志
    timestamp = datetime.now(tz=timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    with open(LOG_OUT, "a", encoding="utf-8") as f:
        f.write(f"[{timestamp}] 共收集 {len(papers)} 篇新论文\n")
        for qs in query_stats:
            f.write(f"  {qs['name']}: {qs['count']} 篇\n")
        f.write("\n")

    # 打印摘要
    print(f"\n{'─'*50}")
    print(f"📊 收集摘要 ({output['collected_at'][:16]})")
    print(f"{'─'*50}")
    for qs in query_stats:
        print(f"  {qs['name']:<20} {qs['count']:>4} 篇")
    print(f"  去重后总计{'':<16} {len(papers):>4} 篇")
    by_cat = defaultdict(int)
    for p in papers:
        by_cat[p["category"]] += 1
    print(f"\n  分类分布:")
    for cat, cnt in sorted(by_cat.items(), key=lambda x: -x[1])[:8]:
        print(f"    {cat:<25} {cnt:>4} 篇")


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
def main():
    import argparse
    parser = argparse.ArgumentParser(description="arXiv 论文自动收集器")
    parser.add_argument("--days", type=int, default=DEFAULT_DAYS,
                        help=f"搜索最近多少天 (默认 {DEFAULT_DAYS})")
    parser.add_argument("--max", type=int, default=MAX_RESULTS,
                        help=f"每查询最多篇数 (默认 {MAX_RESULTS})")
    parser.add_argument("--no-save", action="store_true",
                        help="试运行模式,不保存文件")
    args = parser.parse_args()

    print(f"🚀 arXiv 论文收集器")
    print(f"   时间窗口: 最近 {args.days} 天 | 每查询上限: {args.max} 篇")
    print(f"   查询数: {len(QUERIES)} 个方向\n")

    all_papers = []
    query_stats = []

    for i, qdef in enumerate(QUERIES, 1):
        print(f"[{i}/{len(QUERIES)}] ", end="")
        papers = fetch_arxiv(qdef, max_results=args.max, days=args.days)
        all_papers.extend(papers)
        query_stats.append({"name": qdef["name"], "count": len(papers)})
        # 遵守 arXiv API 礼貌间隔
        if i < len(QUERIES):
            time.sleep(1.5)

    # 去重
    unique = deduplicate(all_papers)
    duplicates = len(all_papers) - len(unique)
    print(f"\n去重: {len(all_papers)} → {len(unique)} (排除 {duplicates} 篇重复)")

    if args.no_save:
        print("\n[试运行模式] 不保存文件。")
        for p in unique[:15]:
            print(f"  • {p['published']} [{p['query_name']}] {p['title'][:70]}")
    else:
        save_results(unique, query_stats)


if __name__ == "__main__":
    main()
