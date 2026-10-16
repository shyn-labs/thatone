from pathlib import Path

import pytest

from bakeoff.sample import build_manifest, file_id, is_excluded, kind_of, read_jsonl, walk, write_jsonl


def touch(p: Path, data: bytes = b"x") -> Path:
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(data)
    return p


@pytest.mark.parametrize("name,kind", [
    ("a.PNG", "image"), ("b.heic", "image"), ("c.pdf", "pdf"), ("d.docx", "doc"), ("e.md", "doc"),
    ("f.m4a", "audio"), ("g.MOV", "video"), ("h.swift", "code"), ("i.zip", None),
])
def test_kind_of(name, kind):
    assert kind_of(Path(name)) == kind


@pytest.mark.parametrize("rel", [
    ".ssh/id_ed25519", ".aws/credentials", "proj/.env", "proj/.env.local", "certs/server.pem",
    "k/private.key", "proj/node_modules/x.js", "proj/.git/HEAD", "Foo.app/Contents/x.png",
    "Photos Library.photoslibrary/originals/a.jpg", "docs/.report.pdf.icloud", "Library/Caches/a.png",
])
def test_is_excluded(rel):
    assert is_excluded(Path("/Users/v") / rel)


def test_not_excluded():
    assert not is_excluded(Path("/Users/v/Documents/work/report.pdf"))


def test_walk_prunes_excluded(tmp_path):
    touch(tmp_path / "keep.png")
    touch(tmp_path / "node_modules" / "skip.png")
    touch(tmp_path / ".ssh" / "id_rsa")
    assert [p.name for p in walk([tmp_path])] == ["keep.png"]


def test_unicode_and_space_paths(tmp_path):
    p = touch(tmp_path / "ಕನ್ನಡ ಫೋಲ್ಡರ್" / "it's a \"photo\".png")
    m = build_manifest([tmp_path], {"image": 5}, force_include=[])
    assert m[0]["path"] == str(p)
    write_jsonl(tmp_path / "m.jsonl", m)
    assert read_jsonl(tmp_path / "m.jsonl") == m


def test_quotas_seeded_and_forced_first(tmp_path):
    imgs = [touch(tmp_path / f"img{i}.png") for i in range(20)]
    pdf = touch(tmp_path / "x.pdf")
    m1 = build_manifest([tmp_path], {"image": 5, "pdf": 0}, force_include=[imgs[17], pdf])
    m2 = build_manifest([tmp_path], {"image": 5, "pdf": 0}, force_include=[imgs[17], pdf])
    assert m1 == m2
    assert [e["path"] for e in m1[:2]] == [str(imgs[17]), str(pdf)]
    assert all(e["forced"] for e in m1[:2])
    assert sum(1 for e in m1 if e["kind"] == "image" and not e["forced"]) == 5
    assert len({e["id"] for e in m1}) == len(m1)
    assert m1[0]["id"] == file_id(imgs[17])


def test_force_include_missing_or_excluded_raises(tmp_path):
    secret = touch(tmp_path / ".ssh" / "id_rsa")
    with pytest.raises(ValueError) as e:
        build_manifest([tmp_path], {}, force_include=[tmp_path / "gone.pdf", secret])
    assert "gone.pdf" in str(e.value) and "id_rsa" in str(e.value)


def test_duplicate_golden_paths_deduplicated(tmp_path):
    a = touch(tmp_path / "a.md")
    m = build_manifest([tmp_path], {}, force_include=[a, a])
    assert [e["path"] for e in m] == [str(a.resolve())]


def test_root_under_library_is_walked(tmp_path):
    root = tmp_path / "Library" / "Mobile Documents"
    p = touch(root / "scan.png")
    assert [x.name for x in walk([root])] == ["scan.png"]
    m = build_manifest([root], {}, force_include=[p])
    assert len(m) == 1


def test_no_owner_identity_in_repo():
    """Fails if any term from THATONE_PRIVATE_TERMS (a |-separated list kept outside the repo) appears in tracked sources."""
    import os
    import re
    import pytest
    terms = os.environ.get("THATONE_PRIVATE_TERMS", "").strip("|")
    if not terms:
        pytest.skip("THATONE_PRIVATE_TERMS not set")
    repo = Path(__file__).resolve().parents[2]
    hits = []
    for f in list(repo.glob("bakeoff/src/**/*.py")) + list(repo.glob("bakeoff/tests/*.py")) + \
            list(repo.glob("sidecar/**/*.py")) + list(repo.glob("*.md")) + list(repo.glob("sidecar/*.md")):
        if ".venv" in f.parts:
            continue
        if re.search(terms, f.read_text(encoding="utf-8"), re.I):
            hits.append(str(f))
    assert hits == []
