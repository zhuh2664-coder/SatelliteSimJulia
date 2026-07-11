# Backend Integration and Independent-Implementation Validation Record

> Date: 2026-07-09
> Branch observed: `refactor/v2-architecture`
> Purpose: retain concise, reviewable engineering evidence for each substantive step. This is not a roadmap and does not replace `CURRENT.md` or `docs/design/dependency-isolation.md`.

## Target acceptance criteria

1. Native, Stub, and JuliaSpace use the same high-level `run_experiment(config)` entry.
2. Link, Net, and Traffic do not depend on a concrete backend package.
3. Backend positions flow directly into GSL, ISL, routing, and Traffic AON.
4. Three-dimensional `Array` and `SubArray` inputs are end-to-end equivalent.
5. Cross-implementation numerical error tests and a performance-baseline script exist.
6. `scripts/test_all.jl` reports zero failed targets.
7. Dependency-boundary and Manifest-baseline gates pass.

## Recording convention

Each step records:

- files inspected or changed;
- exact validation command or equivalent evidence;
- observed result;
- completion conclusion and remaining uncertainty.

Raw package logs, generated data, credentials, and temporary manifests are not copied into this document.

## Step 1 — Re-audit the claimed cross-implementation evidence

### Inspected

- `packages/SatelliteSimJuliaSpaceBackend/src/SatelliteSimJuliaSpaceBackend.jl`
- `packages/SatelliteSimJuliaSpaceBackend/Project.toml`
- `src/orbit/src/propagator_two_body.jl`
- `src/orbit/Project.toml`
- `test/backends/test_backend_end_to_end.jl`
- `packages/SatelliteSimJuliaSpaceBackend/test/runtests.jl`

### Evidence

The current JuliaSpace method calls the Native Orbit facade directly:

```julia
positions = propagate_to_ecef(elements, times; propagator=backend.propagator, kwargs...)
```

The Native Orbit implementation itself uses `SatelliteToolbox.Propagators` for TwoBody/J2/J4.

### Conclusion

The existing `0 km` comparison proves backend dispatch plus frame/unit/shape/time-order adaptation, but it does **not** prove agreement between independent propagation implementations. Acceptance criterion 5 therefore remains incomplete under a strict audit.

## Step 2 — Discover an independent implementation path

### Commands/evidence

Inspected locally available `SatelliteToolbox` and repository propagation implementations. `SatelliteToolbox` exports TwoBody/J2/J4 propagators, but Native already wraps those exact propagators, so calling them directly from JuliaSpace would still compare the same physical implementation.

The repository also contains independent numerical-force-model work under GMAT, but coupling the JuliaSpace backend to that optional package would blur package ownership and backend meaning.

### Decision

Implement a self-contained JuliaSpace propagation path behind `SatelliteSimBackends` rather than delegating to `SatelliteSimOrbit.propagate_to_ecef`. It must preserve the ECEF-km `(satellite,time,xyz)` contract and support the declared `:two_body`, `:j2`, and `:j4` selections. Error thresholds will be derived from measured differences and documented per propagator; they will not be silently retained at `0 km`.

### Status

In progress.

## Step 3 — Make the validation record version-visible

### Changed

- `.gitignore`
- `docs/audits/2026-07-09_backend_integration_validation.md`

### Reason

The repository broadly ignores new Markdown files under `docs/`. A narrow exception was added for this single evidence record so that each subsequent engineering step is visible in `git status` and can be reviewed with the implementation. No other archived or generated documents were unignored.

### Validation

```text
git status --short --untracked-files=all
?? docs/audits/2026-07-09_backend_integration_validation.md
```

### Status

Complete.

## Step 4 — Inspect Native J4 wrapper semantics

### Inspected

- `~/.julia/packages/SatelliteToolboxPropagators/H7jNz/src/api/j4.jl`
- `~/.julia/packages/SatelliteToolboxPropagators/H7jNz/src/propagators/j4.jl`
- `src/orbit/src/propagator_two_body.jl`
- `packages/SatelliteSimJuliaSpaceBackend/src/SatelliteSimJuliaSpaceBackend.jl`

### Evidence

`Propagators.init(Val(:J4), orb₀)` calls `j4_init(orb₀; j4c=j4c)` directly and wraps the returned state. `j4_init!` assigns both `j4d.orb₀` and `j4d.orbk` to the supplied element set. The high-level wrapper does not invoke `fit_mean_elements`, perform an osculating-to-mean conversion, or otherwise adjust the input elements.

### Conclusion

