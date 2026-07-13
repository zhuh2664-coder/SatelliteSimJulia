#!/usr/bin/env python3
"""Network-free contracts for the Modal GPU validation harness."""

from __future__ import annotations

import ast
from pathlib import Path
import unittest


PACKAGE_DIR = Path(__file__).resolve().parents[1]
LAUNCHER_PATH = PACKAGE_DIR / "modal_gpu.py"
RUNNER_PATH = PACKAGE_DIR / "modal_gpu_runner.jl"
LAUNCHER_SOURCE = LAUNCHER_PATH.read_text(encoding="utf-8")
RUNNER_SOURCE = RUNNER_PATH.read_text(encoding="utf-8")
LAUNCHER_TREE = ast.parse(LAUNCHER_SOURCE, filename=str(LAUNCHER_PATH))


def _python_function(name: str):
    node = next(
        item
        for item in LAUNCHER_TREE.body
        if isinstance(item, (ast.FunctionDef, ast.AsyncFunctionDef))
        and item.name == name
    )
    module = ast.Module(body=[node], type_ignores=[])
    ast.fix_missing_locations(module)
    namespace: dict[str, object] = {}
    exec(compile(module, str(LAUNCHER_PATH), "exec"), namespace)
    return namespace[name]


def _function_source(name: str) -> str:
    node = next(
        item
        for item in LAUNCHER_TREE.body
        if isinstance(item, (ast.FunctionDef, ast.AsyncFunctionDef))
        and item.name == name
    )
    source = ast.get_source_segment(LAUNCHER_SOURCE, node)
    if source is None:
        raise AssertionError(f"source unavailable for {name}")
    return source


def _assigned_literal(name: str):
    node = next(
        item
        for item in LAUNCHER_TREE.body
        if isinstance(item, ast.Assign)
        and any(isinstance(target, ast.Name) and target.id == name for target in item.targets)
    )
    return ast.literal_eval(node.value)


class SentinelContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.suite_passed = _python_function("_suite_passed")
        self.suite = "sgp4_cuda"
        self.sentinel = (
            "MODAL_GPU_VALIDATION status=PASS suite=sgp4_cuda"
        )

    def test_accepts_one_matching_final_sentinel(self) -> None:
        stdout = f"SUITE_BEGIN name={self.suite}\n{self.sentinel}\n"
        self.assertTrue(self.suite_passed(0, stdout, self.suite))

    def test_rejects_nonzero_exit(self) -> None:
        self.assertFalse(self.suite_passed(1, self.sentinel, self.suite))

    def test_rejects_wrong_suite(self) -> None:
        wrong = "MODAL_GPU_VALIDATION status=PASS suite=coverage_f64"
        self.assertFalse(self.suite_passed(0, wrong, self.suite))

    def test_rejects_sentinel_substring(self) -> None:
        stdout = f"prefix {self.sentinel}\n"
        self.assertFalse(self.suite_passed(0, stdout, self.suite))

    def test_rejects_duplicate_sentinels(self) -> None:
        stdout = f"{self.sentinel}\n{self.sentinel}\n"
        self.assertFalse(self.suite_passed(0, stdout, self.suite))

    def test_rejects_output_after_sentinel(self) -> None:
        stdout = f"{self.sentinel}\nlate output\n"
        self.assertFalse(self.suite_passed(0, stdout, self.suite))

    def test_rejects_other_validation_sentinel(self) -> None:
        wrong = "MODAL_GPU_VALIDATION status=FAIL suite=sgp4_cuda"
        stdout = f"{wrong}\n{self.sentinel}\n"
        self.assertFalse(self.suite_passed(0, stdout, self.suite))


