# Sidecar protocol v0

One JSON object per line on stdin; one JSON object per line on stdout. Logs go to stderr.
EOF on stdin means shut down (exit 0).

## Requests
{"id": 1, "op": "info"}
{"id": 2, "op": "embed", "modality": "text"|"image"|"audio", "role": "query"|"document", "inputs": ["..."]}

- text: inputs are raw strings. The worker adds its own query/document prefixes.
- image, audio: inputs are absolute file paths.

## Responses
{"id": 1, "ok": true, "model": "<id>", "dim": 768, "modalities": ["text", "image", "audio"]}
{"id": 2, "ok": true, "count": 2, "dim": 768, "vectors_b64": "<base64>"}
{"id": 2, "ok": false, "error": {"code": "unsupported_modality"|"bad_request"|"input_error"|"internal", "message": "..."}}

vectors_b64 = base64 of little-endian float32, row-major count×dim, each row L2-normalized.
If a request line cannot be parsed, the response has "id": null.
