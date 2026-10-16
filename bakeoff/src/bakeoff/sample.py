import fnmatch
import hashlib
import json
import os
import random
from pathlib import Path
from typing import Iterable, Iterator

_EXTS = {
    "image": ".png .jpg .jpeg .heic .gif .webp .tif .tiff",
    "pdf": ".pdf",
    "doc": ".txt .md .rtf .doc .docx .odt .html .htm",
    "audio": ".m4a .mp3 .wav .aiff .aif .caf .flac .ogg",
    "video": ".mov .mp4 .m4v .mkv .webm",
    "code": ".py .ts .tsx .js .swift .go .rs .java .kt .rb .sh .sql .c .h .cpp",
}
KIND_BY_EXT = {ext: kind for kind, exts in _EXTS.items() for ext in exts.split()}

EXCLUDED_DIRS = {".ssh", ".aws", ".gnupg", "node_modules", ".git", ".venv", "venv",
                 "__pycache__", "Library", "Caches", ".Trash", ".cache"}
EXCLUDED_DIR_SUFFIXES = (".app", ".photoslibrary", ".opvault", ".keychain-db")
EXCLUDED_NAMES = (".env", ".env.*", "*.pem", "*.key", "id_*", "*.p12", "*.keychain*", "*.icloud")


def kind_of(path: Path) -> str | None:
    return KIND_BY_EXT.get(path.suffix.lower())


def is_excluded(path: Path, root: Path | None = None) -> bool:
    """Only the part of the path below `root` is checked, so a chosen root inside
    ~/Library (iCloud Drive) is not excluded by its own ancestors."""
    rel = path
    if root is not None:
        try:
            rel = path.relative_to(root)
        except ValueError:
            pass
    for part in rel.parts[:-1]:
        if part in EXCLUDED_DIRS or part.endswith(EXCLUDED_DIR_SUFFIXES):
            return True
    return any(fnmatch.fnmatch(path.name, pat) for pat in EXCLUDED_NAMES)


def walk(roots: list[Path]) -> Iterator[Path]:
    for root in roots:
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = sorted(d for d in dirnames
                                 if d not in EXCLUDED_DIRS and not d.endswith(EXCLUDED_DIR_SUFFIXES))
            for name in sorted(filenames):
                p = Path(dirpath) / name
                if not is_excluded(p, Path(root)) and kind_of(p):
                    yield p


def file_id(path: Path) -> str:
    return hashlib.sha1(str(path.resolve()).encode()).hexdigest()[:12]


def _entry(p: Path, forced: bool) -> dict:
    st = p.stat()
    return {"id": file_id(p), "path": str(p), "kind": kind_of(p), "size": st.st_size,
            "mtime": int(st.st_mtime), "forced": forced}


def _root_of(p: Path, roots: list[Path]) -> Path | None:
    for r in roots:
        if p.is_relative_to(r):
            return r
    return None


def build_manifest(roots, quotas: dict[str, int], force_include: list[Path], seed: int = 13) -> list[dict]:
    roots = [Path(r).resolve() for r in roots]
    bad = [str(p) for p in force_include
           if not Path(p).is_file() or not kind_of(Path(p))
           or is_excluded(Path(p).resolve(), _root_of(Path(p).resolve(), roots))]
    if bad:
        raise ValueError("golden files missing, excluded or unsupported:\n" + "\n".join(bad))
    # A file named by several queries must appear once, or its segments are indexed twice.
    forced = list(dict.fromkeys(Path(p).resolve() for p in force_include))
    entries = [_entry(p, True) for p in forced]
    forced_set = set(forced)
    by_kind: dict[str, list[Path]] = {}
    for p in walk(roots):
        if p.resolve() not in forced_set:
            by_kind.setdefault(kind_of(p), []).append(p)
    rng = random.Random(seed)
    for kind in sorted(by_kind):
        pool = by_kind[kind]
        n = min(quotas.get(kind, 0), len(pool))
        entries += [_entry(p, False) for p in rng.sample(pool, n)]
    return entries


def write_jsonl(path: Path, rows: Iterable[dict]) -> None:
    with open(path, "w", encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")


def read_jsonl(path: Path) -> list[dict]:
    with open(path, encoding="utf-8") as f:
        return [json.loads(line) for line in f if line.strip()]