class StaticHarnessContractTests(unittest.TestCase):
    def test_launcher_uses_pinned_a10g_image(self) -> None:
        image = (
            "ghcr.io/juliagpu/cuda.jl@sha256:"
            "8c40fadfbeea933b98e81a1b164cc3ccb8d442c6caf9e3285e4b577d30d5dd13"
        )
        self.assertEqual(LAUNCHER_SOURCE.count(image), 1)
        self.assertIn('gpu="A10G"', LAUNCHER_SOURCE)

    def test_gpu_runner_is_offline_and_two_threaded(self) -> None:
        source = _function_source("_run_julia_suite")
        for fragment in (
            'env["JULIA_NUM_THREADS"] = "2"',
            'env["JULIA_LOAD_PATH"] = "@:@stdlib"',
            'env["JULIA_PKG_OFFLINE"] = "true"',
            '"--threads=2"',
        ):
            self.assertIn(fragment, source)

    def test_default_matrix_keeps_all_hardware_suites(self) -> None:
        expected = [
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
        self.assertEqual(_assigned_literal("DEFAULT_PARALLEL_SUITES"), expected)

    def test_runner_has_no_runtime_package_mutation(self) -> None:
        self.assertNotIn("Pkg.instantiate", RUNNER_SOURCE)
        self.assertNotIn("Pkg.add", RUNNER_SOURCE)

    def test_runtime_hardware_contract_is_fail_closed(self) -> None:
        for fragment in (
            'EXPECTED_GPU_NAMES = ("NVIDIA A10", "NVIDIA A10G")',
            "EXPECTED_GPU_CAPABILITY = (8, 6)",
            "MIN_GPU_MEMORY_BYTES = 20 * 2^30",
            "Threads.nthreads() == EXPECTED_JULIA_THREADS",
            "device_name in EXPECTED_GPU_NAMES",
            "actual_capability == EXPECTED_GPU_CAPABILITY",
            "total_memory >= MIN_GPU_MEMORY_BYTES",
        ):
            self.assertIn(fragment, RUNNER_SOURCE)

    def test_relative_error_rejects_nonfinite_values(self) -> None:
        self.assertIn(
            "(isfinite(a) && isfinite(b)) || return Inf",
            RUNNER_SOURCE,
        )
        self.assertIn("isfinite(d) || return Inf", RUNNER_SOURCE)

    def test_every_benchmark_parity_is_guarded_before_output(self) -> None:
        self.assertNotIn('"WARN"', RUNNER_SOURCE)
        guards_and_outputs = (
            ("coverage benchmark parity failed", '"BENCH op=coverage type='),
            ("GSL benchmark parity failed", '"BENCH op=gsl type='),
            ("ISL benchmark parity failed", '"BENCH op=isl type='),
            ("GSL reduction parity failed", '"BENCH op=gsl_reduction type='),
            ("ISL reduction parity failed", '"BENCH op=isl_reduction type='),
            ("real1584 GPU parity failed", '"BENCH op=coverage_real1584 mode=gpu'),
        )
        for guard, output in guards_and_outputs:
            with self.subTest(guard=guard):
                self.assertLess(
                    RUNNER_SOURCE.index(guard),
                    RUNNER_SOURCE.index(output),
                )

    def test_cuda_contract_checks_type_and_shape(self) -> None:
        for fragment in (
            "value isa CuArray",
            "eltype(value) == expected_eltype",
            "size(value) == expected_size",
        ):
            self.assertIn(fragment, RUNNER_SOURCE)

        for field in (
            "available",
            "distance_km",
            "delay_ms",
            "line_of_sight",
            "elevation_deg",
            "cos_psi",
            "duration_s",
        ):
            self.assertIn(f"(:{field},", RUNNER_SOURCE)

        for label in (
            "GSL visible-count reduction",
            "GSL station-ratio reduction",
            "ISL available-count reduction",
            "ISL pair-ratio reduction",
            "ISL degree reduction",
            "SGP4 CUDA positions",
            "SGP4 CUDA velocities",
            "SGP4 pipeline ISL",
        ):
            self.assertIn(label, RUNNER_SOURCE)


if __name__ == "__main__":
    unittest.main()
