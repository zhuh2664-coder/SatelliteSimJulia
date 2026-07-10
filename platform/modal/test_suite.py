"""Run precompiled, parallel SatelliteSimJulia test suites on Modal.

Usage: modal run platform/modal/test_suite.py --suite focused|full|current
"""

import os
import subprocess
import time
from pathlib import Path

import modal


REMOTE_REPOSITORY = "/opt/SatelliteSimJulia"
JULIA_VERSION = "1.12.6"
REPOSITORY = (
    Path(__file__).resolve().parents[2]
    if modal.is_local()
    else Path(REMOTE_REPOSITORY)
)

SUITES = {
    "focused": (
        (
            "xvfb-run",
            "-a",
            "julia",
            "--check-bounds=yes",
            "--project=.",
            "-e",
            'using SatelliteSimTraffic: TrafficDemand; include("test/test_precomposed_fixes.jl")',
        ),
        (
            "xvfb-run",
            "-a",
            "julia",
            "--check-bounds=yes",
            "--project=.",
            "src/link/test/runtests.jl",
        ),
    ),
    "full": (
        (
            "xvfb-run",
            "-a",
            "julia",
            "--check-bounds=yes",
            "--project=.",
            "-e",
            "using Pkg; Pkg.test()",
        ),
    ),
    "current": (
        (
            "xvfb-run",
            "-a",
            "julia",
            "--check-bounds=yes",
            "--project=.",
            "-e",
            'ENV["SATSIM_RUN_CURRENT"]="1"; using Pkg; Pkg.test()',
        ),
    ),
}

image = (
    modal.Image.debian_slim(python_version="3.11")
    .apt_install(
        "ca-certificates",
        "curl",
        "libgl1",
        "libx11-6",
        "libxcursor1",
        "libxi6",
        "libxinerama1",
        "libxkbcommon0",
        "libxrandr2",
        "xauth",
        "xvfb",
    )
    .run_commands(
        f"curl -fsSL https://julialang-s3.julialang.org/bin/linux/x64/1.12/julia-{JULIA_VERSION}-linux-x86_64.tar.gz -o /tmp/julia.tar.gz",
        f"tar -xzf /tmp/julia.tar.gz -C /opt",
        f"ln -s /opt/julia-{JULIA_VERSION}/bin/julia /usr/local/bin/julia",
        "rm /tmp/julia.tar.gz",
    )
    .add_local_dir(
        REPOSITORY,
        remote_path=REMOTE_REPOSITORY,
        copy=True,
        ignore=(
            ".git/**",
            "**/.git/**",
            "**/Manifest.toml",
            "**/__pycache__/**",
            "**/*.log",
            "**/*.out",
            ".github/**",
            "artifacts/**",
            "assets/**",
            "benchmark/**",
            "benchmark_suite/**",
            "build/**",
            "data/**",
            "devin_*",
            "docs/**",
            "godot-sandbox/**",
            "packages/**",
            "outputs/**",
            "platform/**",
            "simulation/**",
            "unity-scripts/**",
        ),
    )
    .run_commands(
        f"xvfb-run -a julia --check-bounds=yes --project={REMOTE_REPOSITORY} -e 'using Pkg; Pkg.instantiate(); Pkg.precompile()'",
        env={
            "JULIA_CPU_TARGET": "generic",
            "JULIA_NUM_PRECOMPILE_TASKS": "16",
            "JULIA_PKG_PRECOMPILE_AUTO": "0",
        },
    )
    .add_local_file(
        REPOSITORY / "platform/modal/precompile_test_env.jl",
        remote_path="/opt/precompile_test_env.jl",
        copy=True,
    )
    .run_commands(
        "xvfb-run -a julia --check-bounds=yes /opt/precompile_test_env.jl",
        env={
            "JULIA_CPU_TARGET": "generic",
            "JULIA_NUM_PRECOMPILE_TASKS": "16",
            "JULIA_PKG_PRECOMPILE_AUTO": "0",
            "SATSIM_REPOSITORY": REMOTE_REPOSITORY,
        },
    )
)

app = modal.App("satsim-julia-test-suite")


@app.function(
    image=image,
    cpu=16,
    memory=32768,
    timeout=3600,
)
def run_test_command(command: tuple[str, ...]) -> dict[str, float | str]:
    env = os.environ.copy()
    env["JULIA_CPU_TARGET"] = "generic"
    env["JULIA_NUM_THREADS"] = "16"
    env["JULIA_PKG_PRECOMPILE_AUTO"] = "0"
    started_at = time.monotonic()
    subprocess.run(
        command,
        cwd=REMOTE_REPOSITORY,
        check=True,
        env=env,
    )
    return {
        "command": " ".join(command),
        "seconds": time.monotonic() - started_at,
    }


@app.local_entrypoint()
def main(suite: str = "full"):
    commands = SUITES.get(suite)
    if commands is None:
        choices = ", ".join(sorted(SUITES))
        raise ValueError(f"Unknown suite {suite!r}; choose one of: {choices}")

    for result in run_test_command.map(commands, order_outputs=False):
        print(f"{result['seconds']:.3f}s\t{result['command']}")
