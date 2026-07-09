"""面向 SatelliteSimJulia 的相关性过滤。"""

from __future__ import annotations

from typing import Any

P0_KEYWORDS = [
    "leo satellite network", "leo satellite networks", "satellite internet",
    "satellite network", "satellite networks", "mega-constellation",
    "starlink", "oneweb", "iridium", "inter-satellite", "inter satellite",
    "isl", "gsl", "satellite routing", "routing", "traffic engineering",
    "traffic prediction", "capacity", "latency", "handover", "handoff",
    "satellite simulation", "satellite emulation", "hypatia", "satgenpy",
]

P1_KEYWORDS = [
    "differentiable", "autodiff", "automatic differentiation", "gradient-based",
    "physics-informed", "pinn", "neural operator", "deeponet", "neural ode",
    "graph neural", "heterogeneous graph", "gnn", "orchestration",
    "large language", "llm", "ai agent", "autonomous agent",
    "congestion control", "tcp", "bbr", "quic",
]

P2_KEYWORDS = [
    "orbit propagation", "sgp4", "tle", "j2", "j4", "walker",
    "orbit determination", "gnss jammer", "geolocation", "free-space optical",
    "optical link", "laser link", "telecom network", "non-terrestrial network",
]

# 这些词通常会把 arXiv 查询带偏；若没有强卫星网络词，直接降为候选池。
EXCLUDE_KEYWORDS = [
    "exoplanet", "warm jupiter", "molecular", "quantum chemistry", "crystal",
    "protein", "galaxy", "cosmology", "stellar", "planetary system",
    "social simulation", "human movement", "zoned environments", "material",
    "band-gap", "molecule", "molecular systems",
]

STRONG_INCLUDE_KEYWORDS = [
    "leo satellite", "satellite network", "satellite internet", "starlink",
    "oneweb", "iridium", "inter-satellite", "satellite constellation",
    "mega-constellation", "non-terrestrial network", "satcom",
]


def filter_candidates(candidates: list[dict[str, Any]], min_score: float = 35.0) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """返回 accepted/rejected；rejected 会进入候选池而非主知识库。"""
    accepted: list[dict[str, Any]] = []
    rejected: list[dict[str, Any]] = []
    for candidate in candidates:
        item = dict(candidate)
        decision = evaluate_relevance(item, min_score=min_score)
        item.update(decision)
        if decision["accepted"]:
            item["status"] = "active"
            accepted.append(item)
        else:
            item["status"] = "ignored_candidate"
            rejected.append(item)
    return accepted, rejected


def evaluate_relevance(candidate: dict[str, Any], min_score: float = 35.0) -> dict[str, Any]:
    """给单篇论文做 P0/P1/P2 相关性判断。"""
    blob = _blob(candidate)
    p0 = _hits(blob, P0_KEYWORDS)
    p1 = _hits(blob, P1_KEYWORDS)
    p2 = _hits(blob, P2_KEYWORDS)
    excludes = _hits(blob, EXCLUDE_KEYWORDS)
    strong = _hits(blob, STRONG_INCLUDE_KEYWORDS)

    base = float(candidate.get("relevance_score") or 0) * 0.35 + float(candidate.get("actionability_score") or 0) * 0.25
    keyword_score = len(p0) * 18 + len(p1) * 12 + len(p2) * 8 + len(strong) * 10
    penalty = len(excludes) * 35
    score = max(0.0, min(100.0, base + keyword_score - penalty))

    if excludes and not strong:
        return {
            "accepted": False,
            "priority": "reject",
            "filter_score": score,
            "filter_reason": f"命中低相关关键词：{', '.join(excludes[:3])}",
            "matched_keywords": {"p0": p0, "p1": p1, "p2": p2, "exclude": excludes},
        }

    if p0:
        priority = "P0"
    elif p1:
        priority = "P1"
    elif p2 or strong:
        priority = "P2"
    else:
        priority = "candidate"

    has_project_keyword = bool(p0 or p1 or p2 or strong)
    accepted = has_project_keyword and score >= min_score
    if not has_project_keyword:
        reason = "未命中 LEO 网络/仿真/可微优化/PINN/LLM 编排等项目关键词，仅保留为候选。"
    elif score < min_score:
        reason = f"命中 {priority} 关键词，但过滤分 {score:.1f} 低于阈值 {min_score:.1f}，仅保留为候选。"
    else:
        reason = _reason(priority, p0, p1, p2, strong)
    return {
        "accepted": accepted,
        "priority": priority if accepted else "candidate",
        "filter_score": score,
        "filter_reason": reason,
        "matched_keywords": {"p0": p0, "p1": p1, "p2": p2, "exclude": excludes},
    }


def _blob(candidate: dict[str, Any]) -> str:
    parts = [
        candidate.get("title") or "",
        candidate.get("abstract") or candidate.get("summary") or "",
        candidate.get("section_name") or "",
        candidate.get("module") or "",
        " ".join(candidate.get("fields") or []),
        " ".join(candidate.get("categories") or []),
    ]
    return " ".join(parts).lower()


def _hits(blob: str, keywords: list[str]) -> list[str]:
    return [keyword for keyword in keywords if keyword in blob]


def _reason(priority: str, p0: list[str], p1: list[str], p2: list[str], strong: list[str]) -> str:
    if priority == "P0":
        return f"命中 P0 核心方向：{', '.join(p0[:3])}"
    if priority == "P1":
        return f"命中 P1 创新方向：{', '.join(p1[:3])}"
    if priority == "P2":
        hits = p2 or strong
        return f"命中 P2 支撑方向：{', '.join(hits[:3])}"
    return f"过滤分 {score:.1f} 低于阈值 {min_score:.1f}，仅保留为候选。"
