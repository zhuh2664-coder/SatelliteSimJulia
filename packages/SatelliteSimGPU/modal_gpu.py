"""Modal A10G runner for SatelliteSimGPU suites.

Usage:
  MODAL_PROFILE=satsim-gpu modal run modal_gpu.py
      # parallel default suites (≈20 GPU jobs)
  MODAL_PROFILE=satsim-gpu modal run modal_gpu.py --suites coverage_f64,sgp4_cuda
  MODAL_PROFILE=satsim-gpu modal run modal_gpu.py --suites full
"""

from __future__ import annotations

from pathlib import Path
import subprocess
from typing import Any

import modal


PACKAGE_DIR = Path(__file__).resolve().parent
REMOTE_PACKAGE_DIR = "/opt/SatelliteSimGPU"
BACKENDS_DIR = PACKAGE_DIR.parent / "SatelliteSimBackends"
REMOTE_BACKENDS_DIR = "/opt/SatelliteSimBackends"

# Parallel default matrix: correctness shards + new SGP4/reduction + per-op benches.
DEFAULT_PARALLEL_SUITES = [
    "smoke_info",
    "coverage_f64",
    "coverage_f32",
    "gsl_canonical_f64",
    "gsl_canonical_f32",
    "gsl_f64",
    "gsl_f32",
    "isl_f64",
    "isl_f32",
    "registered_f64",
    "registered_f32",
    "pipeline_adjoint",
    "reductions_f64",
    "reductions_f32",
    "sgp4_cuda",
    "bench_coverage",
    "bench_gsl",
    "bench_isl",
    "bench_gsl_reduction",
    "bench_isl_reduction",
]

image = (
    modal.Image.from_registry(
        "ghcr.io/juliagpu/cuda.jl@sha256:8c40fadfbeea933b98e81a1b164cc3ccb8d442c6caf9e3285e4b577d30d5dd13",
        add_python="3.12",
    )
    .entrypoint([])
    .add_local_dir(BACKENDS_DIR, REMOTE_BACKENDS_DIR, copy=True)
    .add_local_dir(PACKAGE_DIR, REMOTE_PACKAGE_DIR, copy=True)
    # SGP4 CUDA parity suite needs SatelliteToolboxSgp4 as the host golden.
    .run_commands(
        "julia --project=/opt/SatelliteSimGPU -e '"
        "using Pkg; "
        "Pkg.instantiate(); "
        "Pkg.add(\"SatelliteToolboxSgp4\"); "
        "Pkg.precompile()'"
    )
)

app = modal.App("satellitesim-gpu-validation")


@app.function(
    image=image,
    gpu="A10G",
    cpu=2.0,
    memory=4096,
    timeout=20 * 60,
)
def validate_suite(suite: str) -> dict[str, Any]:
    result = subprocess.run(
        [
            "julia",
            f"--project={REMOTE_PACKAGE_DIR}",
            f"{REMOTE_PACKAGE_DIR}/modal_gpu_runner.jl",
            suite,
        ],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    stdout = result.stdout or ""
    print(f"===== SUITE {suite} exit={result.returncode} =====")
    print(stdout, end="" if stdout.endswith("\n") else "\n")
    return {
        "suite": suite,
        "exit_code": result.returncode,
        "stdout": stdout,
        "pass": result.returncode == 0
        and "MODAL_GPU_VALIDATION status=PASS" in stdout,
    }


def _parse_suites(suites: str | None) -> list[str]:
    if suites is None or suites.strip() == "" or suites.strip().lower() == "parallel":
        return list(DEFAULT_PARALLEL_SUITES)
    items = [item.strip() for item in suites.split(",") if item.strip()]
    if not items:
        raise SystemExit("no suites provided")
    return items


@app.local_entrypoint()
def main(suites: str = "parallel") -> None:
    suite_list = _parse_suites(suites)
    print(f"Submitting {len(suite_list)} Modal GPU suites in parallel:")
    for name in suite_list:
        print(f"  - {name}")

    results = list(validate_suite.map(suite_list))

    print("\n===== PARALLEL SUITE SUMMARY =====")
    failed: list[str] = []
    for item in results:
        status = "PASS" if item["pass"] else "FAIL"
        print(f"{status}  suite={item['suite']}  exit={item['exit_code']}")
        if not item["pass"]:
            failed.append(item["suite"])

    print(
        f"TOTAL={len(results)} PASS={len(results) - len(failed)} FAIL={len(failed)}"
    )
    if failed:
        raise SystemExit(f"failed suites: {','.join(failed)}")
