"""No-model tests for the Qwen worker's image preparation."""
import sys
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from worker import MAX_SIDE, prepare_image  # noqa: E402


def test_large_photo_is_downscaled(tmp_path):
    src = tmp_path / "big.jpg"
    Image.new("RGB", (4000, 3000), (10, 120, 30)).save(src)
    out = Path(prepare_image(str(src), tmp_path / "prep"))
    w, h = Image.open(out).size
    assert max(w, h) == MAX_SIDE and abs(w / h - 4000 / 3000) < 0.01


def test_small_photo_is_not_upscaled(tmp_path):
    src = tmp_path / "small.jpg"
    Image.new("RGB", (300, 200), (10, 120, 30)).save(src)
    assert Image.open(prepare_image(str(src), tmp_path / "prep")).size == (300, 200)


def test_exif_rotation_applied(tmp_path):
    src = tmp_path / "tagged.jpg"
    exif = Image.Exif()
    exif[0x0112] = 6  # stored 400x200, displays as 200x400
    Image.new("RGB", (400, 200), (200, 30, 30)).save(src, exif=exif)
    assert Image.open(prepare_image(str(src), tmp_path / "prep")).size == (200, 400)


def test_unreadable_image_raises_input_error(tmp_path):
    import pytest
    from thatone_protocol import ProtocolError
    bad = tmp_path / "bad.png"
    bad.write_bytes(b"nope")
    with pytest.raises(ProtocolError) as e:
        prepare_image(str(bad), tmp_path / "prep")
    assert e.value.code == "input_error"


class FakeTok:
    """One token per whitespace-separated word."""
    def encode(self, text, add_special_tokens=False):
        return text.split()

    def decode(self, ids):
        return " ".join(ids)


def test_long_text_truncated_to_token_limit():
    from worker import truncate_text
    out = truncate_text("w " * 5000, FakeTok(), max_tokens=100)
    assert len(out.split()) == 100


def test_short_text_untouched():
    from worker import truncate_text
    assert truncate_text("a short passage", FakeTok(), max_tokens=100) == "a short passage"
