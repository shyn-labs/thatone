# thatone

Find that one file on your Mac by describing it: a photo by what it shows, a PDF page or document by its text, a recording or video by what is said or shown in it. Everything runs on your machine; nothing is sent anywhere.

Status: pre-alpha, macOS on Apple Silicon only.

## What is here

- `engine/` – Swift package: encrypted index (SQLCipher + sqlite-vec), crawler and file watcher, readers for images, PDFs, documents, audio and video, hybrid keyword + vector search, the `thatone` command-line tool and its private query socket.
- `app/` – the menu-bar app: hotkey search panel with preview, big window, Settings.
- `sidecar/` – the embedding worker (a local multimodal embedding model) and the stdio protocol it speaks (`sidecar/protocol.md`).
- `bakeoff/` – the throwaway harness used to compare embedding models.

## Build

Needs macOS 14+ on Apple Silicon, Xcode command-line tools and [uv](https://github.com/astral-sh/uv).

```sh
cd engine && scripts/fetch-sqlcipher.sh && swift build && swift test
cd ../app && scripts/build-app.sh      # add --install to copy it to ~/Applications
```

Models are not downloaded by the app; the embedding worker loads a local model folder (see `sidecar/`). Speech-to-text for audio and video uses a local WhisperKit model folder if you have one; without it audio and video indexing stay off.

## Releasing (maintainers)

`app/scripts/build-app.sh --release` builds the distributable app with build paths scrubbed, signs it with the neutral project identity `Shyn Dev` (Apple Development and ad-hoc identities are refused) and packs `dist/release/ThatOne-v<version>-darwin-arm64.tar.gz` with a fixed owner. The package is checked by the artifact gate, `scripts/check-artifact-leaks.py`, before it gets its publish name; on any hit it is kept as `...tar.gz.rejected` and the build fails.

The gate scans every file, the raw archive stream and every path and link target for the builder's username, home and checkout path and for the terms of a private denylist (`~/.config/shyn/leak-denylist.txt`, kept outside the repo). It also checks that every bundle and Mach-O file is signed only by an allowed identity (`THATONE_ALLOWED_AUTHORITIES`, default `Shyn Dev`) with no team id. A release build refuses environment that would weaken the gate (denylist or allowlist overrides, a different `HOME`, shell startup files). Upload only the file the build printed after "OK", and match its `sha256:` line. Details: `scripts/check-artifact-leaks.py --help`; tests: `python -m pytest scripts/tests`.

Dev builds (`build-app.sh` without `--release`) are for your own Mac and should not be distributed.

## Privacy

The index is encrypted at rest with a key in your Keychain. Text that looks like a secret (API keys, private keys) is never stored. Indexing needs permission only for the folders you choose (and Photos, if you switch it on).

## License

[Elastic License 2.0](LICENSE): source-available. You may use, modify and share it; you may not offer it as a managed service or sell it.
