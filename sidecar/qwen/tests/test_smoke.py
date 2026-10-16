"""Real-model smoke test. Run with RUN_MODEL_TESTS=1."""
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest
from PIL import Image

from thatone_protocol import decode_vectors

pytestmark = pytest.mark.skipif(os.environ.get("RUN_MODEL_TESTS") != "1", reason="real model")
WORKER = Path(__file__).resolve().parents[1] / "worker.py"


def start(variant):
    env = {**os.environ, "THATONE_QWEN_VARIANT": variant}
    p = subprocess.Popen([sys.executable, str(WORKER)], stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, text=True, env=env)
    n = iter(range(1, 10_000))

    def call(**req):
        req["id"] = next(n)
        p.stdin.write(json.dumps(req) + "\n")
        p.stdin.flush()
        return json.loads(p.stdout.readline())

    return p, call


def vecs(r):
    assert r["ok"], r
    return decode_vectors(r["vectors_b64"], r["count"], r["dim"])


@pytest.mark.parametrize("variant,dim", [("vl", 2048), ("text", 1024)])
def test_text_ranking(variant, dim):
    p, call = start(variant)
    try:
        assert call(op="info")["dim"] == dim
        q = vecs(call(op="embed", modality="text", role="query", inputs=["Which planet is the Red Planet?"]))
        d = vecs(call(op="embed", modality="text", role="document",
                      inputs=["Mars is known as the Red Planet.", "Venus is often called Earth's twin."]))
        s = (q @ d.T)[0]
        assert s[0] > s[1]
        r = call(op="embed", modality="audio", role="document", inputs=["/nonexistent.wav"])
        assert r["error"]["code"] == "unsupported_modality"
    finally:
        p.stdin.close()
        p.wait(timeout=30)


def test_vl_image(tmp_path):
    red, blue = tmp_path / "red.png", tmp_path / "blue.png"
    Image.new("RGB", (256, 256), (220, 20, 20)).save(red)
    Image.new("RGB", (256, 256), (20, 40, 220)).save(blue)
    p, call = start("vl")
    try:
        imgs = vecs(call(op="embed", modality="image", role="document", inputs=[str(red), str(blue)]))
        q = vecs(call(op="embed", modality="text", role="query", inputs=["a plain red square"]))
        s = (q @ imgs.T)[0]
        assert s[0] > s[1]
    finally:
        p.stdin.close()
        p.wait(timeout=30)
