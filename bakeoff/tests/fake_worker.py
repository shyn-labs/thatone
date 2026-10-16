"""Deterministic test worker. Text: hashed bag of words. Image/audio: hash of the path.
'bad' in an input → input_error. FAKE_DIE_AFTER=n → exits hard after n requests.
FAKE_NO_AUDIO=1 → audio unsupported."""
import hashlib
import os
import sys
import time

import numpy as np

from thatone_protocol import ProtocolError, serve

DIM = 16
SERVED = 0


def bag(text: str) -> np.ndarray:
    v = np.zeros(DIM, dtype=np.float32)
    for w in text.lower().split():
        v[int(hashlib.md5(w.encode()).hexdigest(), 16) % DIM] += 1
    return v


class Fake:
    def info(self):
        return {"model": "fake", "dim": DIM, "modalities": ["text", "image", "audio"]}

    def embed(self, modality, role, inputs):
        global SERVED
        SERVED += 1
        if os.environ.get("FAKE_DIE_AFTER") and SERVED > int(os.environ["FAKE_DIE_AFTER"]):
            os._exit(3)
        if modality == "audio" and os.environ.get("FAKE_NO_AUDIO"):
            raise ProtocolError("unsupported_modality", "audio")
        if any("hangnow" in x for x in inputs):
            time.sleep(60)
        if any("strayline" in x for x in inputs):
            sys.stdout.write("this is not json\n")
            sys.stdout.flush()
        if any("killme" in x for x in inputs):
            os._exit(4)
        if any("unsup" in x for x in inputs):
            raise ProtocolError("unsupported_modality", "rejected")
        if any("bad" in x for x in inputs):
            raise ProtocolError("input_error", "bad input")
        return np.stack([bag(x) + 0.01 for x in inputs])


if __name__ == "__main__":
    serve(Fake())
