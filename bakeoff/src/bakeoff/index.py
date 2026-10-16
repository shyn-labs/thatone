import hashlib
import json
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

import numpy as np

from bakeoff.client import SidecarClient, SidecarError
from bakeoff.paths import vectors_dir
from bakeoff.segments import Segment

MODALITY_ORDER = ("text", "image", "audio")


@dataclass
class IndexResult:
    ids: dict[str, list[str]] = field(default_factory=dict)
    vectors: dict[str, np.ndarray] = field(default_factory=dict)
    failed: list[dict] = field(default_factory=list)
    skipped_modalities: list[str] = field(default_factory=list)
    seconds: dict[str, float] = field(default_factory=dict)
    digest: str = ""


def _payload(s: Segment) -> str:
    return s.text if s.modality == "text" else s.media


class _Unsupported(Exception):
    pass


class _Embedder:
    """Wraps a client: restarts a dead worker (up to max_restarts) and closes the ones it started."""

    def __init__(self, client: SidecarClient, restart: Callable[[], SidecarClient] | None, max_restarts: int):
        self.client, self.restart, self.left, self.started = client, restart, max_restarts, []

    def call(self, mod: str, items: list[Segment]) -> np.ndarray:
        try:
            return self.client.embed(mod, "document", [_payload(s) for s in items])
        except SidecarError as e:
            if e.code == "worker_exited" and self.restart and self.left > 0:
                self.left -= 1
                self.client = self.restart()
                self.started.append(self.client)
            raise

    def close(self):
        for c in self.started:
            c.close()


def embed_segments(client: SidecarClient, segments: list[Segment], batch: int = 16,
                   restart: Callable[[], SidecarClient] | None = None, max_restarts: int = 3) -> IndexResult:
    r = IndexResult()
    emb = _Embedder(client, restart, max_restarts)
    try:
        for mod in MODALITY_ORDER:
            group = [s for s in segments if s.modality == mod]
            if not group:
                continue
            t0, ids, rows = time.perf_counter(), [], []
            try:
                for i in range(0, len(group), batch):
                    chunk = group[i:i + batch]
                    try:
                        rows.append(emb.call(mod, chunk))
                        ids += [s.seg_id for s in chunk]
                        continue
                    except SidecarError as e:
                        if e.code == "unsupported_modality" and not ids:
                            raise _Unsupported() from None  # rejected before any success: modality skipped
                        if e.code == "worker_exited" and emb.client is client and not restart:
                            raise
                    for s in chunk:  # isolate the bad item
                        try:
                            rows.append(emb.call(mod, [s]))
                            ids.append(s.seg_id)
                        except SidecarError as e1:
                            if e1.code == "worker_exited" and emb.left <= 0 and emb.restart:
                                raise
                            r.failed.append({"seg_id": s.seg_id, "code": e1.code, "message": e1.message})
            except _Unsupported:
                r.skipped_modalities.append(mod)
                continue
            r.seconds[mod] = time.perf_counter() - t0
            if ids:
                r.ids[mod] = ids
                r.vectors[mod] = np.concatenate(rows).astype(np.float32)
    finally:
        emb.close()
    return r


def segments_digest(path: Path) -> str:
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def check_digest(result: IndexResult, digest: str) -> None:
    if result.digest != digest:
        raise ValueError("index was built from a different segments.jsonl; re-run index for every model")


def save_index(name: str, result: IndexResult, digest: str = "") -> Path:
    path = vectors_dir() / f"{name}.npz"
    meta = {"ids": result.ids, "failed": result.failed, "skipped_modalities": result.skipped_modalities,
            "seconds": result.seconds, "digest": digest or result.digest}
    np.savez(path, meta=np.array(json.dumps(meta)),
             **{f"vec_{m}": v for m, v in result.vectors.items()})
    return path


def load_index(name: str) -> IndexResult:
    data = np.load(vectors_dir() / f"{name}.npz")
    meta = json.loads(str(data["meta"]))
    vectors = {k[4:]: data[k] for k in data.files if k.startswith("vec_")}
    return IndexResult(ids=meta["ids"], vectors=vectors, failed=meta["failed"],
                       skipped_modalities=meta["skipped_modalities"], seconds=meta["seconds"],
                       digest=meta.get("digest", ""))
