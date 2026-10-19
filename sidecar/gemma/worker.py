"""EmbeddingGemma 2 sidecar worker. Speaks sidecar/protocol.md on stdio."""
import os
import subprocess
import sys

import mlx.core as mx
import numpy as np
from PIL import Image, ImageOps

from batching import MAX_TEXTS, TOKEN_BUDGET, plan_batches
from thatone_protocol import ProtocolError, serve

# MLX keeps freed GPU buffers in a cache for reuse and never hands them back on its own, so a
# worker that once ran a big batch stays big. The limit caps what that cache may hold while a
# request runs (buffers past it are freed instead of cached); release_cache() empties it after
# every request so an idle worker returns to roughly the model's own size.
CACHE_LIMIT_BYTES = 1 << 30


def release_cache() -> None:
    clear = getattr(mx, "clear_cache", None) or mx.metal.clear_cache
    clear()


MODEL_ID = os.environ.get("THATONE_GEMMA_MODEL", "mlx-community/embeddinggemma-2-8bit")
QUERY_PREFIX = "task: search result | query: "
DOC_PREFIX = "title: none | text: "
MAX_TEXT_TOKENS = 2048
AUDIO_RATE = 16000


def load_audio(path: str) -> np.ndarray:
    """Decode any audio file to mono float32 at 16 kHz via ffmpeg."""
    proc = subprocess.run(
        ["ffmpeg", "-nostdin", "-v", "error", "-i", path, "-ac", "1", "-ar", str(AUDIO_RATE),
         "-f", "f32le", "-"],
        capture_output=True,
    )
    if proc.returncode != 0:
        raise ProtocolError("input_error", f"ffmpeg failed on {path}: {proc.stderr.decode()[:200]}")
    return np.frombuffer(proc.stdout, dtype="<f4")


class GemmaBackend:
    def __init__(self):
        from mlx_vlm import load
        set_limit = getattr(mx, "set_cache_limit", None) or getattr(mx.metal, "set_cache_limit", None)
        if set_limit:
            set_limit(CACHE_LIMIT_BYTES)
        self.model, self.processor = load(MODEL_ID)
        self.tokenizer = getattr(self.processor, "tokenizer", self.processor)
        self.audio_kw = None  # discovered on first audio call: "audio" or "audios"
        print(f"loaded {MODEL_ID}", file=sys.stderr, flush=True)

    def info(self):
        return {"model": MODEL_ID, "dim": 768, "modalities": ["text", "image", "audio"]}

    def _run(self, inputs) -> np.ndarray:
        out = self.model(**{k: mx.array(v) for k, v in inputs.items()})
        emb = out.text_embeds.astype(mx.float32)
        mx.eval(emb)
        return np.array(emb)

    def embed(self, modality, role, inputs):
        try:
            return self._embed(modality, role, inputs)
        finally:
            release_cache()

    def _embed_text(self, role, inputs) -> np.ndarray:
        prefix = QUERY_PREFIX if role == "query" else DOC_PREFIX
        texts = [prefix + t for t in inputs]
        # Padding a batch to its longest text makes one long chunk cost every row that length, so
        # group by length and cap padded tokens per forward pass (see batching.py).
        ids = self.tokenizer(texts, truncation=True, max_length=MAX_TEXT_TOKENS)["input_ids"]
        out = np.zeros((len(texts), 768), dtype=np.float32)
        for group in plan_batches([len(x) for x in ids], TOKEN_BUDGET, MAX_TEXTS):
            enc = self.tokenizer([texts[i] for i in group], padding=True, truncation=True,
                                 max_length=MAX_TEXT_TOKENS, return_tensors="np")
            out[group] = self._run(dict(enc))
            release_cache()
        return out

    def _embed(self, modality, role, inputs):
        if modality == "text":
            return self._embed_text(role, inputs)
        if modality == "image":
            try:
                # Phone photos store rotation in EXIF; apply it so portraits aren't embedded sideways.
                images = [ImageOps.exif_transpose(Image.open(p)).convert("RGB") for p in inputs]
            except Exception as e:  # noqa: BLE001
                raise ProtocolError("input_error", f"cannot open image: {e}") from None
            # One inner list per document; a flat list means one document holding every image.
            return self._run(dict(self.processor(images=[[im] for im in images], return_tensors="np")))
        if modality == "audio":
            waves = [load_audio(p) for p in inputs]
            return self._run(self._audio_inputs(waves))
        raise ProtocolError("unsupported_modality", modality)

    def _audio_inputs(self, waves):
        kws = [self.audio_kw] if self.audio_kw else ["audio", "audios"]
        last = None
        for kw in kws:
            try:
                enc = self.processor(**{kw: waves}, sampling_rate=AUDIO_RATE, return_tensors="np")
                self.audio_kw = kw
                return dict(enc)
            except (TypeError, ValueError) as e:
                last = e
        if self.audio_kw:  # audio worked before, so this clip is the problem, not the modality
            raise ProtocolError("input_error", f"processor rejected clip: {last}")
        raise ProtocolError("unsupported_modality", f"processor rejected audio: {last}")


if __name__ == "__main__":
    serve(GemmaBackend())
