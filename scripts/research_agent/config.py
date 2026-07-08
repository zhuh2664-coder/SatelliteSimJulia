#!/usr/bin/env python3
"""Paths and default search queries for the research agent."""

from __future__ import annotations

import os
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_DIR = SCRIPT_DIR.parent.parent
STORE_DIR = Path(os.environ.get("SATSIM_RESEARCH_STORE", PROJECT_DIR / "research_store"))

PAPERS_JSONL = STORE_DIR / "papers.jsonl"
REPOS_JSONL = STORE_DIR / "repos.jsonl"
META_JSON = STORE_DIR / "meta.json"
RUNS_DIR = STORE_DIR / "runs"

ARXIV_API = "https://export.arxiv.org/api/query"
GITHUB_API = "https://api.github.com"

DEFAULT_PAPER_DAYS = 14
DEFAULT_PAPER_MAX_PER_QUERY = 40
DEFAULT_REPO_PER_PAGE = 30

# Reuse the same research axes as scripts/arxiv_collector.py (subset for agent MVP).
ARXIV_QUERIES = [
    {
        "id": "01_orbit",
        "name": "轨道传播",
        "query": (
            "(ti:satellite OR ti:constellation OR ti:LEO OR ti:orbit) "
            "AND (ti:propagation OR ti:SGP4 OR ti:J2 OR ti:two-body OR ti:Walker)"
        ),
        "categories": ["cs.NI", "astro-ph.EP", "astro-ph.IM", "eess.SP"],
    },
    {
        "id": "02_link",
        "name": "ISL/GSL 链路",
        "query": (
            '(ti:"inter-satellite link" OR ti:ISL OR ti:OISL OR ti:"laser link" '
            'OR ti:FSO OR ti:GSL OR ti:"rain attenuation") '
            "AND (ti:satellite OR ti:LEO OR ti:constellation)"
        ),
        "categories": ["cs.NI", "physics.optics", "astro-ph.IM"],
    },
    {
        "id": "03_topology",
        "name": "拓扑策略",
        "query": (
            '(ti:topology OR ti:"link assignment" OR ti:snapshot OR ti:connectivity) '
            "AND (ti:satellite OR ti:LEO OR ti:constellation OR ti:NTN)"
        ),
        "categories": ["cs.NI", "cs.IT"],
    },
    {
        "id": "04_routing",
        "name": "路由算法",
        "query": (
            "(ti:routing OR ti:CGR OR ti:DTN OR ti:multipath OR ti:SDN) "
            "AND (ti:satellite OR ti:LEO OR ti:constellation OR ti:NTN)"
        ),
        "categories": ["cs.NI", "cs.IT"],
    },
    {
        "id": "05_traffic",
        "name": "流量/容量/时延",
        "query": (
            "(ti:traffic OR ti:capacity OR ti:throughput OR ti:latency) "
            "AND (ti:satellite OR ti:LEO OR ti:constellation OR ti:Starlink)"
        ),
        "categories": ["cs.NI", "cs.IT", "cs.PF"],
    },
    {
        "id": "99_general",
        "name": "通用卫星仿真",
        "query": (
            '(ti:"satellite network" OR ti:"LEO constellation" OR ti:"mega-constellation" '
            'OR ti:"satellite simulation") '
            "AND (ti:simulation OR ti:emulation OR ti:network OR ti:performance)"
        ),
        "categories": ["cs.NI", "cs.PF"],
    },
]

GITHUB_QUERIES = [
    {
        "id": "sim_leo",
        "name": "LEO constellation simulation",
        "q": "LEO constellation simulation stars:>5",
    },
    {
        "id": "isl_routing",
        "name": "ISL / satellite routing",
        "q": "inter-satellite link OR satellite routing stars:>3",
    },
    {
        "id": "walker_sgp4",
        "name": "Walker / SGP4 tools",
        "q": "Walker constellation OR SGP4 satellite stars:>5",
    },
    {
        "id": "starlink_sim",
        "name": "Starlink / mega-constellation sim",
        "q": "Starlink simulation OR mega-constellation network stars:>5",
    },
    {
        "id": "julia_sat",
        "name": "Julia satellite tooling",
        "q": "satellite language:Julia stars:>1",
    },
]

USER_AGENT = "SatelliteSimJulia-ResearchAgent/0.1 (+local research store)"
