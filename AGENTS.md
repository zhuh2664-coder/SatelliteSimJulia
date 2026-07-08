# AGENTS.md

## Cursor Cloud specific instructions

SatelliteSimJulia is a Julia (≥1.12) LEO satellite-constellation simulation platform: an
aggregate package (`SatelliteSimJulia`) that re-exports ~12 local subpackages under `src/*`
(foundation/orbit/link/net/metrics/traffic/opt/lab/core/viz/…). Julia is installed via
`juliaup` (`$HOME/.juliaup/bin/julia`); the update script runs `Pkg.instantiate()` on the
root project.

- **Julia version**: subpackages pin `julia = "1.12"` (see `src/foundation/Project.toml`).
  Use the `1.12` channel; other majors will fail to resolve.
- **No committed `Manifest.toml`**: it is gitignored, so the environment resolves purely from
  each `Project.toml` `[sources]` (local path deps). A cold `Pkg.instantiate()` +
  precompile is heavy (Makie/CairoMakie/Flux/Lux/OrdinaryDiffEq) and can take several minutes;
  this is normal, not a hang.
- **Run the app** (no external data/keys needed):
  `julia --project=. -e 'using SatelliteSimJulia; demo()'`. Higher-level entry points:
  `run_examples()`, `agent_repl(LLMProvider())` (AI REPL, needs `DEEPSEEK_API_KEY`),
  `optimize_coverage(loss, x0)`.
- **`ExperimentConfig` keyword API** uses `topology_strategy=` and `routing_algorithm=`
  (the README's `topology=`/`routing=` keywords are outdated and will `MethodError`).
- **Tests**: full `julia --project=. -e 'using Pkg; Pkg.test()'` currently errors at
  `test/runtests.jl:23` because `supports_orbit_elements` is defined in `src/orbit` but never
  exported into the aggregate namespace (`isdefined(SatelliteSimJulia, :supports_orbit_elements)`
  is `false`). This is a pre-existing source/test mismatch, not an environment problem.
  Individual test files run fine against the instantiated root project, e.g.
  `julia --project=. test/test_metrics.jl` or `julia --project=. test/test_topology_strategies.jl`.
- `test/Project.toml` adds `GLMakie` (needs a display); `runtests.jl` guards it behind
  `HAS_GLMAKIE`, so its absence only skips Makie-related testsets.

### Experiment / regression scripts (`scripts/`)

- Numerical experiment scripts run against the root project and all pass:
  `julia --project=. scripts/probe_e2e.jl` (Core bare-array pipeline; note the 24/6 case
  yields 0 usable ISL by design — too sparse — while the Iridium 66/6 case gives ~91/132),
  `scripts/probe_opt.jl` and `scripts/verify_end_to_end_gradient.jl` (three-way
  Forward/Reverse/finite-diff gradient agreement), and `scripts/smoke_core_net_lab_experiment.jl`
  (full Lab experiment).
- `julia --project=. scripts/run_regression.jl` is the unified regression entry (quick_validate
  + integration_test + smoke + probe_e2e + probe_opt). `integration_test.jl` does
  `Pkg.activate("src/lab")`, so the `src/lab` subproject must be instantiated first
  (`julia --project=src/lab -e 'using Pkg; Pkg.instantiate()'`) or that line fails; once done,
  the suite reports 5/5.
- `scripts/viz_demo.jl` currently errors in `SatelliteSimViz` `draw_coastlines!`
  (`src/viz/src/earth.jl`): it iterates a `GeometryBasics.MultiLineString`, which the resolved
  GeometryBasics/Makie version no longer supports. This is a viz-only (auxiliary) API-drift bug,
  independent of the core simulation pipeline.
