#!/usr/bin/env python3
"""论文格式作图：读取 run_study.jl 产出的 CSV，出 PDF+PNG。

研究 1：网络容量 下界(greedy) / 上界(max-flow) 随星座规模变化。
研究 2：AoN 准入控制 vs 基线（承载吞吐 / 最大链路利用率 / 阻塞率 vs offered load）。

用法：python3 plot_study.py
输出：figures/*.pdf 与 *.png（300 dpi）。
"""
import csv
import os

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")
FIG = os.path.join(HERE, "figures")
os.makedirs(FIG, exist_ok=True)

# ---- 论文级样式 ----
plt.rcParams.update({
    "font.family": "serif",
    "font.size": 11,
    "axes.labelsize": 12,
    "axes.titlesize": 12,
    "legend.fontsize": 10,
    "xtick.labelsize": 10,
    "ytick.labelsize": 10,
    "axes.grid": True,
    "grid.alpha": 0.3,
    "grid.linestyle": "--",
    "figure.dpi": 120,
    "lines.linewidth": 1.8,
    "lines.markersize": 5,
})

C_LOWER = "#1f77b4"
C_UPPER = "#d62728"
C_BASE = "#7f7f7f"
C_CA = "#2ca02c"


def read_csv(name):
    with open(os.path.join(DATA, name)) as f:
        return list(csv.DictReader(f))


def save(fig, stem):
    for ext in ("pdf", "png"):
        fig.savefig(os.path.join(FIG, f"{stem}.{ext}"), bbox_inches="tight", dpi=300)
    plt.close(fig)
    print(f"  → figures/{stem}.pdf / .png")


def fig_capacity_bounds():
    rows = read_csv("study1_capacity.csv")
    n = [int(r["n_sat"]) for r in rows]
    lo = [float(r["greedy_gbps"]) for r in rows]
    up = [float(r["maxflow_gbps"]) for r in rows]

    fig, ax = plt.subplots(figsize=(5.2, 3.6))
    ax.fill_between(n, lo, up, color=C_UPPER, alpha=0.12, label="Achievable range")
    ax.plot(n, up, "-s", color=C_UPPER, label="Max-flow upper bound")
    ax.plot(n, lo, "-o", color=C_LOWER, label="Greedy single-path lower bound")
    ax.set_xlabel("Constellation size (number of satellites)")
    ax.set_ylabel("Aggregate capacity (Gbps)")
    ax.set_title("Network capacity bounds vs. constellation size")
    ax.legend(frameon=False, loc="upper left")
    ax.set_ylim(bottom=0)
    save(fig, "fig1_capacity_bounds")