The measured J4 rate discrepancy is not explained by Native wrapper element fitting. The next diagnostic must compare actual constants and individual secular-rate terms between the package-local implementation and SatelliteToolbox's initialized state. No threshold change is justified yet.

## Step 5 — Isolate the J4 discrepancy to Julia numeric-literal parsing

### Diagnostic commands/evidence

Compared the initialized Native state with an exact local transcription of SatelliteToolbox's J4 equations and printed each secular-rate term for a 550 km, 71° Walker element (`e = 0.001`). The exact transcription reproduced Native exactly:

```text
n̄  = 0.0010943101162149806
∂Ω = -4.899407978729303e-7
∂ω = -3.5464822850866567e-7
```

The package-local implementation instead used an ASCII variable named `e2` with expressions such as `4e2`, `12e2`, and `21e2`. In Julia, these tokens are parsed as scientific-notation literals (`400.0`, `1200.0`, and `2100.0`), not as numeric-literal multiplication by the variable `e2`. SatelliteToolbox's source uses the Unicode variable `e₀²`, for which juxtaposition has the intended multiplication meaning.

### Conclusion

The 0.363 km J4 difference was an implementation bug, not a legitimate model difference and not a wrapper semantic difference. The correct fix is to write all `e2` products explicitly (`4 * e2`, etc.), retain the strict cross-implementation threshold, and add a regression test that would fail if the scientific-notation parsing bug returns.

## Step 6 — Correct J4 products and re-establish numerical agreement

### Changed

- `packages/SatelliteSimJuliaSpaceBackend/src/SatelliteSimJuliaSpaceBackend.jl`

All products whose coefficient preceded the ASCII `e2` variable now use explicit multiplication, for example `4 * e2`, `12 * e2`, and `252 * e2`.

### Validation

```text
julia --project=packages/SatelliteSimJuliaSpaceBackend \
  -e 'using Pkg; Pkg.resolve(); Pkg.test(; coverage=false)'
SatelliteSimJuliaSpaceBackend: 15 passed, 0 failed
```

Independent-vs-Native comparison for 12 satellites, four times through 600 s:

```text
two_body max = 4.092726157978177e-12 km, rms = 9.706055961394775e-13 km
j2       max = 5.002220859751105e-12 km, rms = 1.5310982361359428e-12 km
j4       max = 5.4569682106375694e-12 km, rms = 1.7608665751361257e-12 km
```

The corrected independent J4 rates for the diagnostic element are:

```text
n̄  = 0.0010943101162149806
∂Ω = -4.899407978729303e-7
∂ω = -3.5464822850866567e-7
```

### Conclusion

The independent secular-element path now agrees with Native to floating-point roundoff for all three declared propagators. The existing `1e-3 km` acceptance budget remains conservative and does not need to be relaxed. Tests still need explicit implementation metadata and a focused J4-rate regression before this step is considered fully hardened.

## Step 7 — Harden tests and make benchmark metadata explicit

### Changed

- `packages/SatelliteSimJuliaSpaceBackend/test/runtests.jl`
- `test/backends/test_backend_end_to_end.jl`
- `scripts/benchmark_orbit_backends.jl`

The package test now asserts the independent implementation capability and result metadata, checks the selected frame transform, and includes version-locked J4 secular rates that specifically catch the `4e2` parsing regression. The E2E comparison now validates implementation metadata for every propagator. The benchmark CSV now includes an explicit `propagator` column and names its fixed `:two_body` workload in code.

### Validation

```text
SatelliteSimJuliaSpaceBackend: 22 passed, 0 failed
backend high-level entry:      41 passed, 0 failed
Array/SubArray E2E:            21 passed, 0 failed
cross-implementation error:     9 passed, 0 failed
```

Benchmark smoke completed successfully and emitted Native, Stub, and JuliaSpace rows with `propagator=two_body`, correct `6x3x3` shapes, elapsed time, allocated bytes, and JuliaSpace maximum error `4.09272615798e-12 km`.

### Conclusion

The independent-path claim is now checked at the capability, result-metadata, fixed-rate, and multi-satellite output levels. The performance baseline remains informational rather than a noisy latency gate, while retaining numerical and shape pass/fail checks.

## Step 8 — Correct public implementation claims

### Changed

- `README.md`
- `CURRENT.md`
- `docs/design/dependency-isolation.md`

### Corrections

The documents no longer say that JuliaSpace delegates to Native or that the observed error is exactly zero. They now state that JuliaSpace owns an independent `:two_body` / `:j2` / `:j4` secular-element code path, has no runtime dependency on `SatelliteSimOrbit`, and measured a `5.46e-12 km` maximum difference in the recorded 12-satellite/4-time comparison.

