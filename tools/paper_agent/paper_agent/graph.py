"""LangGraph 日跑流程。"""

from __future__ import annotations

import json
import uuid
from pathlib import Path
from typing import Any, Callable

from .actions import propose_duplicate_actions
from .arxiv_source import discover_arxiv
from .config import PaperAgentConfig
from .db import PaperStore
from .fetcher import fetch_for_reading
from .git_pr import create_weekly_pr
from .llm import should_use_llm, summarize_paper
from .relevance_filter import filter_candidates
from .render import render_main_markdown, render_notes, render_weekly_report
from .scoring import score_candidate
from .semantic_scholar import SemanticScholarClient
from .state import PaperAgentState
from .util import canonical_id_for, json_dumps, today_utc, utc_now


def run_agent(config: PaperAgentConfig, mode: str) -> PaperAgentState:
    """运行 Agent。优先使用 LangGraph；缺依赖时退回顺序执行。"""
    store = PaperStore(config)
    config.ensure_dirs()
    run_id = store.start_run(mode, config.public_dict())
    state: PaperAgentState = {
        "run_id": run_id,
        "mode": mode,
        "today": today_utc(),
        "config": config.public_dict(),
        "candidates": [],
        "new_or_updated_paper_ids": [],
        "read_queue": [],
        "fetch_results": [],
        "read_results": [],
        "proposed_actions": [],
        "render_outputs": {},
        "errors": [],
        "stats": {},
    }
    try:
        runnable = _build_langgraph(config, store)
        if runnable is not None:
            state = runnable.invoke(state)  # type: ignore[assignment]
        else:
            state = _run_sequential(config, store, state)
        status = "success" if not state.get("errors") else "completed_with_errors"
        _write_run_summary(config, state)
        store.finish_run(run_id, status, state.get("stats") or {}, state.get("errors") or [], state.get("pr_url"))
        return state
    except Exception as exc:
        state.setdefault("errors", []).append({"stage": "run_agent", "error": str(exc)})
        _write_run_summary(config, state)
        store.finish_run(run_id, "failed", state.get("stats") or {}, state.get("errors") or [])
        raise


def _build_langgraph(config: PaperAgentConfig, store: PaperStore):
    try:
        from langgraph.graph import END, START, StateGraph  # type: ignore
    except Exception:
        return None

    builder = StateGraph(PaperAgentState)
    nodes: list[tuple[str, Callable[[PaperAgentState], PaperAgentState]]] = [
        ("init_db", lambda s: _init_db(store, s)),
        ("discover_arxiv", lambda s: _discover_arxiv(config, s)),
        ("discover_semantic_scholar", lambda s: _discover_semantic_scholar(config, s)),
        ("canonicalize_and_dedupe", _canonicalize_and_dedupe),
        ("score_and_route", lambda s: _score_and_route(config, s)),
        ("filter_relevance", lambda s: _filter_relevance(config, s)),
        ("persist_candidates", lambda s: _persist_candidates(store, s)),
        ("fetch_pdf_or_web", lambda s: _fetch_pdf_or_web(config, store, s)),
        ("read_with_llm", lambda s: _read_with_llm(config, store, s)),
        ("propose_deletions", lambda s: _propose_deletions(store, s)),
        ("maybe_weekly_report", lambda s: _maybe_weekly_report(config, store, s)),
        ("render_markdown", lambda s: _render_markdown(config, store, s)),
        ("maybe_create_pr", lambda s: _maybe_create_pr(config, s)),
    ]
    for name, fn in nodes:
        builder.add_node(name, fn)
    builder.add_edge(START, nodes[0][0])
    for (left, _), (right, _) in zip(nodes, nodes[1:]):
        builder.add_edge(left, right)
    builder.add_edge(nodes[-1][0], END)
    return builder.compile()


