"""Real-model smoke test. Run with RUN_MODEL_TESTS=1. Downloads the model on first run."""
import json
import os
import subprocess
import sys
from pathlib import Path

import numpy as np
import pytest
from PIL import Image

from thatone_protocol import decode_vectors

pytestmark = pytest.mark.skipif(os.environ.get("RUN_MODEL_TESTS") != "1", reason="real model")
WORKER = Path(__file__).resolve().parents[1] / "worker.py"


@pytest.fixture(scope="module")
def worker():
    p = subprocess.Popen([sys.executable, str(WORKER)], stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, text=True)
    n = iter(range(1, 10_000))

    def call(**req):
        req["id"] = next(n)
        p.stdin.write(json.dumps(req) + "\n")
        p.stdin.flush()
        resp = json.loads(p.stdout.readline())
        assert resp["id"] == req["id"]
        return resp

    yield call
    p.stdin.close()
    p.wait(timeout=30)


def vecs(resp):
    assert resp["ok"], resp
    return decode_vectors(resp["vectors_b64"], resp["count"], resp["dim"])


def test_info(worker):
    r = worker(op="info")
    assert r["ok"] and r["dim"] == 768


def test_text_ranks_relevant_doc_first(worker):
    q = vecs(worker(op="embed", modality="text", role="query",
                    inputs=["Which planet is known as the Red Planet?"]))
    d = vecs(worker(op="embed", modality="text", role="document",
                    inputs=["Mars is known as the Red Planet.", "Venus is often called Earth's twin."]))
    assert d.shape == (2, 768)
    s = (q @ d.T)[0]
    assert s[0] > s[1]


def test_text_query_matches_image(worker, tmp_path):
    red, blue = tmp_path / "red.png", tmp_path / "blue.png"
    Image.new("RGB", (256, 256), (220, 20, 20)).save(red)
    Image.new("RGB", (256, 256), (20, 40, 220)).save(blue)
    imgs = vecs(worker(op="embed", modality="image", role="document", inputs=[str(red), str(blue)]))
    q = vecs(worker(op="embed", modality="text", role="query", inputs=["a plain red square"]))
    s = (q @ imgs.T)[0]
    assert s[0] > s[1]


def test_audio_supported_or_cleanly_unsupported(worker, tmp_path):
    aiff = tmp_path / "speech.aiff"
    subprocess.run(["say", "-o", str(aiff), "the buffer pool is twenty percent"], check=True)
    r = worker(op="embed", modality="audio", role="document", inputs=[str(aiff)])
    if r["ok"]:
        assert vecs(r).shape == (1, 768)
    else:
        assert r["error"]["code"] == "unsupported_modality", r
    print("AUDIO:", "supported" if r["ok"] else r["error"]["message"])


def test_corrupt_image_is_input_error(worker, tmp_path):
    bad = tmp_path / "bad.png"
    bad.write_bytes(b"not a png")
    r = worker(op="embed", modality="image", role="document", inputs=[str(bad)])
    assert not r["ok"] and r["error"]["code"] == "input_error"


def test_audio_batch_returns_one_vector_per_clip(worker, tmp_path):
    a, b = tmp_path / "a.aiff", tmp_path / "b.aiff"
    subprocess.run(["say", "-o", str(a), "tractor in the rice field"], check=True)
    subprocess.run(["say", "-o", str(b), "invoice number forty four"], check=True)
    r = worker(op="embed", modality="audio", role="document", inputs=[str(a), str(b)])
    assert vecs(r).shape == (2, 768)


def test_exif_orientation_applied(worker, tmp_path):
    # A portrait photo stored sideways with EXIF orientation 6 must embed like its upright version.
    upright = Image.new("RGB", (200, 400), (240, 240, 240))
    for y in range(0, 120):
        for x in range(200):
            upright.putpixel((x, y), (200, 30, 30))
    up_path, tagged_path = tmp_path / "up.jpg", tmp_path / "tagged.jpg"
    upright.save(up_path)
    exif = Image.Exif()
    exif[0x0112] = 6  # rotate 90 CW on display
    upright.rotate(90, expand=True).save(tagged_path, exif=exif)
    v = vecs(worker(op="embed", modality="image", role="document", inputs=[str(up_path), str(tagged_path)]))
    assert float(v[0] @ v[1]) > 0.98
