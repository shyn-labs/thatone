"""Sidecar wire protocol v0. See sidecar/protocol.md."""
import base64
import json
import sys

import numpy as np

MODALITIES = ("text", "image", "audio")
ROLES = ("query", "document")


class ProtocolError(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


def encode_vectors(arr: np.ndarray) -> str:
    a = np.ascontiguousarray(arr, dtype="<f4")
    return base64.b64encode(a.tobytes()).decode("ascii")


def decode_vectors(b64: str, count: int, dim: int) -> np.ndarray:
    a = np.frombuffer(base64.b64decode(b64), dtype="<f4")
    if a.size != count * dim:
        raise ValueError(f"expected {count}x{dim} floats, got {a.size}")
    return a.reshape(count, dim).astype(np.float32)


def l2_normalize(arr: np.ndarray) -> np.ndarray:
    arr = np.asarray(arr, dtype=np.float32)
    norms = np.linalg.norm(arr, axis=1, keepdims=True)
    norms[norms == 0] = 1.0
    return arr / norms


def parse_request(line: str) -> dict:
    try:
        req = json.loads(line)
    except json.JSONDecodeError as e:
        raise ProtocolError("bad_request", f"invalid json: {e}") from None
    if not isinstance(req, dict) or not isinstance(req.get("id"), int):
        raise ProtocolError("bad_request", "missing integer id")
    op = req.get("op")
    if op == "info":
        return req
    if op != "embed":
        raise ProtocolError("bad_request", f"unknown op {op!r}")
    if req.get("modality") not in MODALITIES:
        raise ProtocolError("bad_request", f"unknown modality {req.get('modality')!r}")
    if req.get("role") not in ROLES:
        raise ProtocolError("bad_request", f"unknown role {req.get('role')!r}")
    inputs = req.get("inputs")
    if not isinstance(inputs, list) or not inputs or not all(isinstance(x, str) for x in inputs):
        raise ProtocolError("bad_request", "inputs must be a non-empty list of strings")
    return req


def serve(backend, stdin=sys.stdin, stdout=sys.stdout) -> None:
    for raw in stdin:
        line = raw.strip()
        if not line:
            continue
        rid = None
        try:
            req = parse_request(line)
            rid = req["id"]
            if req["op"] == "info":
                resp = {"id": rid, "ok": True, **backend.info()}
            else:
                vecs = l2_normalize(backend.embed(req["modality"], req["role"], req["inputs"]))
                resp = {"id": rid, "ok": True, "count": int(vecs.shape[0]),
                        "dim": int(vecs.shape[1]), "vectors_b64": encode_vectors(vecs)}
        except ProtocolError as e:
            resp = {"id": rid, "ok": False, "error": {"code": e.code, "message": e.message}}
        except Exception as e:  # noqa: BLE001 — every failure must become a response
            resp = {"id": rid, "ok": False,
                    "error": {"code": "internal", "message": f"{type(e).__name__}: {e}"}}
        stdout.write(json.dumps(resp) + "\n")
        stdout.flush()
