# Phase 4 — Dual fidelity & validation baselines

## Goal

Keep **analytical (fast / differentiable)** and **DES (accurate)** on the same
topology, then establish external baselines:

| Baseline | What it checks | How to run |
|---|---|---|
| Dual fidelity | Same hop delays: prop-only vs DES under/overload | `demo_dual_fidelity()` |
| M/D/1 theory | Single-hop queue wait vs closed-form | `compare_to_md1(...)` |
| ns-3 scenario JSON | Portable DropTail multi-hop case | `export_ns3_scenario(...)` |
| GMAT orbit | `propagate_positions` ECI vs `GMAT.PropSetup` | `scripts/validate_phase4.jl` |

## Architecture rule

DES never enters the AD / `optimize_coverage` path. Dual fidelity is an
**evaluation** tool: analytical for optimization, DES for high-fidelity check.

## Quick demos

```julia
using SatelliteSimJulia
demo_dual_fidelity()
```

Full harness (needs GMAT + constellation stack):

```bash
julia --project=. scripts/validate_phase4.jl
```

Writes (gitignored under `data/`):

- `data/validation/ns3_scenario_iridium.json`
- `data/validation/phase4_report.txt`

## ns-3 comparison recipe

1. Export scenario JSON from Julia (`export_ns3_scenario` / validate script).
2. In ns-3: build a `PointToPoint` chain with the same `hop_prop_ms`, `rate_bps`,
   DropTail `max_packets`, CBR/Poisson load, and packet size.
3. Compare mean e2e latency and drop ratio to `simulate_path` on the same inputs.

## Expected dual-fidelity signature

On a loaded path (load > rate):

- Analytical: only Σ prop delay
- DES underload: mean latency ≈ prop + Σ transmission, **drops ≈ 0**, `aligned=true`
- DES overload: **drop > 0**, queue delay > 0, mean latency > analytical

## Orbit note

GMAT and `SatelliteSimOrbit` share a circular LEO initial state in ECI for the
harness. Frame / force-model differences can produce large meter-level drift;
the report records the delta as a **baseline**, not a pass/fail gate.
`Orbit TwoBody vs J2` drift is the in-package sanity check.
