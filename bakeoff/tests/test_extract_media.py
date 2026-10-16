import subprocess
from pathlib import Path

import pytest

from bakeoff.extract_media import extract_audio, extract_video
from bakeoff.sample import file_id

pytestmark = pytest.mark.slow  # ffmpeg, say, whisper (downloads the model on first run)


def entry(p: Path, kind: str) -> dict:
    return {"id": file_id(p), "path": str(p), "kind": kind}


def speech(p: Path, text: str) -> Path:
    subprocess.run(["say", "-o", str(p), text], check=True)
    return p


def test_audio_clips_and_transcript(tmp_path):
    a = speech(tmp_path / "note.aiff", "The buffer pool deduction is twenty percent for this project.")
    segs = extract_audio(entry(a, "audio"))
    clips = [s for s in segs if s.modality == "audio"]
    text = [s for s in segs if s.modality == "text"]
    assert clips and Path(clips[0].media).is_file() and clips[0].anchor["t0"] == 0
    assert text and "buffer" in text[0].text.lower()


def test_silent_audio_has_no_transcript_segment(tmp_path):
    a = tmp_path / "silence.wav"
    subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "anullsrc=r=16000:cl=mono",
                    "-t", "5", str(a)], check=True)
    segs = extract_audio(entry(a, "audio"))
    assert [s.modality for s in segs] == ["audio"]


def test_video_frames_and_soundtrack(tmp_path):
    a = speech(tmp_path / "s.aiff", "Tractor field visit in Bihar.")
    v = tmp_path / "clip.mp4"
    subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "testsrc=size=320x240:rate=10",
                    "-i", str(a), "-af", "apad", "-t", "12", "-pix_fmt", "yuv420p", str(v)], check=True)
    segs = extract_video(entry(v, "video"), every=5)
    frames = [s for s in segs if s.modality == "image"]
    assert [f.anchor["t"] for f in frames][:2] == [0, 5]
    assert all(Path(f.media).is_file() for f in frames)
    assert any(s.modality == "audio" for s in segs)


def test_video_without_audio_track(tmp_path):
    v = tmp_path / "mute.mp4"
    subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "testsrc=size=320x240:rate=10",
                    "-t", "6", "-pix_fmt", "yuv420p", str(v)], check=True)
    segs = extract_video(entry(v, "video"), every=5)
    assert {s.modality for s in segs} == {"image"}
