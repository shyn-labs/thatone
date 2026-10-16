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

## Privacy

The index is encrypted at rest with a key in your Keychain. Text that looks like a secret (API keys, private keys) is never stored. Indexing needs permission only for the folders you choose (and Photos, if you switch it on).

## License

[Elastic License 2.0](LICENSE): source-available. You may use, modify and share it; you may not offer it as a managed service or sell it.
