import io
import json

import numpy as np
import pytest

from thatone_protocol import (
    ProtocolError, decode_vectors, encode_vectors, l2_normalize, parse_request, serve,
)


def test_vectors_round_trip():
    arr = np.arange(6, dtype=np.float32).reshape(2, 3)
    out = decode_vectors(encode_vectors(arr), 2, 3)
    assert out.dtype == np.float32
    np.testing.assert_array_equal(out, arr)


def test_decode_rejects_wrong_shape():
    b64 = encode_vectors(np.zeros((2, 3), dtype=np.float32))
    with pytest.raises(ValueError):
        decode_vectors(b64, 3, 3)


def test_l2_normalize_handles_zero_rows():
    out = l2_normalize(np.array([[3.0, 4.0], [0.0, 0.0]], dtype=np.float32))
    np.testing.assert_allclose(out[0], [0.6, 0.8])
    np.testing.assert_array_equal(out[1], [0.0, 0.0])


@pytest.mark.parametrize("line,code", [
    ("not json", "bad_request"),
    ('{"op": "info"}', "bad_request"),
    ('{"id": 1, "op": "nope"}', "bad_request"),
    ('{"id": 1, "op": "embed", "modality": "smell", "role": "query", "inputs": ["x"]}', "bad_request"),
    ('{"id": 1, "op": "embed", "modality": "text", "role": "boss", "inputs": ["x"]}', "bad_request"),
    ('{"id": 1, "op": "embed", "modality": "text", "role": "query", "inputs": []}', "bad_request"),
    ('{"id": 1, "op": "embed", "modality": "text", "role": "query", "inputs": [1]}', "bad_request"),
])
def test_parse_request_rejects(line, code):
    with pytest.raises(ProtocolError) as e:
        parse_request(line)
    assert e.value.code == code


class FakeBackend:
    def info(self):
        return {"model": "fake", "dim": 2, "modalities": ["text"]}

    def embed(self, modality, role, inputs):
        if modality != "text":
            raise ProtocolError("unsupported_modality", modality)
        if "boom" in inputs:
            raise RuntimeError("kaboom")
        return np.array([[3.0, 4.0]] * len(inputs), dtype=np.float32)


def run(lines):
    out = io.StringIO()
    serve(FakeBackend(), stdin=io.StringIO("\n".join(lines) + "\n"), stdout=out)
    return [json.loads(l) for l in out.getvalue().splitlines()]


def test_serve_info_embed_and_errors():
    resps = run([
        '{"id": 1, "op": "info"}',
        '{"id": 2, "op": "embed", "modality": "text", "role": "query", "inputs": ["a", "b"]}',
        '{"id": 3, "op": "embed", "modality": "image", "role": "document", "inputs": ["/x.png"]}',
        '{"id": 4, "op": "embed", "modality": "text", "role": "query", "inputs": ["boom"]}',
        "garbage",
        "",
    ])
    assert resps[0] == {"id": 1, "ok": True, "model": "fake", "dim": 2, "modalities": ["text"]}
    assert resps[1]["ok"] and resps[1]["count"] == 2 and resps[1]["dim"] == 2
    np.testing.assert_allclose(decode_vectors(resps[1]["vectors_b64"], 2, 2), [[0.6, 0.8]] * 2)
    assert resps[2]["error"]["code"] == "unsupported_modality"
    assert resps[3]["error"]["code"] == "internal" and "kaboom" in resps[3]["error"]["message"]
    assert resps[4] == {"id": None, "ok": False, "error": {"code": "bad_request", "message": resps[4]["error"]["message"]}}
    assert len(resps) == 5  # blank line ignored