def _run_sequential(config: PaperAgentConfig, store: PaperStore, state: PaperAgentState) -> PaperAgentState:
    for fn in [
        lambda s: _init_db(store, s),
        lambda s: _discover_arxiv(config, s),
        lambda s: _discover_semantic_scholar(config, s),
        _canonicalize_and_dedupe,
        lambda s: _score_and_route(config, s),
        lambda s: _filter_relevance(config, s),
        lambda s: _persist_candidates(store, s),
        lambda s: _fetch_pdf_or_web(config, store, s),
        lambda s: _read_with_llm(config, store, s),
        lambda s: _propose_deletions(store, s),
        lambda s: _maybe_weekly_report(config, store, s),
        lambda s: _render_markdown(config, store, s),
        lambda s: _maybe_create_pr(config, s),
    ]:
        state = fn(state)
    return state


def _init_db(store: PaperStore, state: PaperAgentState) -> PaperAgentState:
    store.init_db()
    return state


def _discover_arxiv(config: PaperAgentConfig, state: PaperAgentState) -> PaperAgentState:
    try:
        candidates = discover_arxiv(config)
        state["candidates"] = candidates
        state.setdefault("stats", {})["arxiv_candidates"] = len(candidates)
    except Exception as exc:
        state.setdefault("errors", []).append({"stage": "discover_arxiv", "error": str(exc)})
    return state


def _discover_semantic_scholar(config: PaperAgentConfig, state: PaperAgentState) -> PaperAgentState:
    candidates = state.get("candidates") or []
    if not candidates:
        return state
    if not config.enable_semantic_scholar:
        state.setdefault("stats", {})["semantic_scholar_skipped"] = True
        return state
    try:
        client = SemanticScholarClient(config)
        enhanced = client.enhance_many(candidates)
        state["candidates"] = enhanced
        state.setdefault("stats", {})["semantic_scholar_checked"] = min(len(candidates), config.semantic_scholar_max)
    except Exception as exc:
        state.setdefault("errors", []).append({"stage": "discover_semantic_scholar", "error": str(exc)})
    return state


def _canonicalize_and_dedupe(state: PaperAgentState) -> PaperAgentState:
    seen: set[str] = set()
    deduped: list[dict[str, Any]] = []
    for candidate in state.get("candidates") or []:
        canonical_id = canonical_id_for(candidate)
        if canonical_id in seen:
            continue
        seen.add(canonical_id)
        item = dict(candidate)
        item["canonical_id"] = canonical_id
        deduped.append(item)
    state["candidates"] = deduped
    state.setdefault("stats", {})["deduped_candidates"] = len(deduped)
    return state


def _score_and_route(config: PaperAgentConfig, state: PaperAgentState) -> PaperAgentState:
    scored: list[dict[str, Any]] = []
    for candidate in state.get("candidates") or []:
        try:
            scored.append(score_candidate(candidate, config))
        except Exception as exc:
            item = dict(candidate)
            item.setdefault("source_errors", []).append({"stage": "score_and_route", "error": str(exc)})
            scored.append(item)
    scored.sort(key=lambda p: (p.get("actionability_score") or 0, p.get("relevance_score") or 0), reverse=True)
    state["candidates"] = scored[: config.max_metadata_ingest]
    state.setdefault("stats", {})["scored_candidates"] = len(state["candidates"])
    return state


def _filter_relevance(config: PaperAgentConfig, state: PaperAgentState) -> PaperAgentState:
    accepted, rejected = filter_candidates(state.get("candidates") or [], min_score=config.min_filter_score)
    state["candidates"] = accepted
    state["candidate_pool"] = rejected
    stats = state.setdefault("stats", {})
    stats["accepted_candidates"] = len(accepted)
    stats["candidate_pool"] = len(rejected)
    return state


def _persist_candidates(store: PaperStore, state: PaperAgentState) -> PaperAgentState:
    inserted_or_updated: list[str] = []
    inserted = 0
    all_candidates = list(state.get("candidates") or []) + list(state.get("candidate_pool") or [])
    for candidate in all_candidates:
        paper_id, was_inserted = store.upsert_paper(candidate, run_id=state["run_id"])
        if candidate.get("status") == "active":
            inserted_or_updated.append(paper_id)
        if was_inserted:
            inserted += 1
    state["new_or_updated_paper_ids"] = inserted_or_updated
    state.setdefault("stats", {})["persisted_candidates"] = len(all_candidates)
    state.setdefault("stats", {})["inserted_candidates"] = inserted
    return state


