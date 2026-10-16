# thatone engine

Headless engine and `thatone` command-line tool: indexes images in chosen folders (Vision OCR text plus an
EmbeddingGemma 2 image embedding) into one encrypted database and finds them by describing them.

Setup: `scripts/fetch-sqlcipher.sh`, then `swift build -c release`. The embedding worker lives in `../sidecar/gemma`
(`uv sync` there once). Tests: `swift test` (needs `uv sync` in `../bakeoff` for the Python fake worker).

    thatone index ~/Pictures/Screenshots
    thatone search "invoice 4471" --json
    thatone status

Data lives in `~/Library/Application Support/thatone` (override with `THATONE_HOME`). The database key is a random
32-byte key in the login Keychain; `THATONE_KEY_HEX` replaces it for disposable test databases only.
