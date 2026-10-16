import subprocess
from pathlib import Path

import pypdfium2 as pdfium
from ocrmac import ocrmac

from bakeoff.paths import media_dir
from bakeoff.segments import Segment, make_seg_id

MIN_TEXT = 3
PDF_MIN_PAGE_TEXT = 40
CONVERT_EXTS = {".heic", ".tif", ".tiff", ".gif"}
CODE_WINDOW, CODE_STEP = 60, 40


def ocr_text(image_path: Path) -> str:
    return " ".join(t for t, _conf, _box in ocrmac.OCR(str(image_path)).recognize()).strip()


def _openable_image(path: Path, fid: str) -> Path:
    if path.suffix.lower() not in CONVERT_EXTS:
        return path
    out = media_dir() / f"{fid}.jpg"
    if not out.exists():
        subprocess.run(["sips", "-s", "format", "jpeg", str(path), "--out", str(out)],
                       check=True, capture_output=True)
    return out


def _image_segments(fid: str, kind: str, img: Path, anchor: dict, start: int) -> list[Segment]:
    text = ocr_text(img)
    segs = [Segment(make_seg_id(fid, start), fid, kind, "image", anchor, text=text, media=str(img))]
    if len(text.strip()) >= MIN_TEXT:
        segs.append(Segment(make_seg_id(fid, start + 1), fid, kind, "text", anchor, text=text))
    return segs


def extract_image(entry: dict) -> list[Segment]:
    img = _openable_image(Path(entry["path"]), entry["id"])
    return _image_segments(entry["id"], "image", img, {}, 0)


def extract_pdf(entry: dict, max_pages: int = 50) -> list[Segment]:
    fid, segs = entry["id"], []
    pdf = pdfium.PdfDocument(entry["path"])
    try:
        for i in range(min(len(pdf), max_pages)):
            page = pdf[i]
            text = page.get_textpage().get_text_range().strip()
            anchor = {"page": i + 1}
            if len(text) >= PDF_MIN_PAGE_TEXT:
                segs.append(Segment(make_seg_id(fid, len(segs)), fid, "pdf", "text", anchor, text=text))
            else:
                out = media_dir() / f"{fid}-p{i + 1}.png"
                page.render(scale=1.5).to_pil().save(out)
                segs += _image_segments(fid, "pdf", out, anchor, len(segs))
    finally:
        pdf.close()
    return segs


def chunk_text(text: str, size: int = 1200, overlap: int = 200) -> list[tuple[int, int, str]]:
    chunks, start = [], 0
    while start < len(text):
        end = min(start + size, len(text))
        chunks.append((start, end, text[start:end]))
        if end == len(text):
            break
        start = end - overlap
    return chunks


def _read_doc(path: Path) -> str:
    if path.suffix.lower() in {".txt", ".md"}:
        return path.read_text(encoding="utf-8", errors="replace")
    proc = subprocess.run(["textutil", "-convert", "txt", "-stdout", str(path)],
                          capture_output=True, check=True)
    return proc.stdout.decode("utf-8", errors="replace")


def extract_doc(entry: dict) -> list[Segment]:
    fid, text = entry["id"], _read_doc(Path(entry["path"]))
    return [Segment(make_seg_id(fid, n), fid, "doc", "text", {"char0": a, "char1": b}, text=t)
            for n, (a, b, t) in enumerate(c for c in chunk_text(text) if len(c[2].strip()) >= MIN_TEXT)]


def extract_code(entry: dict) -> list[Segment]:
    fid = entry["id"]
    lines = Path(entry["path"]).read_text(encoding="utf-8", errors="replace").splitlines()
    segs, start = [], 0
    while start < len(lines):
        end = min(start + CODE_WINDOW, len(lines))
        body = "\n".join(lines[start:end])
        if len(body.strip()) >= MIN_TEXT:
            segs.append(Segment(make_seg_id(fid, len(segs)), fid, "code", "text",
                                {"line0": start + 1, "line1": end}, text=body))
        if end == len(lines):
            break
        start += CODE_STEP
    return segs