def _fetch_pdf_or_web(config: PaperAgentConfig, store: PaperStore, state: PaperAgentState) -> PaperAgentState:
    candidates = state.get("candidates") or []
    top = candidates[: max(config.max_llm_papers, 0)]
    results: list[dict[str, Any]] = []
    for candidate in top:
        result = fetch_for_reading(candidate, config)
        results.append(result)
        if result.get("pdf_path") or result.get("pdf_sha256"):
            merged = dict(candidate)
            merged.update({"pdf_path": result.get("pdf_path"), "pdf_sha256": result.get("pdf_sha256")})
            store.upsert_paper(merged)
    state["fetch_results"] = results
    state["read_queue"] = [r.get("paper_id") for r in results if r.get("paper_id")]
    state.setdefault("stats", {})["fetch_results"] = len(results)
    return state


def _read_with_llm(config: PaperAgentConfig, store: PaperStore, state: PaperAgentState) -> PaperAgentState:
    if not should_use_llm(config):
        state.setdefault("stats", {})["llm_skipped"] = True
        return state
    by_id = {c.get("canonical_id"): c for c in state.get("candidates") or []}
    read_results: list[dict[str, Any]] = []
    for idx, reading_input in enumerate(state.get("fetch_results") or []):
        if idx >= config.max_llm_papers:
            break
        paper_id = reading_input.get("paper_id")
        candidate = by_id.get(paper_id)
        if not paper_id or not candidate:
            continue
        try:
            read = summarize_paper(candidate, reading_input, config)
            if read:
                store.insert_read(paper_id, state["run_id"], read)
                read_results.append({"paper_id": paper_id, "model": read.get("model")})
        except Exception as exc:
            state.setdefault("errors", []).append({"stage": "read_with_llm", "paper_id": paper_id, "error": str(exc)})
    state["read_results"] = read_results
    state.setdefault("stats", {})["llm_reads"] = len(read_results)
    return state


def _propose_deletions(store: PaperStore, state: PaperAgentState) -> PaperAgentState:
    proposed = propose_duplicate_actions(store, state["run_id"])
    state["proposed_actions"] = proposed
    state.setdefault("stats", {})["proposed_actions"] = len(proposed)
    return state


def _render_markdown(config: PaperAgentConfig, store: PaperStore, state: PaperAgentState) -> PaperAgentState:
    main_path = render_main_markdown(config, store, run_id=state["run_id"])
    note_paths = render_notes(config, store, run_id=state["run_id"], limit=50)
    state.setdefault("render_outputs", {})["main_markdown"] = str(main_path)
    state.setdefault("render_outputs", {})["notes"] = [str(p) for p in note_paths]
    return state


def _maybe_weekly_report(config: PaperAgentConfig, store: PaperStore, state: PaperAgentState) -> PaperAgentState:
    if state.get("mode") not in {"weekly", "weekly_pr"}:
        return state
    report_path = render_weekly_report(config, store, run_id=state["run_id"])
    state["weekly_report_path"] = str(report_path)
    return state


def _maybe_create_pr(config: PaperAgentConfig, state: PaperAgentState) -> PaperAgentState:
    if state.get("mode") not in {"weekly_pr"}:
        return state
    report = state.get("weekly_report_path")
    if not report:
        state.setdefault("errors", []).append({"stage": "maybe_create_pr", "error": "缺少周报路径"})
        return state
    try:
        result = create_weekly_pr(config, Path(report), dry_run=config.dry_run)
        state.setdefault("render_outputs", {})["pr"] = result
        if result.get("pr_url"):
            state["pr_url"] = result["pr_url"]
    except Exception as exc:
        state.setdefault("errors", []).append({"stage": "maybe_create_pr", "error": str(exc)})
    return state


def _write_run_summary(config: PaperAgentConfig, state: PaperAgentState) -> None:
    config.runs_dir.mkdir(parents=True, exist_ok=True)
    path = config.runs_dir / f"{state['run_id']}.json"
    payload = {
        "run_id": state.get("run_id"),
        "mode": state.get("mode"),
        "finished_at": utc_now(),
        "stats": state.get("stats") or {},
        "errors": state.get("errors") or [],
        "render_outputs": state.get("render_outputs") or {},
    }
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
