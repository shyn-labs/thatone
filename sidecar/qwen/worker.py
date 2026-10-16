"""Qwen embedding sidecar worker (bake-off challenger). Speaks sidecar/protocol.md."""
import os
import sys

import mlx.core as mx
import numpy as np
import tempfile
from pathlib import Path

from PIL import Image, ImageOps

from thatone_protocol import ProtocolError, serve

VARIANT = os.environ.get("THATONE_QWEN_VARIANT", "vl")
VL_ID = "Qwen/Qwen3-VL-Embedding-2B"
TEXT_ID = "Qwen/Qwen3-Embedding-0.6B"
VL_INSTRUCTION = "Retrieve images or text relevant to the user's query."
MAX_TEXT_TOKENS = 2048  # same cap as the Gemma worker; one 25k-token PDF page needed 17 GB untruncated
MAX_SIDE = 1024      # Qwen3-VL reads images at native resolution; phone photos become thousands of tokens
IMAGE_BATCH = 4     # and 16 of them at once needed 17 GB, so images go through in small batches
TEXT_QUERY_PREFIX = "Instruct: Given a search query, retrieve relevant passages or files\nQuery: "


def truncate_text(text: str, tokenizer, max_tokens: int = MAX_TEXT_TOKENS) -> str:
    ids = tokenizer.encode(text, add_special_tokens=False)
    return text if len(ids) <= max_tokens else tokenizer.decode(ids[:max_tokens])


def prepare_image(path: str, out_dir) -> str:
    """Apply EXIF rotation and cap the long side at MAX_SIDE; returns the path to embed."""
    try:
        img = ImageOps.exif_transpose(Image.open(path)).convert("RGB")
    except Exception as e:  # noqa: BLE001
        raise ProtocolError("input_error", f"cannot open image {path}: {e}") from None
    img.thumbnail((MAX_SIDE, MAX_SIDE))  # keeps aspect ratio, never upscales
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    out = out_dir / f"{abs(hash(path))}.jpg"
    img.save(out, quality=92)
    return str(out)


class QwenBackend:
    def __init__(self):
        from huggingface_hub import snapshot_download
        from mlx_embeddings import load
        self.model_id = VL_ID if VARIANT == "vl" else TEXT_ID
        # mlx-embeddings' own download skips chat_template.jinja, which Qwen3-VL's processor needs.
        self.model, self.processor = load(snapshot_download(self.model_id))
        self.tmp = tempfile.mkdtemp(prefix="thatone-qwen-")
        print(f"loaded {self.model_id}", file=sys.stderr, flush=True)

    def _reset_rope_cache(self):
        # mlx-embeddings caches rope position ids across calls and only clears them for image
        # batches, so a later text batch reuses stale positions. Clear before every call.
        inner = getattr(self.model, "model", None)
        for obj in (self.model, inner, getattr(self.model, "language_model", None),
                    getattr(inner, "language_model", None)):
            if obj is not None and hasattr(obj, "_position_ids"):
                obj._position_ids = None
                obj._rope_deltas = None

    def info(self):
        if VARIANT == "vl":
            return {"model": VL_ID, "dim": 2048, "modalities": ["text", "image"]}
        return {"model": TEXT_ID, "dim": 1024, "modalities": ["text"]}

    def embed(self, modality, role, inputs):
        if modality == "audio" or (modality == "image" and VARIANT != "vl"):
            raise ProtocolError("unsupported_modality", modality)
        if VARIANT == "vl":
            if modality == "text":
                tok = getattr(self.processor, "tokenizer", self.processor)
                texts = [truncate_text(t, tok) for t in inputs]
                items = [{"text": t, "instruction": VL_INSTRUCTION} if role == "query" else {"text": t}
                         for t in texts]
            else:
                prepared = [prepare_image(p, self.tmp) for p in inputs]
                parts = []
                for i in range(0, len(prepared), IMAGE_BATCH):
                    self._reset_rope_cache()
                    parts.append(self.model.process([{"image": p} for p in prepared[i:i + IMAGE_BATCH]],
                                                    processor=self.processor))
                emb = mx.concatenate(parts, axis=0)
                items = None
            if items is not None:
                self._reset_rope_cache()
                emb = self.model.process(items, processor=self.processor)
        else:
            from mlx_embeddings import generate
            texts = [TEXT_QUERY_PREFIX + t if role == "query" else t for t in inputs]
            emb = generate(self.model, self.processor, texts=texts, max_length=2048).text_embeds
        emb = emb.astype(mx.float32)
        mx.eval(emb)
        return np.array(emb)


if __name__ == "__main__":
    serve(QwenBackend())