def fig_admission():
    rows = read_csv("study2_admission.csv")
    off = [float(r["offered_gbps"]) for r in rows]
    cb = [float(r["carried_base_gbps"]) for r in rows]
    cc = [float(r["carried_ca_gbps"]) for r in rows]
    mub = [float(r["maxutil_base"]) for r in rows]
    muc = [float(r["maxutil_ca"]) for r in rows]
    bb = [float(r["blocking_base"]) for r in rows]
    bc = [float(r["blocking_ca"]) for r in rows]

    # Fig 2: carried throughput vs offered load
    fig, ax = plt.subplots(figsize=(5.2, 3.6))
    ax.plot(off, off, ":", color="k", alpha=0.5, label="Offered (y = x)")
    ax.plot(off, cb, "-o", color=C_BASE, label="Baseline AoN")
    ax.plot(off, cc, "-s", color=C_CA, label="Capacity-aware AoN")
    ax.set_xlabel("Offered load (Gbps)")
    ax.set_ylabel("Carried throughput (Gbps)")
    ax.set_title("Carried throughput vs. offered load")
    ax.legend(frameon=False, loc="upper left")
    ax.set_ylim(bottom=0)
    save(fig, "fig2_carried_throughput")

    # Fig 3: max link utilization vs offered load
    fig, ax = plt.subplots(figsize=(5.2, 3.6))
    ax.axhline(1.0, color="k", ls="--", lw=1.2, alpha=0.7, label="Capacity limit (util = 1)")
    ax.plot(off, mub, "-o", color=C_BASE, label="Baseline AoN")
    ax.plot(off, muc, "-s", color=C_CA, label="Capacity-aware AoN")
    ax.set_xlabel("Offered load (Gbps)")
    ax.set_ylabel("Max ISL link utilization")
    ax.set_title("Peak link utilization vs. offered load")
    ax.legend(frameon=False, loc="upper left")
    ax.set_ylim(bottom=0)
    save(fig, "fig3_max_utilization")

    # Fig 4: blocking probability vs offered load
    fig, ax = plt.subplots(figsize=(5.2, 3.6))
    ax.plot(off, bb, "-o", color=C_BASE, label="Baseline AoN")
    ax.plot(off, bc, "-s", color=C_CA, label="Capacity-aware AoN")
    ax.set_xlabel("Offered load (Gbps)")
    ax.set_ylabel("Blocking probability")
    ax.set_title("Blocking probability vs. offered load")
    ax.legend(frameon=False, loc="upper left")
    ax.set_ylim(-0.02, 1.0)
    save(fig, "fig4_blocking")

    # Overview 2x2 (for quick sharing)
    fig, axs = plt.subplots(2, 2, figsize=(9.5, 7))
    a = axs[0, 0]
    a.plot(off, off, ":", color="k", alpha=0.5, label="Offered")
    a.plot(off, cb, "-o", color=C_BASE, label="Baseline")
    a.plot(off, cc, "-s", color=C_CA, label="Capacity-aware")
    a.set_xlabel("Offered load (Gbps)"); a.set_ylabel("Carried (Gbps)")
    a.set_title("(a) Carried throughput"); a.legend(frameon=False, fontsize=9); a.set_ylim(bottom=0)
    a = axs[0, 1]
    a.axhline(1.0, color="k", ls="--", lw=1.2, alpha=0.7, label="util = 1")
    a.plot(off, mub, "-o", color=C_BASE, label="Baseline")
    a.plot(off, muc, "-s", color=C_CA, label="Capacity-aware")
    a.set_xlabel("Offered load (Gbps)"); a.set_ylabel("Max utilization")
    a.set_title("(b) Peak link utilization"); a.legend(frameon=False, fontsize=9); a.set_ylim(bottom=0)
    a = axs[1, 0]
    a.plot(off, bb, "-o", color=C_BASE, label="Baseline")
    a.plot(off, bc, "-s", color=C_CA, label="Capacity-aware")
    a.set_xlabel("Offered load (Gbps)"); a.set_ylabel("Blocking probability")
    a.set_title("(c) Blocking probability"); a.legend(frameon=False, fontsize=9); a.set_ylim(-0.02, 1.0)
    a = axs[1, 1]
    rows1 = read_csv("study1_capacity.csv")
    n = [int(r["n_sat"]) for r in rows1]
    lo = [float(r["greedy_gbps"]) for r in rows1]
    up = [float(r["maxflow_gbps"]) for r in rows1]
    a.fill_between(n, lo, up, color=C_UPPER, alpha=0.12)
    a.plot(n, up, "-s", color=C_UPPER, label="Max-flow (upper)")
    a.plot(n, lo, "-o", color=C_LOWER, label="Greedy (lower)")
    a.set_xlabel("Constellation size"); a.set_ylabel("Aggregate capacity (Gbps)")
    a.set_title("(d) Capacity bounds"); a.legend(frameon=False, fontsize=9); a.set_ylim(bottom=0)
    fig.tight_layout()
    save(fig, "fig5_overview")


if __name__ == "__main__":
    print("作图中…")
    fig_capacity_bounds()
    fig_admission()
    print("完成。")
