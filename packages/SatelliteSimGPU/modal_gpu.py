from pathlib import Path
import subprocess

import modal


PACKAGE_DIR = Path(__file__).resolve().parent
REMOTE_PACKAGE_DIR = "/opt/SatelliteSimGPU"
BACKENDS_DIR = PACKAGE_DIR.parent / "SatelliteSimBackends"
REMOTE_BACKENDS_DIR = "/opt/SatelliteSimBackends"

image = (
    modal.Image.from_registry(
        "ghcr.io/juliagpu/cuda.jl@sha256:8c40fadfbeea933b98e81a1b164cc3ccb8d442c6caf9e3285e4b577d30d5dd13",
        add_python="3.12",
    )
    .entrypoint([])
    .add_local_dir(BACKENDS_DIR, REMOTE_BACKENDS_DIR, copy=True)
    .add_local_dir(PACKAGE_DIR, REMOTE_PACKAGE_DIR, copy=True)
)

app = modal.App("satellitesim-gpu-validation")


@app.function(
    image=image,
    gpu="A10G",
    cpu=2.0,
    memory=4096,
    timeout=20 * 60,
)
def validate_on_gpu() -> None:
    result = subprocess.run(
        [
            "julia",
            f"--project={REMOTE_PACKAGE_DIR}",
            f"{REMOTE_PACKAGE_DIR}/modal_gpu_runner.jl",
        ],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    print(result.stdout, end="")
    result.check_returncode()


@app.local_entrypoint()
def main() -> None:
    validate_on_gpu.remote()
