import os
from pathlib import Path


def home() -> Path:
    default = Path.home() / "Library" / "Application Support" / "thatone-bakeoff"
    p = Path(os.environ.get("THATONE_BAKEOFF_HOME", default))
    p.mkdir(parents=True, exist_ok=True)
    return p


def _dir(name: str) -> Path:
    p = home() / name
    p.mkdir(parents=True, exist_ok=True)
    return p


def manifest_path() -> Path: return home() / "manifest.jsonl"
def segments_path() -> Path: return home() / "segments.jsonl"
def errors_path() -> Path: return home() / "errors.jsonl"
def media_dir() -> Path: return _dir("media")
def vectors_dir() -> Path: return _dir("vectors")
def results_dir() -> Path: return _dir("results")
