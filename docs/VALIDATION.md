# Phase 4 — Dual fidelity & validation baselines

## Goal

Keep **analytical (fast / differentiable)** and **DES (accurate)** on the same
topology, then establish external baselines:

| Baseline | What it checks | How to run |
|---|---|---|
| Dual fidelity | Same hop delays: prop-only vs DES under/overload | `demo_dual_fidelity()` |
| M/D/1 theory | Single-hop queue wait vs closed-form | `compare_to_md1(...)` |
| ns-3 scenario JSON | Portable DropTail multi-hop case | `export_ns3_scenario(...)` |
| GMAT orbit | `propagate_eci_rv` ECI state vs `GMAT.PropSetup` | `scripts/validate_phase4.jl` |

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

## Orbit cross-check

Use **`propagate_eci_rv`** (meters / m/s) for the initial state — do **not**
assume circular `√(μ/a)`. Walker elements use `e≈0.001`, which shifts `|v|` by
~O(100 m/s) and previously produced ~km-level false disagreement.

| Compare | Expected |
|---|---|
| GMAT `GravityField(degree=0)` vs Orbit TwoBody | **~0 m** (pass/fail gate, `<1 m` over 10 min) |
| GMAT `GravityField(degree=2)` vs Orbit J2 | O(km) baseline — analytical J2 forms differ |
| Orbit TwoBody vs Orbit J2 | O(km) over 10 min (perturbation sanity) |

```bash
julia --project=. test/test_orbit_gmat_align.jl
julia --project=. scripts/validate_phase4.jl
```
