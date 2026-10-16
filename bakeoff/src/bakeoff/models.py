from pathlib import Path

from bakeoff.client import SidecarClient

SIDECAR = Path(__file__).resolve().parents[3] / "sidecar"


def _worker(project: str, env: dict) -> dict:
    proj = SIDECAR / project
    return {"cmd": ["uv", "run", "--project", str(proj), "python", str(proj / "worker.py")], "env": env}


MODELS = {
    "gemma": _worker("gemma", {}),
    "qwen-vl": _worker("qwen", {"THATONE_QWEN_VARIANT": "vl"}),
    "qwen-text": _worker("qwen", {"THATONE_QWEN_VARIANT": "text"}),
}


def offline_env() -> dict:
    return {"HF_HUB_OFFLINE": "1", "UV_OFFLINE": "1"}


def worker_env(name: str, offline: bool = True) -> dict:
    return {**MODELS[name]["env"], **(offline_env() if offline else {})}


def client_for(name: str, offline: bool = True) -> SidecarClient:
    return SidecarClient(MODELS[name]["cmd"], env=worker_env(name, offline))
