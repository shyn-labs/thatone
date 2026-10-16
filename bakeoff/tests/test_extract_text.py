from pathlib import Path

import pytest
from fpdf import FPDF
from PIL import Image, ImageDraw, ImageFont

from bakeoff.extract_text import chunk_text, extract_code, extract_doc, extract_image, extract_pdf
from bakeoff.sample import file_id
from bakeoff.segments import Segment


def entry(p: Path, kind: str) -> dict:
    return {"id": file_id(p), "path": str(p), "kind": kind}


def text_image(p: Path, text: str) -> Path:
    img = Image.new("RGB", (1200, 300), "white")
    ImageDraw.Draw(img).text((40, 100), text, fill="black", font=ImageFont.load_default(size=64))
    img.save(p)
    return p


def test_chunk_text_overlaps_and_covers():
    text = "".join(str(i % 10) for i in range(3000))
    chunks = chunk_text(text, size=1200, overlap=200)
    assert chunks[0][:2] == (0, 1200)
    assert chunks[1][0] == 1000
    assert chunks[-1][1] == 3000
    assert all(c[2] == text[c[0]:c[1]] for c in chunks)


def test_segment_round_trip():
    s = Segment("f:0", "f", "pdf", "text", {"page": 3}, text="hello")
    assert Segment.from_dict(s.to_dict()) == s


@pytest.mark.slow
def test_image_gets_image_and_ocr_segments(tmp_path):
    p = text_image(tmp_path / "shot.png", "INVOICE 4471")
    segs = extract_image(entry(p, "image"))
    mods = sorted(s.modality for s in segs)
    assert mods == ["image", "text"]
    txt = next(s for s in segs if s.modality == "text").text
    assert "4471" in txt
    img = next(s for s in segs if s.modality == "image")
    assert img.media == str(p) and "4471" in img.text  # OCR text kept for keyword search


@pytest.mark.slow
def test_blank_image_has_no_text_segment(tmp_path):
    p = tmp_path / "blank.png"
    Image.new("RGB", (400, 400), "white").save(p)
    segs = extract_image(entry(p, "image"))
    assert [s.modality for s in segs] == ["image"]


@pytest.mark.slow
def test_textless_pdf_page_becomes_image(tmp_path):
    p = tmp_path / "mixed.pdf"
    pdf = FPDF()
    pdf.add_page()
    pdf.set_font("Helvetica", size=14)
    pdf.multi_cell(0, 10, text="The buffer pool deduction for this project is twenty percent. " * 3)
    pdf.add_page()  # blank page, like a scan with no text layer
    pdf.output(str(p))
    segs = extract_pdf(entry(p, "pdf"))
    page1 = [s for s in segs if s.anchor == {"page": 1}]
    page2 = [s for s in segs if s.anchor == {"page": 2}]
    assert [s.modality for s in page1] == ["text"] and "buffer pool" in page1[0].text
    assert [s.modality for s in page2] == ["image"] and Path(page2[0].media).is_file()


def test_doc_with_unicode_path(tmp_path):
    p = tmp_path / "ಟಿಪ್ಪಣಿ notes.md"
    p.write_text("Biochar trial notes from Bihar.\n" * 100, encoding="utf-8")
    segs = extract_doc(entry(p, "doc"))
    assert segs and all(s.modality == "text" for s in segs)
    assert segs[0].anchor["char0"] == 0 and "Biochar" in segs[0].text


def test_doc_rtf_via_textutil(tmp_path):
    p = tmp_path / "memo.rtf"
    p.write_text(r"{\rtf1\ansi Carbon credits memo for Kheti.}", encoding="utf-8")
    segs = extract_doc(entry(p, "doc"))
    assert "Kheti" in segs[0].text


def test_code_line_windows(tmp_path):
    p = tmp_path / "x.py"
    p.write_text("\n".join(f"line_{i} = {i}" for i in range(1, 131)), encoding="utf-8")
    segs = extract_code(entry(p, "code"))
    assert segs[0].anchor == {"line0": 1, "line1": 60}
    assert segs[1].anchor == {"line0": 41, "line1": 100}
    assert segs[-1].anchor["line1"] == 130
    assert segs[0].text.startswith("line_1 = 1")
