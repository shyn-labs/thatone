import json
import os
import subprocess

import numpy as np

from thatone_protocol import decode_vectors


class SidecarError(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(f"{code}: {message}")
        self.code = code
        self.message = message


class SidecarClient:
    def __init__(self, cmd: list[str], env: dict | None = None, cwd: str | None = None):
        self._proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                      text=True, env={**os.environ, **(env or {})}, cwd=cwd)
        self._next = 0

    def _call(self, req: dict) -> dict:
        self._next += 1
        req["id"] = self._next
        try:
            self._proc.stdin.write(json.dumps(req) + "\n")
            self._proc.stdin.flush()
        except BrokenPipeError:
            raise SidecarError("worker_exited", f"exit code {self._proc.poll()}") from None
        line = self._proc.stdout.readline()
        if not line:
            raise SidecarError("worker_exited", f"exit code {self._proc.wait()}")
        resp = json.loads(line)
        if not resp.get("ok"):
            err = resp.get("error", {})
            raise SidecarError(err.get("code", "internal"), err.get("message", ""))
        return resp

    def info(self) -> dict:
        return self._call({"op": "info"})

    def embed(self, modality: str, role: str, inputs: list[str]) -> np.ndarray:
        r = self._call({"op": "embed", "modality": modality, "role": role, "inputs": inputs})
        return decode_vectors(r["vectors_b64"], r["count"], r["dim"])

    def close(self) -> None:
        if self._proc.poll() is None:
            self._proc.stdin.close()
            try:
                self._proc.wait(timeout=30)
            except subprocess.TimeoutExpired:
                self._proc.kill()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
