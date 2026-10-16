import sys
from pathlib import Path

import numpy as np
import pytest

from bakeoff.client import SidecarClient, SidecarError
from bakeoff.index import embed_segments, load_index, save_index
from bakeoff.segments import Segment

FAKE = [sys.executable, str(Path(__file__).parent / "fake_worker.py")]


def seg(i, modality, text="", media=""):
    return Segment(f"f{i}:0", f"f{i}", "image", modality, {}, text=text, media=media)


def test_client_info_and_embed():
    with SidecarClient(FAKE) as c:
        assert c.info()["dim"] == 16
        v = c.embed("text", "query", ["red planet", "blue planet"])
        assert v.shape == (2, 16)
        np.testing.assert_allclose(np.linalg.norm(v, axis=1), 1.0, rtol=1e-5)


def test_client_raises_protocol_errors():
    with SidecarClient(FAKE) as c:
        with pytest.raises(SidecarError) as e:
            c.embed("text", "document", ["bad one"])
        assert e.value.code == "input_error"
        assert c.embed("text", "document", ["fine"]).shape == (1, 16)  # still usable


def test_worker_death_raises():
    with SidecarClient(FAKE, env={"FAKE_DIE_AFTER": "1"}) as c:
        c.embed("text", "document", ["one"])
        with pytest.raises(SidecarError) as e:
            c.embed("text", "document", ["two"])
        assert e.value.code == "worker_exited"


def test_bad_item_isolated():
    segs = [seg(i, "text", text=f"doc {i}") for i in range(5)]
    segs[2] = seg(2, "text", text="bad doc")
    with SidecarClient(FAKE) as c:
        r = embed_segments(c, segs, batch=4)
    assert r.ids["text"] == ["f0:0", "f1:0", "f3:0", "f4:0"]
    assert r.vectors["text"].shape == (4, 16)
    assert [f["seg_id"] for f in r.failed] == ["f2:0"]


def test_unsupported_modality_skipped():
    segs = [seg(0, "text", text="hello"), seg(1, "audio", media="/a.wav")]
    with SidecarClient(FAKE, env={"FAKE_NO_AUDIO": "1"}) as c:
        r = embed_segments(c, segs)
    assert r.skipped_modalities == ["audio"]
    assert "audio" not in r.vectors and r.ids["text"] == ["f0:0"]


def test_media_used_for_image_and_save_load():
    segs = [seg(0, "image", text="ocr words", media="/pics/a.png")]
    with SidecarClient(FAKE) as c:
        r = embed_segments(c, segs)
        expected = c.embed("image", "document", ["/pics/a.png"])
    np.testing.assert_allclose(r.vectors["image"], expected)
    save_index("fake", r)
    back = load_index("fake")
    assert back.ids == r.ids and back.failed == r.failed
    np.testing.assert_allclose(back.vectors["image"], r.vectors["image"])


def test_unsupported_after_first_batch_is_item_failure():
    segs = [seg(0, "audio", media="/a.wav"), seg(1, "audio", media="/x-unsup.wav"), seg(2, "audio", media="/c.wav")]
    with SidecarClient(FAKE) as c:
        r = embed_segments(c, segs, batch=1)
    assert r.skipped_modalities == []
    assert r.ids["audio"] == ["f0:0", "f2:0"]
    assert [f["seg_id"] for f in r.failed] == ["f1:0"]


def test_worker_crash_restarts_and_isolates_item():
    segs = [seg(i, "text", text=f"doc {i}") for i in range(4)]
    segs[1] = seg(1, "text", text="killme now")
    restarts = []

    def restart():
        restarts.append(1)
        return SidecarClient(FAKE)

    with SidecarClient(FAKE) as c:
        r = embed_segments(c, segs, batch=4, restart=restart)
    assert r.ids["text"] == ["f0:0", "f2:0", "f3:0"]
    assert [f["seg_id"] for f in r.failed] == ["f1:0"]
    assert len(restarts) == 2  # once for the batch, once for the killer item


def test_index_records_segments_digest():
    from bakeoff.index import check_digest
    with SidecarClient(FAKE) as c:
        r = embed_segments(c, [seg(0, "text", text="hello")])
    save_index("d", r, digest="abc")
    back = load_index("d")
    assert back.digest == "abc"
    check_digest(back, "abc")
    with pytest.raises(ValueError):
        check_digest(back, "other")


def test_worker_env_is_offline():
    from bakeoff.models import worker_env
    env = worker_env("gemma", offline=True)
    assert env["HF_HUB_OFFLINE"] == "1" and env["UV_OFFLINE"] == "1"
    assert "HF_HUB_OFFLINE" not in worker_env("gemma", offline=False)