The dependency diagram now places JuliaSpace above `SatelliteSimBackends + SatelliteToolbox`, not Orbit. The limitation is also explicit: both paths use the same EGM2008 constants and analytical model family and share SatelliteToolbox's TEME→PEF transform, so this does not replace future validation against an independent high-fidelity numerical force model.

### Validation

`git diff --check` passed for all three documents, and a targeted search found no remaining claim that JuliaSpace reuses Native or that its cross-implementation error is `0 km`.

## Step 9 — Re-run dependency, Manifest, and backend-leakage gates

### Commands/results

```text
julia scripts/check_dependency_boundaries.jl
DEPENDENCY BOUNDARIES: PASS

julia scripts/check_manifest_baseline.jl
backends_stub: current 12, baseline 12, limit 14 — PASS
core:          current 139, baseline 139, limit 166 — PASS
root:          current 155, baseline 155, limit 186 — PASS
MANIFEST BASELINE: PASS

rg concrete backend names in src/link src/net src/traffic
BACKEND LEAKAGE: PASS (no matches)
```

### Conclusion

The JuliaSpace runtime dependency change did not violate package direction or local-source rules, did not grow tracked Manifest baselines, and did not leak concrete backend names into Link, Net, or Traffic.

## Step 10 — Run the unified nightly backend slice

### Command/result

```text
SATSIM_RUN_NIGHTLY=1 \
SATSIM_TEST_ONLY=juliaspace-backend,backend-e2e,backend-benchmark \
julia --project=. scripts/test_all.jl

SUMMARY: 3 passed, 0 failed, 18 skipped
```

The selected targets were `juliaspace-backend`, `backend-e2e`, and `backend-benchmark`; all three passed through the repository's unified test runner.

### Conclusion

The independent implementation, full downstream E2E, and benchmark smoke are wired correctly into the nightly selection rather than only passing as ad hoc commands.

## Step 11 — Run the default unified verification

### Command/result

```text
julia --project=. scripts/test_all.jl
SUMMARY: 14 passed, 0 failed, 7 skipped
```

The passing default targets included dependency boundaries, Manifest baseline, core smoke, bare-array, Foundation, Orbit, Link, Metrics, Net, Traffic, root regression, Lab, backend contract, and Stub backend. Optional and nightly-only targets were skipped by their documented environment switches.

### Conclusion

The backend changes preserve the repository's required zero-failure default verification result.

## Step 12 — Synchronize validation counts in current documentation

### Changed

- `README.md`
- `CURRENT.md`
- `docs/design/dependency-isolation.md`

The package-level JuliaSpace count is now `22/22`, reflecting capability/metadata and J4 parsing regressions. The backend E2E count is now `71/71`: high-level entry `41`, Array/SubArray chain `21`, and cross-implementation checks `9`. Default and nightly unified-runner counts remain `14 passed, 0 failed, 7 skipped` and `3 passed, 0 failed, 18 skipped`, respectively.

## Step 13 — Final workspace and configuration review

### Checks/results

```text
JuliaSpace runtime/test dependency split: PASS
Nightly workflow YAML parse:           PASS
git diff --check:                      PASS
package-local Manifest ignored:        PASS
envs/backends-integration Manifest:    ignored as intended
```

The final dependency check confirms that `SatelliteSimOrbit` is absent from JuliaSpace runtime `[deps]`, remains a test-only extra with an explicit local `[sources]` path, and `SatelliteToolbox` is the runtime dependency. No package-local or integration-environment temporary Manifest is exposed for commit.

The workspace still contains unrelated concurrent platform and optimization work. It was not reset, deleted, or rewritten as part of this validation.

## Final acceptance status

| Criterion | Evidence |
|---|---|
| Native, Stub, JuliaSpace share `run_experiment(config)` | E2E `41/41` |
| Link/Net/Traffic do not depend on concrete backends | dependency gate and targeted leakage search pass |
| Backend positions enter GSL/ISL/routing/Traffic AON | E2E high-level and direct downstream assertions pass |
| Three-dimensional Array/SubArray equivalence | E2E `21/21` |
| Real cross-implementation error test | independent package-local equations; E2E cross-check `9/9`; maximum `5.46e-12 km` |
| Performance baseline | three-backend smoke CSV with explicit propagator, shape, elapsed, allocations, and error |
| Unified verification stays at zero failed | default `14/0/7`; nightly backend slice `3/0/18` |
| Dependency and Manifest gates | both pass |

All requested acceptance criteria have local evidence. No claim is made that GitHub-hosted Actions have run, and no claim is made that the analytical implementations are validated against a high-fidelity numerical truth model.
