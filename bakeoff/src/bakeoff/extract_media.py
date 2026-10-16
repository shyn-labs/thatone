import subprocess
from pathlib import Path

from bakeoff.extract_text import MIN_TEXT, ocr_text
from bakeoff.paths import media_dir
from bakeoff.segments import Segment, make_seg_id

WINDOW, STEP = 30, 25
WHISPER_REPO = "mlx-community/whisper-large-v3-turbo"
SILENCE_DB = -50.0


def _ffprobe(path: Path, stream: str) -> str:
    proc = subprocess.run(["ffprobe", "-v", "error", "-select_streams", stream, "-show_entries",
                           "format=duration", "-of", "csv=p=0", str(path)], capture_output=True, text=True)
    return proc.stdout.strip()


def duration(path: Path) -> float:
    try:
        return float(_ffprobe(path, "a:0") or _ffprobe(path, "v:0") or 0)
    except ValueError:
        return 0.0


def has_audio(path: Path) -> bool:
    proc = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "a", "-show_entries",
                           "stream=index", "-of", "csv=p=0", str(path)], capture_output=True, text=True)
    return bool(proc.stdout.strip())


def _to_wav(src: Path, out: Path, start: float | None = None, length: float | None = None) -> Path:
    cmd = ["ffmpeg", "-nostdin", "-v", "error", "-y"]
    if start is not None:
        cmd += ["-ss", str(start)]
    cmd += ["-i", str(src)]
    if length is not None:
        cmd += ["-t", str(length)]
    subprocess.run(cmd + ["-vn", "-ac", "1", "-ar", "16000", str(out)], check=True)
    return out


def is_silent(wav: Path) -> bool:
    """Whisper invents text ("Thank you.") on silence, so silent audio is never transcribed."""
    proc = subprocess.run(["ffmpeg", "-nostdin", "-v", "info", "-i", str(wav), "-af", "volumedetect",
                           "-f", "null", "-"], capture_output=True, text=True)
    for line in proc.stderr.splitlines():
        if "max_volume:" in line:
            return float(line.split("max_volume:")[1].split("dB")[0].strip()) < SILENCE_DB
    return True


def transcribe(wav: Path) -> list[dict]:
    if is_silent(wav):
        return []
    import mlx_whisper
    result = mlx_whisper.transcribe(str(wav), path_or_hf_repo=WHISPER_REPO)
    return [{"start": float(s["start"]), "end": float(s["end"]), "text": s["text"].strip()}
            for s in result.get("segments", []) if s["text"].strip()]


def _audio_segments(fid: str, kind: str, src: Path, total: float, start_n: int) -> list[Segment]:
    full = _to_wav(src, media_dir() / f"{fid}-full.wav", length=total)
    words = transcribe(full)
    segs, n, t0 = [], start_n, 0.0
    while t0 < total:
        t1 = min(t0 + WINDOW, total)
        inside = " ".join(w["text"] for w in words if w["start"] < t1 and w["end"] > t0)
        clip = _to_wav(src, media_dir() / f"{fid}-{int(t0)}.wav", start=t0, length=t1 - t0)
        anchor = {"t0": round(t0, 1), "t1": round(t1, 1)}
        segs.append(Segment(make_seg_id(fid, n), fid, kind, "audio", anchor, text=inside, media=str(clip)))
        n += 1
        if len(inside.strip()) >= MIN_TEXT:
            segs.append(Segment(make_seg_id(fid, n), fid, kind, "text", anchor, text=inside))
            n += 1
        if t1 >= total:
            break
        t0 += STEP
    return segs


def extract_audio(entry: dict, max_seconds: int = 1800) -> list[Segment]:
    src = Path(entry["path"])
    total = min(duration(src), max_seconds)
    if total <= 0:
        return []
    return _audio_segments(entry["id"], "audio", src, total, 0)


def extract_video(entry: dict, every: int = 5, max_frames: int = 120) -> list[Segment]:
    fid, src = entry["id"], Path(entry["path"])
    pattern = media_dir() / f"{fid}-f%04d.jpg"
    subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-y", "-i", str(src), "-vf", f"fps=1/{every}",
                    "-frames:v", str(max_frames), "-q:v", "3", str(pattern)], check=True)
    segs = []
    for i, frame in enumerate(sorted(media_dir().glob(f"{fid}-f*.jpg"))):
        segs.append(Segment(make_seg_id(fid, len(segs)), fid, "video", "image", {"t": i * every},
                            text=ocr_text(frame), media=str(frame)))
    if has_audio(src):
        total = min(duration(src), max_frames * every)
        if total > 0:
            segs += _audio_segments(fid, "video", src, total, len(segs))
    return segs
