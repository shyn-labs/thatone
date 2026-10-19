"""Drives scripts/check-artifact-leaks.py (the release gate) as a subprocess
against SYNTHETIC artifacts in temp dirs. The builder's username comes from
SHYN_GATE_USERNAME, the denylist and allowlist from temp files, and `codesign`
is a fake shim reached through THATONE_CODESIGN (PATH is never consulted by the
gate), so no real identity, name, domain or signing certificate appears in (or
is read by) this file. The gate checks every bundle type (.app .framework .xpc
.appex .bundle .plugin .kext .systemextension, any case) and every Mach-O file
by magic with `codesign --verify --strict --deep`; a tarball without a .app is
a hit; THATONE_ALLOWED_AUTHORITIES sets the allowed authorities (set but
empty is a usage error; set prints a NOTICE with the entry count only); it
prints the sha256 of each archive and a WARNING for each test-only hook that is
set. `--release` refuses SHYN_LEAK_DENYLIST, SHYN_ARTIFACT_ALLOW, --ci and a
/Users/runner home (exit 2); without it each of those prints a NOTICE.

The last section runs app/scripts/build-app.sh --release in a temp copy of the
repo layout with fake swift/codesign/security/install_name_tool on PATH and a
stub gate at the fixed path <copy>/scripts/check-artifact-leaks.py (there is no
override variable: THATONE_GATE no longer exists and is ignored), to prove the
package is renamed only after the gate passes, the gate runs as
/usr/bin/python3 -I with --release (a python3 on PATH is never used), the
identity, an empty allowlist and the weakening environment are refused before
swift, and the test hooks are stripped. No real build output, keychain or
identity is touched.

Run: bakeoff/.venv/bin/python -m pytest scripts/tests
"""

import ast
import io
import os
import pwd
import re
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import time

import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
GATE = os.path.join(ROOT, "scripts", "check-artifact-leaks.py")
PREFIX = "thatone-artifact-gate-"
NAME = "builder-zq7"
TERM = "acme-secret"
TIMEOUT = 25
TAR_ENV = dict(os.environ, COPYFILE_DISABLE="1")  # like package-release.sh: no AppleDouble members

SHYN_DEV_DVV = """Executable=/x/Fake.app/Contents/MacOS/Fake
Identifier=com.example.fake
Format=app bundle with Mach-O thin (arm64)
CodeDirectory v=20400 size=100 flags=0x0(none) hashes=3+3 location=embedded
Signature size=1663
Authority=Shyn Dev
Signed Time=1 Jan 2026 at 00:00:00
Info.plist entries=16
TeamIdentifier=not set
Sealed Resources version=2 rules=13 files=1
Internal requirements count=1 size=96
"""

SHIM = """#!/bin/sh
# fake codesign for the gate tests: canned output, never a real signature check. The path is the last
# argument; when it contains $FAKE_CODESIGN_ALT_MATCH the ALT output and certificate are used instead.
echo "$*" >> "$FAKE_CODESIGN_LOG"
for a; do last="$a"; done
dvv="$FAKE_CODESIGN_DVV"; cert="$FAKE_CODESIGN_CERT"
if [ -n "$FAKE_CODESIGN_ALT_MATCH" ]; then
  case "$last" in *"$FAKE_CODESIGN_ALT_MATCH"*) dvv="$FAKE_CODESIGN_ALT_DVV"; cert="$FAKE_CODESIGN_ALT_CERT" ;; esac
fi
case "$1" in
  --verify) exit "${FAKE_CODESIGN_VERIFY_RC:-0}" ;;
  -dvv) /bin/cat "$dvv" >&2; exit 0 ;;
  -d) [ -n "$cert" ] || exit 1
      prefix="${2#--extract-certificates=}"; /bin/cp "$cert" "${prefix}0"; exit 0 ;;
esac
exit 64
"""


@pytest.fixture(scope="session")
def base():
    d = tempfile.mkdtemp(prefix="thatone-leakgate-test-")
    os.makedirs(os.path.join(d, "empty-dist"))
    shim_dir = os.path.join(d, "shim")
    os.makedirs(shim_dir)
    with open(os.path.join(shim_dir, "codesign"), "w") as f:
        f.write(SHIM)
    os.chmod(os.path.join(shim_dir, "codesign"), 0o755)
    os.makedirs(os.path.join(d, "no-codesign"))
    with open(os.path.join(d, "dvv-shyn-dev.txt"), "w") as f:
        f.write(SHYN_DEV_DVV)
    yield d
    for root, dirs, files in os.walk(d):  # undo chmod 000 leftovers before removing
        for n in dirs + files:
            try:
                os.chmod(os.path.join(root, n), 0o755, follow_symlinks=False)
            except (OSError, NotImplementedError):
                pass
    shutil.rmtree(d, ignore_errors=True)


def write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data if isinstance(data, bytes) else data.encode("utf-8"))
    return path


def deny(base, name, *terms):
    return write(os.path.join(base, name), "# synthetic denylist\n" + "\n".join(terms) + "\n")


def allow(base, name, *lines):
    return write(os.path.join(base, name), "# synthetic allowlist\n" + "\n".join(lines) + "\n")


def gate_env(base, **extra):
    """The ONE place that builds the environment of every spawned gate process: synthetic builder
    name, temp denylist, absent allowlist, allowed authorities, empty dist dir and THATONE_CODESIGN
    pointing at the fake codesign. Nothing may fall back to ~/.config/shyn or the real codesign
    (test_every_spawn_uses_gate_env enforces it)."""
    env = dict(os.environ)
    env.update({
        "CI": "",
        "SHYN_GATE_USERNAME": NAME,
        "SHYN_LEAK_DENYLIST": deny(base, "deny-acme.txt", TERM),
        "SHYN_ARTIFACT_ALLOW": os.path.join(base, "no-allowlist.txt"),
        "SHYN_DIST_DIR": os.path.join(base, "empty-dist"),
        "THATONE_ALLOWED_AUTHORITIES": "Shyn Dev",
        "THATONE_CODESIGN": os.path.join(base, "shim", "codesign"),
        "FAKE_CODESIGN_DVV": os.path.join(base, "dvv-shyn-dev.txt"),
        "FAKE_CODESIGN_LOG": os.path.join(base, "codesign.log"),
        "FAKE_CODESIGN_VERIFY_RC": "0",
    })
    for k in ("SHYN_GATE_TEST_DELAY_MS", "FAKE_CODESIGN_ALT_MATCH", "FAKE_CODESIGN_CERT"):
        env.pop(k, None)
    for k, v in extra.items():  # None removes the variable
        if v is None:
            env.pop(k, None)
        else:
            env[k] = v
    return env


def run_gate(base, args, **env):
    r = subprocess.run([sys.executable, GATE] + list(args), cwd=ROOT, capture_output=True, text=True,
                       timeout=TIMEOUT, env=gate_env(base, **env))
    return r.returncode, r.stdout + r.stderr


def tar_of(base, name, files, app=True):
    d = tempfile.mkdtemp(prefix="src-", dir=base)
    for f, c in files.items():
        write(os.path.join(d, f), c)
    if app:  # an empty bundle dir: no file counted, signed "Shyn Dev" per the default shim output
        os.makedirs(os.path.join(d, "Fake.app"), exist_ok=True)
    out = os.path.join(base, name)
    subprocess.run(["/usr/bin/tar", "--no-mac-metadata", "--no-xattrs", "-czf", out, "-C", d, "."], check=True,
                   timeout=TIMEOUT, env=TAR_ENV)
    return out


def tar_dir(base, name, d, *opts, app=True):
    if app:
        os.makedirs(os.path.join(d, "Fake.app"), exist_ok=True)
    out = os.path.join(base, name)
    subprocess.run(["/usr/bin/tar", "--no-mac-metadata", "--no-xattrs"] + list(opts) + ["-czf", out, "-C", d, "."],
                   check=True, timeout=TIMEOUT, env=TAR_ENV)
    return out


def gate_dirs():
    return sorted(n for n in os.listdir(tempfile.gettempdir()) if n.startswith(PREFIX))


def summary(f, mb, h, a, n, u):
    return "scanned %d files, %s MB, hits %d, allowlisted %d, ignored binary noise %d, unreadable %d" % (f, mb, h, a, n, u)


# --------------------------------------------------------------------------


def test_help_documents_flags(base):
    code, out = run_gate(base, ["--help"])
    assert code == 0
    for f in ["--tarball", "--dir", "--ci", "--show-noise", "SHYN_LEAK_DENYLIST", "SHYN_ARTIFACT_ALLOW",
              "SHYN_GATE_USERNAME", "THATONE_ALLOWED_AUTHORITIES"]:
        assert f in out


def test_usage_errors_exit_2(base):
    assert run_gate(base, [])[0] == 2  # no default target in the empty dist dir
    assert run_gate(base, ["--bogus"])[0] == 2
    assert run_gate(base, ["--tarball"])[0] == 2
    assert run_gate(base, ["--tarball", os.path.join(base, "nope.tar.gz")])[0] == 2
    assert run_gate(base, ["--dir", os.path.join(base, "nope")])[0] == 2


def test_default_target_is_newest_release_tarball(base):
    dist = os.path.join(base, "dist-default")
    os.makedirs(os.path.join(dist, "release"))
    old = tar_of(base, "x1.tar.gz", {"a.txt": TERM + "\n"})
    new = tar_of(base, "x2.tar.gz", {"a.txt": "clean\n"})
    shutil.copy(old, os.path.join(dist, "release", "ThatOne-v0.1.0-darwin-arm64.tar.gz"))
    shutil.copy(new, os.path.join(dist, "release", "ThatOne-v0.2.0-darwin-arm64.tar.gz"))
    os.utime(os.path.join(dist, "release", "ThatOne-v0.1.0-darwin-arm64.tar.gz"), (1, 1))
    code, out = run_gate(base, [], SHYN_DIST_DIR=dist)
    assert code == 0, out
    assert "ThatOne-v0.2.0-darwin-arm64.tar.gz" in out


def test_text_hit_with_offset_and_redacted_context(base):
    tb = tar_of(base, "text.tar.gz", {"a/readme.txt": "line one\nsee the acme-secret vendor\n"})
    code, out = run_gate(base, ["--tarball", tb])
    assert code == 1
    # "line one\nsee the " is 17 bytes
    assert re.search(r"tarball:a/readme\.txt  @17  \[denylist-term-0\]  .*<denylist-term-0>", out), out
    assert TERM not in out
    assert re.search(r"scanned 1 files, \S+ MB, hits 1, allowlisted 0, ignored binary noise 0, unreadable 0", out)


def test_binary_hit_inside_12_char_printable_run(base):
    blob = bytes([0xCF, 0xFA, 0, 0xFF]) + b"x-acme-secret" + bytes([0, 1])
    tb = tar_of(base, "bin.tar.gz", {"bin/blob": blob})
    code, out = run_gate(base, ["--tarball", tb])
    assert code == 1
    assert re.search(r"blob  @6 ", out), out
    assert "hits 1, allowlisted 0, ignored binary noise 0" in out


def test_short_term_coincidence_in_binary_is_counted_noise(base):
    dl = deny(base, "deny-short.txt", "zqx")
    blob = bytes([0, 0xFF, 1, 0x7A, 0x71, 0x78, 2, 0xFE, 0])
    tb = tar_of(base, "noise.tar.gz", {"bin/blob": blob})
    code, out = run_gate(base, ["--tarball", tb, "--show-noise"], SHYN_LEAK_DENYLIST=dl)
    assert code == 0, out
    assert "hits 0, allowlisted 0, ignored binary noise 1, unreadable 0" in out
    assert "ignored binary noise in: bin/blob" in out
    assert "zqx" not in out


def test_long_term_outside_printable_run_is_noise(base):
    # a 4-char term surrounded by control bytes is a printable run of 4 (< 6): noise, counted
    dl = deny(base, "deny-4.txt", "qzvk")
    blob = bytes([0, 1, 2]) + b"qzvk" + bytes([3, 4, 0])
    d = tempfile.mkdtemp(prefix="noise4-", dir=base)
    write(os.path.join(d, "b.bin"), blob)
    code, out = run_gate(base, ["--dir", d], SHYN_LEAK_DENYLIST=dl)
    assert code == 0, out
    assert "hits 0, allowlisted 0, ignored binary noise 1" in out


def test_builder_needle_has_no_noise_rule(base):
    blob = bytes([0, 0xFF, 0x61, 0x62, 0x7A, 0x71, 0x37, 0x63, 0x64, 1, 0])  # ab zq7 cd
    tb = tar_of(base, "builder.tar.gz", {"bin/blob": blob})
    code, out = run_gate(base, ["--tarball", tb], SHYN_GATE_USERNAME="zq7")
    assert code == 1
    assert re.search(r"blob  @4  \[username\]  .*ab<username>cd", out), out
    assert "zq7" not in out


def test_matches_straddling_64mib_offset(base):
    d = tempfile.mkdtemp(prefix="big-", dir=base)
    at = 64 * 1024 * 1024
    with open(os.path.join(d, "big.dat"), "wb") as f:
        f.truncate(at + 1024 * 1024)
    with open(os.path.join(d, "big.dat"), "r+b") as f:
        f.seek(0)
        chunk = b"." * (1024 * 1024)
        for _ in range(65):
            f.write(chunk)
        f.seek(at - 5)
        f.write(TERM.encode())
        f.seek(at - 100)
        f.write(NAME.encode())
    code, out = run_gate(base, ["--dir", d])
    assert code == 1, out
    assert "@%d " % (at - 5) in out
    assert "@%d " % (at - 100) in out
    assert "[username]" in out and "[denylist-term-0]" in out
    assert re.search(r"hits 2, ", out)


def test_whole_words_only(base):
    d = tempfile.mkdtemp(prefix="word-", dir=base)
    write(os.path.join(d, "ident.txt"), "myacme-secretly acme-secretive xacme-secret acme-secret9\n")
    assert run_gate(base, ["--dir", d])[0] == 0
    write(os.path.join(d, "edge.txt"), "a_acme-secret b/acme-secret.c ACME-SECRET\n")
    code, out = run_gate(base, ["--dir", d])
    assert code == 1
    assert re.search(r"hits 3, ", out)


def test_short_term_never_in_binary_but_in_text(base):
    dl = deny(base, "deny-3.txt", "zqx")
    d = tempfile.mkdtemp(prefix="short-", dir=base)
    write(os.path.join(d, "b.bin"), bytes([0, 1]) + b"long printable run zqx and more" + bytes([0]))
    code, out = run_gate(base, ["--dir", d], SHYN_LEAK_DENYLIST=dl)
    assert code == 0, out
    assert "hits 0, allowlisted 0, ignored binary noise 1, " in out
    write(os.path.join(d, "t.txt"), "see zqx here\n")
    assert run_gate(base, ["--dir", d], SHYN_LEAK_DENYLIST=dl)[0] == 1


def test_non_ascii_term_matches_as_utf8(base):
    dl = deny(base, "deny-utf8.txt", "café-geheim")
    d = tempfile.mkdtemp(prefix="utf8-", dir=base)
    write(os.path.join(d, "t.txt"), "the café-geheim file\n")
    write(os.path.join(d, "b.bin"), bytes([0, 1]) + "xx café-geheim xx".encode() + bytes([0]))
    code, out = run_gate(base, ["--dir", d], SHYN_LEAK_DENYLIST=dl)
    assert code == 1
    assert re.search(r"hits 2, ", out)
    assert "geheim" not in out


def test_third_party_users_path_is_not_a_hit(base):
    # an upstream framework built on someone else's CI keeps its own /Users/<them> paths: not the builder's
    d = tempfile.mkdtemp(prefix="jenkins-", dir=base)
    write(os.path.join(d, "Vendor.framework", "Versions", "A", "Vendor"),
          bytes([0xCF, 0xFA, 0, 0]) + b"/Users/jenkins/x/build/sqlite3.c" + bytes([0]))
    write(os.path.join(d, "notes.txt"), "built at /Users/jenkins/x\n")
    code, out = run_gate(base, ["--dir", d])
    assert code == 0, out
    assert "hits 0," in out


# --- owner allowlist --------------------------------------------------------


def _al_setup(base):
    d = tempfile.mkdtemp(prefix="al-", dir=base)
    write(os.path.join(d, "vendor", "deps", "lib.c"), "/* acme-secret */\n/* acme-secret */\n")
    return d


def test_allowlist_match_is_reported_not_failure(base):
    d = _al_setup(base)
    code, out = run_gate(base, ["--dir", d], SHYN_ARTIFACT_ALLOW=allow(base, "al1.txt", "vendor/**/lib.c|ACME-secret"))
    assert code == 0, out
    assert "allowlisted: dir:vendor/deps/lib.c x2 (<denylist-term-0>)" in out
    assert summary(1, "0.0", 0, 2, 0, 0) in out


def test_allowlist_other_file_still_hits(base):
    d = _al_setup(base)
    code, out = run_gate(base, ["--dir", d], SHYN_ARTIFACT_ALLOW=allow(base, "al2.txt", "vendor/deps/other.c|acme-secret"))
    assert code == 1
    assert "hits 2, allowlisted 0" in out


@pytest.mark.parametrize("lines,n", [
    (["# c", "**|acme-secret"], 2), (["*|acme-secret"], 1), (["vendor/**|not-a-term-xyz"], 1),
    (["vendor/deps/*.c|acme-secret"], 1), (["vendor/**/**|acme-secret"], 1), (["vendor/deps/lib.c"], 1),
])
def test_allowlist_rejections_name_line_only(base, lines, n):
    d = _al_setup(base)
    code, out = run_gate(base, ["--dir", d], SHYN_ARTIFACT_ALLOW=allow(base, "al3.txt", *lines))
    assert code == 1
    assert "line(s): %d" % (n + 1) in out
    assert "not-a-term-xyz" not in out


def test_allowlist_narrows_to_term_and_file(base):
    dl = deny(base, "deny-two.txt", TERM, "zorblat-corp")
    d = _al_setup(base)
    write(os.path.join(d, "vendor", "deps", "lib.c"), "/* acme-secret */ zorblat-corp\n")
    code, out = run_gate(base, ["--dir", d], SHYN_LEAK_DENYLIST=dl,
                         SHYN_ARTIFACT_ALLOW=allow(base, "al4.txt", "vendor/**/lib.c|acme-secret"))
    assert code == 1
    assert "hits 1, allowlisted 1" in out
    assert "zorblat" not in out


def test_absent_allowlist_has_no_effect(base):
    assert run_gate(base, ["--dir", _al_setup(base)])[0] == 1


# --- archive headers, names, links -------------------------------------------


def test_owner_name_in_tar_header_found_by_raw_stream(base):
    d = tempfile.mkdtemp(prefix="own-", dir=base)
    write(os.path.join(d, "a.txt"), "nothing\n")
    tb = tar_dir(base, "owner.tar.gz", d, "--uname", NAME, "--gname", "staff")
    code, out = run_gate(base, ["--tarball", tb])
    assert code == 1
    assert re.search(r"tarball-raw:raw stream  @\d+  \[username\]", out), out
    assert NAME not in out


def test_symlink_target_and_directory_name(base):
    d = tempfile.mkdtemp(prefix="lnk-", dir=base)
    write(os.path.join(d, "a.txt"), "nothing\n")
    os.symlink("/Users/%s/x" % NAME, os.path.join(d, "dangling"))
    write(os.path.join(d, "dir-acme-secret", "b.txt"), "clean\n")
    tb = tar_dir(base, "links.tar.gz", d)
    code, out = run_gate(base, ["--tarball", tb])
    assert code == 1
    assert re.search(r"tarball:dangling  link:  \[username\]", out), out
    assert re.search(r"tarball:dir-<denylist-term-0>  name:  \[denylist-term-0\]", out), out
    assert NAME not in out and TERM not in out


def test_empty_denylist_fails_ci_passes(base):
    dl = deny(base, "deny-empty.txt")
    tb = tar_of(base, "clean5.tar.gz", {"a.txt": "x\n"})
    code, out = run_gate(base, ["--tarball", tb], SHYN_LEAK_DENYLIST=dl)
    assert code == 1 and "no active terms" in out
    code, out = run_gate(base, ["--tarball", tb, "--ci"], SHYN_LEAK_DENYLIST=dl)
    assert code == 0, out
    assert "no active terms (--ci)" in out


def test_zero_files_fail_even_with_ci(base):
    d = tempfile.mkdtemp(prefix="emptyar-", dir=base)
    tb = tar_dir(base, "empty.tar.gz", d)
    assert run_gate(base, ["--tarball", tb])[0] == 1
    code, out = run_gate(base, ["--tarball", tb, "--ci"])
    assert code == 1
    assert "scanned 0 files" in out


def test_redaction_everywhere(base):
    d = tempfile.mkdtemp(prefix="hyg-", dir=base)
    write(os.path.join(d, "t.txt"), "acme-secret next to xAcme-SecretLy and acme-secret\n")
    # a term as a substring of a printed path (not itself a whole-word hit) is still hidden
    write(os.path.join(d, "sub-xacme-secretly", "u.txt"), "acme-secret\n")
    code, out = run_gate(base, ["--dir", d])
    assert code == 1
    assert "acme-secret" not in out.lower()
    assert "sub-x<denylist-term-0>ly" in out
    code, out = run_gate(base, ["--tarball", os.path.join(base, "missing-%s-ACME-secret.tar.gz" % NAME)])
    assert code == 2
    assert NAME not in out and "acme-secret" not in out.lower()
    assert "<username>" in out
    # the builder's home is redacted in error messages too
    code, out = run_gate(base, ["--dir", os.path.join(os.path.expanduser("~"), "no-such-dir-zq7")])
    assert code == 2
    assert os.path.expanduser("~") not in out and "<home>" in out


def test_clean_tarball_exact_summary(base):
    tb = tar_of(base, "clean.tar.gz", {"a.txt": "nothing\n", "d/b.txt": "to see\n", "d/e/c.bin": bytes([0, 1, 2, 3])})
    code, out = run_gate(base, ["--tarball", tb])
    assert code == 0, out
    assert summary(3, "0.0", 0, 0, 0, 0) in out
    assert "builder needles used: username, home, checkout" in out
    assert "denylist: 1 term(s)" in out


def _evil_tar(path, add):
    with tarfile.open(path, "w:gz") as tf:
        add(tf)
    return path


def _member(tf, name, data=b"escaped", **kw):
    ti = tarfile.TarInfo(name)
    for k, v in kw.items():
        setattr(ti, k, v)
    if ti.type == tarfile.REGTYPE:
        ti.size = len(data)
        tf.addfile(ti, io.BytesIO(data))
    else:
        tf.addfile(ti)


@pytest.mark.parametrize("kind", ["dotdot", "absolute", "newline", "backslash", "hardlink-dotdot", "through-symlink"])
def test_unsafe_entries_refused_nothing_written_outside(base, kind):
    work = tempfile.mkdtemp(prefix="esc-", dir=base)
    tb = os.path.join(work, "evil.tgz")

    def add(tf):
        _member(tf, "ok.txt", b"fine\n")
        if kind == "dotdot":
            _member(tf, "../payload")
        elif kind == "absolute":
            _member(tf, os.path.join(work, "abs-payload"))
        elif kind == "newline":
            _member(tf, "a\nb.txt")
        elif kind == "backslash":
            _member(tf, "a\\..\\b.txt")
        elif kind == "hardlink-dotdot":
            _member(tf, "hl", type=tarfile.LNKTYPE, linkname="../../etc/hosts")
        elif kind == "through-symlink":
            _member(tf, "up", type=tarfile.SYMTYPE, linkname=work)
            _member(tf, "up/through-payload")

    _evil_tar(tb, add)
    before = sorted(os.listdir(work))
    parent_before = sorted(os.listdir(base))
    code, out = run_gate(base, ["--tarball", tb])
    assert code == 1, out
    assert "refusing tarball" in out
    assert sorted(os.listdir(work)) == before
    assert sorted(os.listdir(base)) == parent_before


def test_corrupt_tarball_fails_and_cleans_up(base):
    tb = tar_of(base, "trunc-src.tar.gz", {"a.txt": "x" * 5000})
    with open(tb, "rb") as f:
        data = f.read()
    bad = write(os.path.join(base, "trunc.tar.gz"), data[: len(data) // 2])
    before = gate_dirs()
    code, out = run_gate(base, ["--tarball", bad])
    assert code == 1, out
    assert gate_dirs() == before


def test_unreadable_file_fails(base):
    if os.getuid() == 0:
        pytest.skip("root reads everything")
    d = tempfile.mkdtemp(prefix="unread-", dir=base)
    write(os.path.join(d, "ok.txt"), "fine\n")
    locked = write(os.path.join(d, "locked.txt"), "x\n")
    os.chmod(locked, 0)
    try:
        code, out = run_gate(base, ["--dir", d])
    finally:
        os.chmod(locked, 0o644)
    assert code == 1
    assert "hits 0, allowlisted 0, ignored binary noise 0, unreadable 1" in out
    assert "unreadable: locked.txt" in out


def test_missing_denylist_fails_ci_passes(base):
    tb = tar_of(base, "clean2.tar.gz", {"a.txt": "nothing\n"})
    missing = os.path.join(base, "no-such-denylist.txt")
    code, out = run_gate(base, ["--tarball", tb], SHYN_LEAK_DENYLIST=missing)
    assert code == 1 and "denylist missing" in out
    code, out = run_gate(base, ["--tarball", tb, "--ci"], SHYN_LEAK_DENYLIST=missing)
    assert code == 0, out
    assert "only the remaining builder checks ran" in out
    assert "builder needles used: checkout" in out


def test_invalid_regex_names_line_not_content(base):
    dl = deny(base, "deny-bad.txt", "fine-term", "bad(secret-regex")
    tb = tar_of(base, "clean3.tar.gz", {"a.txt": "nothing\n"})
    code, out = run_gate(base, ["--tarball", tb], SHYN_LEAK_DENYLIST=dl)
    assert code == 1
    assert "line(s): 3" in out
    assert "secret-regex" not in out


def test_print_caps_but_counts_all(base):
    d = tempfile.mkdtemp(prefix="caps-", dir=base)
    for i in range(12):
        write(os.path.join(d, "f%02d.txt" % i), "acme-secret\n" * 25)
    code, out = run_gate(base, ["--dir", d])
    assert code == 1
    assert "hits 300, " in out
    shown = [ln for ln in out.splitlines() if "[denylist-term-0]" in ln]
    assert len(shown) == 200
    assert sum(1 for ln in shown if "f00.txt" in ln) == 20
    assert "(100 more hit(s) not shown; all are counted)" in out


def test_temp_dir_removed_on_success_and_failure(base):
    before = gate_dirs()
    run_gate(base, ["--tarball", tar_of(base, "c4.tar.gz", {"a.txt": "x\n"})])
    run_gate(base, ["--tarball", tar_of(base, "h4.tar.gz", {"a.txt": "acme-secret\n"})])
    assert gate_dirs() == before


@pytest.mark.parametrize("sig,expected", [(signal.SIGINT, 130), (signal.SIGTERM, 143), (signal.SIGHUP, 129),
                                          (signal.SIGQUIT, 131)])
def test_signal_during_scan_cleans_up(base, sig, expected):
    files = {"f%d.txt" % i: "file %d\n" % i for i in range(40)}
    tb = tar_of(base, "slow-%d.tar.gz" % sig, files)
    before = gate_dirs()
    child = subprocess.Popen([sys.executable, GATE, "--tarball", tb], cwd=ROOT, stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, env=gate_env(base, SHYN_GATE_TEST_DELAY_MS="300"))
    try:
        deadline = time.monotonic() + 20
        out = b""
        while b"scanning tarball" not in out:
            assert time.monotonic() < deadline, "gate never started scanning"
            line = child.stdout.readline()
            assert line, "gate exited early: %r" % out
            out += line
        time.sleep(0.5)  # inside the per-file delay of the content scan
        assert gate_dirs() != before, "the temp dir should exist mid-scan"
        child.send_signal(sig)
        code = child.wait(timeout=10)
        assert code == expected
        assert gate_dirs() == before
    finally:
        child.kill()
        child.wait(timeout=5)
        child.stdout.close()


# --- signing ---------------------------------------------------------------


def _app_tar(base, name, dvv_text=None):
    d = tempfile.mkdtemp(prefix="app-", dir=base)
    write(os.path.join(d, "Fake.app", "Contents", "Info.plist"), "<plist/>\n")
    write(os.path.join(d, "Fake.app", "Contents", "MacOS", "Fake"), bytes([0xCF, 0xFA, 0, 0]) + b"clean")
    tb = tar_dir(base, name, d)
    dvv = None
    if dvv_text is not None:
        dvv = write(os.path.join(base, name + ".dvv"), dvv_text)
    return tb, dvv


def _codesign_calls(base):
    p = os.path.join(base, "codesign.log")
    if not os.path.exists(p):
        return []
    with open(p) as f:
        return f.read().splitlines()


def test_signing_allowlisted_authority_passes(base):
    tb, _ = _app_tar(base, "sig-ok.tar.gz")
    n = len(_codesign_calls(base))
    code, out = run_gate(base, ["--tarball", tb])
    assert code == 0, out
    assert "signing: tarball:Fake.app ok (Authority=Shyn Dev; TeamIdentifier=not set)" in out
    calls = _codesign_calls(base)[n:]
    assert any(c.startswith("--verify --strict --deep ") for c in calls)
    assert any(c.startswith("-dvv ") for c in calls)


PERSONAL = SHYN_DEV_DVV.replace("Authority=Shyn Dev",
                                "Authority=Apple Development: Someone Person (someone@example.com) (ABCDE12345)\n"
                                "Authority=Apple Worldwide Developer Relations Certification Authority\n"
                                "Authority=Apple Root CA").replace("TeamIdentifier=not set", "TeamIdentifier=ABCDE12345")


@pytest.mark.parametrize("label,dvv,reasons", [
    ("apple-development", PERSONAL, ["authority not allowed (<redacted>)", "TeamIdentifier set (<redacted>)"]),
    ("developer-id", SHYN_DEV_DVV.replace("Authority=Shyn Dev", "Authority=Developer ID Application: X (ABCDE12345)"),
     ["authority not allowed (<redacted>)"]),
    ("apple-distribution", SHYN_DEV_DVV.replace("Authority=Shyn Dev", "Authority=Apple Distribution: X (ABCDE12345)"),
     ["authority not allowed (<redacted>)"]),
    ("mac-developer", SHYN_DEV_DVV.replace("Authority=Shyn Dev", "Authority=Mac Developer: X (ABCDE12345)"),
     ["authority not allowed (<redacted>)"]),
    ("adhoc", SHYN_DEV_DVV.replace("Signature size=1663", "Signature=adhoc").replace("Authority=Shyn Dev\n", ""),
     ["ad-hoc signature"]),
    ("team-set", SHYN_DEV_DVV.replace("TeamIdentifier=not set", "TeamIdentifier=ABCDE12345"),
     ["TeamIdentifier set (<redacted>)"]),
    ("near-miss", SHYN_DEV_DVV.replace("Authority=Shyn Dev", "Authority=Shyn Dev2"),
     ["authority not allowed (<redacted>)"]),
], ids=lambda v: v if isinstance(v, str) and "\n" not in v else "")
def test_signing_rejections(base, label, dvv, reasons):
    tb, dvv_path = _app_tar(base, "sig-%s.tar.gz" % label, dvv)
    code, out = run_gate(base, ["--tarball", tb], FAKE_CODESIGN_DVV=dvv_path)
    assert code == 1, out
    for r in reasons:
        assert "tarball:Fake.app  signing:  %s" % r in out, out
    assert re.search(r"hits %d, " % len(reasons), out), out
    for secret in ["someone@example.com", "Someone", "ABCDE12345", "Developer ID", "Distribution", "Mac Developer", "Dev2"]:
        assert secret not in out


def test_signing_verify_failure(base):
    tb, _ = _app_tar(base, "sig-verify.tar.gz")
    code, out = run_gate(base, ["--tarball", tb], FAKE_CODESIGN_VERIFY_RC="1")
    assert code == 1
    assert "tarball:Fake.app  signing:  verification failed (codesign --verify --strict --deep exit 1)" in out


def test_signing_allowlist_override(base):
    tb, dvv = _app_tar(base, "sig-override.tar.gz",
                       SHYN_DEV_DVV.replace("Authority=Shyn Dev", "Authority=Neutral Test Identity"))
    assert run_gate(base, ["--tarball", tb], FAKE_CODESIGN_DVV=dvv)[0] == 1
    code, out = run_gate(base, ["--tarball", tb], FAKE_CODESIGN_DVV=dvv,
                         THATONE_ALLOWED_AUTHORITIES="Shyn Dev, Neutral Test Identity")
    assert code == 0, out


def test_signing_missing_codesign_fails_closed(base):
    tb, _ = _app_tar(base, "sig-nocs.tar.gz")
    before = gate_dirs()
    code, out = run_gate(base, ["--tarball", tb], THATONE_CODESIGN=os.path.join(base, "no-such-codesign"))
    assert code == 1
    assert "codesign not found" in out and "failing closed" in out
    assert gate_dirs() == before


def test_signing_dir_target_that_is_itself_an_app(base):
    d = tempfile.mkdtemp(prefix="appdir-", dir=base)
    app = os.path.join(d, "Fake.app")
    write(os.path.join(app, "Contents", "Info.plist"), "<plist/>\n")
    nested = os.path.join(app, "Contents", "Frameworks", "Lib.framework")
    write(os.path.join(nested, "Lib"), "x")
    dvv = write(os.path.join(base, "dirapp.dvv"), PERSONAL)
    code, out = run_gate(base, ["--dir", app], FAKE_CODESIGN_DVV=dvv)
    assert code == 1
    assert "dir:Fake.app  signing:  authority not allowed (<redacted>)" in out
    assert "dir:Contents/Frameworks/Lib.framework  signing:  authority not allowed (<redacted>)" in out
    assert "example.com" not in out


# --- the env discipline itself -----------------------------------------------


def test_every_spawn_uses_gate_env(base):
    """Every subprocess call that runs the gate (sys.executable or GATE in its argv) passes env=gate_env(...)."""
    tree = ast.parse(open(os.path.abspath(__file__)).read())
    spawns, with_env = 0, 0
    for node in ast.walk(tree):
        if not (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                and isinstance(node.func.value, ast.Name) and node.func.value.id == "subprocess"):
            continue
        names = {n.id for a in node.args for n in ast.walk(a) if isinstance(n, ast.Name)}
        attrs = {n.attr for a in node.args for n in ast.walk(a) if isinstance(n, ast.Attribute)}
        if "GATE" not in names and "executable" not in attrs:
            continue
        spawns += 1
        for kw in node.keywords:
            if kw.arg == "env" and isinstance(kw.value, ast.Call) and getattr(kw.value.func, "id", "") == "gate_env":
                with_env += 1
    assert spawns >= 2
    assert with_env == spawns
    env = gate_env(base)
    for k in ["SHYN_GATE_USERNAME", "SHYN_LEAK_DENYLIST", "SHYN_ARTIFACT_ALLOW", "THATONE_ALLOWED_AUTHORITIES"]:
        assert env[k]
    assert env["SHYN_LEAK_DENYLIST"].startswith(base) and env["SHYN_ARTIFACT_ALLOW"].startswith(base)
    assert env["THATONE_CODESIGN"] == os.path.join(base, "shim", "codesign")
    assert os.access(env["THATONE_CODESIGN"], os.X_OK)


def test_contexts_never_show_signing_identity(base):
    # a hit near an embedded certificate (as in a _CodeSignature blob) must not print the team id or email
    # around it, even though neither is a denylist term: the signing check's team id and disallowed
    # authorities, any email address and any "(10-char team id)" are redacted in every printed string
    d = tempfile.mkdtemp(prefix="certctx-", dir=base)
    app = os.path.join(d, "Fake.app")
    write(os.path.join(app, "Contents", "_CodeSignature", "CodeResources"),
          # each value sits within a context's reach of a hit
          "<string>Apple Development: acme-secret@example.com (ABCDE12345)</string>\n"
          "OU=ABCDE12345 acme-secret (QWERTY6789)\n"
          "other@mail.example.org acme-secret UID=ZX12CV34BN\n"
          "\x0c\x0aWQ12ER34TY1<0 acme-secret Zorp Person\n")
    dvv = write(os.path.join(base, "certctx.dvv"), PERSONAL)
    # the leaf certificate as `codesign --extract-certificates` writes it: DER string fields (a UID glued
    # to the next DER tag byte "1", which no shape regex can isolate, and a person's name)
    cert = write(os.path.join(base, "certctx.der"), b"\x30\x82\x05\xc9\x31\x1a\x30\x18\x06\x0a\x09\x92"
                 b"\x0c\x0aWQ12ER34TY\x31\x13\x0c\x0bZorp Person\x31\x0b")
    code, out = run_gate(base, ["--dir", app], FAKE_CODESIGN_DVV=dvv, FAKE_CODESIGN_CERT=cert)
    assert code == 1
    assert "[denylist-term-0]" in out
    for secret in ["ABCDE12345", "QWERTY6789", "ZX12CV34BN", "WQ12ER34TY", "Zorp", "example.com", "example.org", "Someone", "acme-secret"]:
        assert secret not in out, secret
    assert "<team-id>" in out and "<email>" in out


# --- fix round 1: every code item, identities redacted before printing, hardened extraction -----------

MACHO = b"\xcf\xfa\xed\xfe"  # 0xfeedfacf, little-endian on disk

# a personal signer, all synthetic
ZQ7_DVV = SHYN_DEV_DVV.replace(
    "Authority=Shyn Dev", "Authority=Apple Development: zq7-person@zq7mail.example (ZQ7TEAM123)\n"
    "Authority=Apple Worldwide Developer Relations Certification Authority").replace(
    "TeamIdentifier=not set", "TeamIdentifier=ZQ7TEAM123")
ZQ7_CERT = (b"\x30\x82\x05\xc9\x31\x1a\x30\x18\x06\x0a\x09\x92\x0c\x0aZQ7UID4567\x31\x13"
            b"\x0c\x0bZq7 Persona\x31\x0b\x30\x09\x06\x03\x55\x04\x0b\x0c\x0aZQ7TEAM123\x31")
ZQ7_SECRETS = ["zq7-person", "zq7mail", "ZQ7TEAM123", "ZQ7UID4567", "Zq7 Persona", "Apple Development"]


def _personal(base, **extra):
    dvv = write(os.path.join(base, "zq7.dvv"), ZQ7_DVV)
    cert = write(os.path.join(base, "zq7.der"), ZQ7_CERT)
    env = {"FAKE_CODESIGN_ALT_DVV": dvv, "FAKE_CODESIGN_ALT_CERT": cert}
    env.update(extra)
    return env


def test_uppercase_app_suffix_is_a_bundle(base):
    d = tempfile.mkdtemp(prefix="upper-", dir=base)
    write(os.path.join(d, "ThatOne.APP", "Contents", "Info.plist"), "<plist/>\n")
    tb = tar_dir(base, "upper.tar.gz", d, app=False)
    code, out = run_gate(base, ["--tarball", tb], **_personal(base, FAKE_CODESIGN_ALT_MATCH="ThatOne.APP"))
    assert code == 1, out
    assert "tarball:ThatOne.APP  signing:  authority not allowed (<redacted>)" in out
    assert "no .app bundle" not in out


def test_symlinked_app_is_a_hit(base):
    d = tempfile.mkdtemp(prefix="symapp-", dir=base)
    write(os.path.join(d, "Real", "Contents", "Info.plist"), "<plist/>\n")
    os.symlink("Real", os.path.join(d, "ThatOne.app"))
    tb = tar_dir(base, "symapp.tar.gz", d, app=False)
    code, out = run_gate(base, ["--tarball", tb])
    assert code == 1, out
    assert "tarball:ThatOne.app  signing:  bundle is a symlink" in out
    assert "signing:  no .app bundle in the tarball" in out


def test_tarball_without_app_is_a_hit(base):
    tb = tar_of(base, "noapp.tar.gz", {"a.txt": "nothing\n"}, app=False)
    code, out = run_gate(base, ["--tarball", tb])
    assert code == 1
    assert "signing:  no .app bundle in the tarball" in out
    assert "hits 1, " in out


@pytest.mark.parametrize("rel", ["Fake.app/Contents/XPCServices/Helper.xpc", "Fake.app/Contents/PlugIns/Ext.APPEX",
                                 "Fake.app/Contents/Library/X.bundle", "Fake.app/Contents/Library/Y.plugin",
                                 "Fake.app/Contents/Library/Z.kext", "Fake.app/Contents/Library/S.systemextension"])
def test_nested_personally_signed_bundle_is_a_hit(base, rel):
    d = tempfile.mkdtemp(prefix="nested-", dir=base)
    write(os.path.join(d, rel, "Contents", "Info.plist"), "<plist/>\n")
    tb = tar_dir(base, "nested.tar.gz", d)
    match = rel.rsplit("/", 1)[1]
    code, out = run_gate(base, ["--tarball", tb], **_personal(base, FAKE_CODESIGN_ALT_MATCH=match))
    assert code == 1, out
    assert "tarball:%s  signing:  authority not allowed (<redacted>)" % rel in out
    assert "signing: tarball:Fake.app ok" in out


def test_non_bundle_macho_signed_personally_is_a_hit_and_redacted(base):
    # a dylib and a helper tool outside any bundle; one is signed personally and sits next to its own
    # certificate strings and a denylist hit: nothing of the identity may be printed
    d = tempfile.mkdtemp(prefix="macho-", dir=base)
    blob = (MACHO + b"\x00" * 12 + b"acme-secret \x0c\x0aZQ7UID45671<0 Apple Development: zq7-person@zq7mail.example "
            b"(ZQ7TEAM123)\x00 OU ZQ7TEAM1231 Zq7 Persona\x00")
    write(os.path.join(d, "lib", "libzq.dylib"), blob)
    write(os.path.join(d, "bin", "tool"), b"\xca\xfe\xba\xbe" + b"\x00" * 20)
    n = len(_codesign_calls(base))
    code, out = run_gate(base, ["--dir", d], **_personal(base, FAKE_CODESIGN_ALT_MATCH="libzq"))
    assert code == 1, out
    assert "dir:lib/libzq.dylib  signing:  authority not allowed (<redacted>)" in out
    assert "dir:lib/libzq.dylib  signing:  TeamIdentifier set (<redacted>)" in out
    assert "signing: dir:bin/tool ok" in out
    assert "[denylist-term-0]" in out
    for secret in ZQ7_SECRETS:
        assert secret not in out, secret
    calls = _codesign_calls(base)[n:]
    assert any(c.startswith("-dvv ") and c.endswith("lib/libzq.dylib") for c in calls)
    assert any(c.startswith("-dvv ") and c.endswith("bin/tool") for c in calls)


@pytest.mark.parametrize("magic", [b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
                                   b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"])
def test_every_macho_magic_is_checked(base, magic):
    d = tempfile.mkdtemp(prefix="magic-", dir=base)
    write(os.path.join(d, "x"), magic + b"\x00" * 8)
    write(os.path.join(d, "notmacho"), b"\xcf\xfa\x00\x00" + b"\x00" * 8)
    code, out = run_gate(base, ["--dir", d], FAKE_CODESIGN_VERIFY_RC="1")
    assert code == 1
    assert "dir:x  signing:  verification failed" in out
    assert "notmacho  signing" not in out


def test_marker_runs_redacted_without_any_signing_data(base):
    # identity strings in content the signing check never saw (the shim says "Shyn Dev"): the printable run
    # holding the marker and any team-id-shaped token near it are redacted, even glued to a DER tag byte
    d = tempfile.mkdtemp(prefix="marker-", dir=base)
    write(os.path.join(d, "blob.bin"), b"\x00\x01acme-secret\x02\x03Developer ID Application: Zq7 Persona (ZQ7TEAM123)"
          b"\x0c\x0aZQ7UID45671<0\x00Mac Developer: zq7-person\x00Apple Distribution: Zq7 Persona\x00")
    code, out = run_gate(base, ["--dir", d])
    assert code == 1
    assert "[denylist-term-0]" in out
    for secret in ZQ7_SECRETS + ["Developer ID", "Mac Developer", "Distribution"]:
        assert secret not in out, secret


def test_default_codesign_is_the_system_one(base):
    # explicitly the real /usr/bin/codesign (read-only verify of a synthetic, unsigned bundle): it fails
    tb = tar_of(base, "realcs.tar.gz", {"a.txt": "x\n"})
    code, out = run_gate(base, ["--tarball", tb], THATONE_CODESIGN="/usr/bin/codesign")
    assert code == 1
    assert "tarball:Fake.app  signing:  " in out
    code, out = run_gate(base, ["--help"])
    assert "/usr/bin/codesign" in out and "THATONE_CODESIGN" in out


def test_duplicate_members_refused(base):
    tb = os.path.join(base, "dup.tgz")

    def add(tf):
        _member(tf, "Fake.app/", type=tarfile.DIRTYPE)
        _member(tf, "a.txt", b"first\n")
        _member(tf, "./a.txt", b"second\n")

    _evil_tar(tb, add)
    code, out = run_gate(base, ["--tarball", tb])
    assert code == 1
    assert "refusing tarball" in out and "duplicate" in out


def test_gzip_header_name_is_scanned(base):
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w") as tf:
        _member(tf, "Fake.app/", type=tarfile.DIRTYPE)
        _member(tf, "a.txt", b"clean\n")
    import gzip
    tb = os.path.join(base, "fname.tar.gz")
    with open(tb, "wb") as f, gzip.GzipFile(filename="%s-out.tar" % NAME, mode="wb", fileobj=f) as g:
        g.write(raw.getvalue())
    code, out = run_gate(base, ["--tarball", tb])
    assert code == 1, out
    assert re.search(r"tarball-gz:gzip file  @\d+  \[username\]", out), out
    assert NAME not in out


@pytest.mark.parametrize("mode", [0o555, 0o000])
def test_readonly_and_locked_dirs_leave_no_temp_dir(base, mode):
    tb = os.path.join(base, "ro-%o.tgz" % mode)

    def add(tf):
        _member(tf, "Fake.app/", type=tarfile.DIRTYPE)
        _member(tf, "ro/", type=tarfile.DIRTYPE, mode=mode)
        _member(tf, "ro/inner/", type=tarfile.DIRTYPE, mode=mode)
        _member(tf, "ro/inner/f.txt", b"x\n")

    _evil_tar(tb, add)
    before = gate_dirs()
    code, out = run_gate(base, ["--tarball", tb])
    if mode == 0:
        assert code == 1  # unreadable content
    assert gate_dirs() == before


def test_damaged_header_fails_and_cleans_up(base):
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.USTAR_FORMAT) as tf:
        _member(tf, "Fake.app/", type=tarfile.DIRTYPE)
        _member(tf, "a.txt", b"one\n")
        _member(tf, "b.txt", b"two\n")
        _member(tf, "c.txt", b"three\n")
    data = bytearray(raw.getvalue())
    off = data.find(b"b.txt")
    data[off + 148:off + 156] = b"0000000\x00"  # wrong checksum on the third header
    import gzip
    tb = write(os.path.join(base, "damaged.tar.gz"), gzip.compress(bytes(data)))
    before = gate_dirs()
    code, out = run_gate(base, ["--tarball", tb])
    assert code == 1, out
    assert gate_dirs() == before


def _gate_module():
    import importlib.util
    spec = importlib.util.spec_from_file_location("check_artifact_leaks", GATE)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def test_extracted_tree_must_equal_the_listing(base):
    mod = _gate_module()
    d = tempfile.mkdtemp(prefix="tree-", dir=base)
    write(os.path.join(d, "a", "b.txt"), "x")
    os.symlink("b.txt", os.path.join(d, "a", "l"))
    assert mod.compare_extracted(d, ["./", "a/", "a/b.txt", "a/l"]) == []
    assert mod.compare_extracted(d, ["a/b.txt", "a/l"]) == []  # parents are implied
    probs = mod.compare_extracted(d, ["a/b.txt"])
    assert len(probs) == 1 and "1 extra" in probs[0]
    probs = mod.compare_extracted(d, ["a/b.txt", "a/l", "a/missing.txt"])
    assert len(probs) == 1 and "1 missing" in probs[0]
    os.mkfifo(os.path.join(d, "fifo"))
    probs = mod.compare_extracted(d, ["a/b.txt", "a/l", "fifo"])
    assert any("not a regular file, directory or symlink" in p for p in probs)


@pytest.mark.parametrize("python", [sys.executable, "/usr/bin/python3"], ids=["test-python", "system-python3"])
def test_regex_warning_makes_line_invalid(base, python):
    if not os.path.exists(python):
        pytest.skip("no system python3")
    dl = deny(base, "deny-warn.txt", "fine-term", "[[secret-warn]x")  # FutureWarning: possible nested set
    tb = tar_of(base, "clean-warn.tar.gz", {"a.txt": "x\n"})
    r = subprocess.run([python, GATE, "--tarball", tb], cwd=ROOT, capture_output=True, text=True, timeout=TIMEOUT,
                       env=gate_env(base, SHYN_LEAK_DENYLIST=dl))
    out = r.stdout + r.stderr
    assert r.returncode == 1, out
    assert "line(s): 3" in out
    assert "secret-warn" not in out and "Warning" not in out


def test_appledouble_members_fail_closed(base):
    # a tarball made without COPYFILE_DISABLE carries "._x" AppleDouble members; bsdtar swallows them on
    # extraction, so the tree no longer equals the listing (a hit), and the raw stream still sees their bytes
    tb = os.path.join(base, "adbl.tgz")

    def add(tf):
        _member(tf, "Fake.app/", type=tarfile.DIRTYPE)
        _member(tf, "._a.txt", b"\x00\x05\x16\x07 /Users/%s/where-from\n" % NAME.encode())
        _member(tf, "a.txt", b"x\n")

    _evil_tar(tb, add)
    code, out = run_gate(base, ["--tarball", tb])
    assert code == 1, out
    assert "tarball:<extraction>  extraction:  extracted tree differs from the listing: 1 missing, 0 extra" in out
    assert re.search(r"tarball-raw:raw stream  @\d+  \[username\]", out), out
    assert NAME not in out


# --------------------------------------------------------------------------
# sha256 line and test-override warning
# --------------------------------------------------------------------------


def test_prints_sha256_of_the_scanned_archive(base):
    import hashlib
    t = tar_of(base, "sha.tar.gz", {"a.txt": "hello"})
    rc, out = run_gate(base, ["--tarball", t])
    assert rc == 0, out
    with open(t, "rb") as f:
        want = hashlib.sha256(f.read()).hexdigest()
    assert "sha256: %s" % want in out.splitlines()


@pytest.mark.parametrize("hook,value", [("THATONE_CODESIGN", None), ("SHYN_GATE_USERNAME", None),
                                        ("SHYN_GATE_TEST_DELAY_MS", "1")])
def test_test_override_warning_names_hook_never_value(base, hook, value):
    t = tar_of(base, "warn.tar.gz", {"a.txt": "hello"})
    extra = {hook: value} if value else {}
    rc, out = run_gate(base, ["--tarball", t], **extra)
    assert rc == 0, out
    assert "WARNING: test override active: %s" % hook in out.splitlines()
    for v in (NAME, os.path.join(base, "shim", "codesign")):
        assert v not in out


# --------------------------------------------------------------------------
# build-app.sh --release: rename flow, early identity check, hooks stripped
# --------------------------------------------------------------------------

BUILD_SH = os.path.join(ROOT, "app", "scripts", "build-app.sh")
PACKAGE_SH = os.path.join(ROOT, "app", "scripts", "package-release.sh")
SECURITY_SHIM = """#!/bin/sh
echo '  1) 0123456789ABCDEF0123456789ABCDEF01234567 "Shyn Dev" (CSSMERR_TP_NOT_TRUSTED)'
echo '  2) 89ABCDEF0123456789ABCDEF0123456789ABCDEF "Other Authority" (CSSMERR_TP_NOT_TRUSTED)'
"""
SWIFT_SHIM = """#!/bin/sh
echo "swift $*" >> "$FAKE_LOG"
for a; do [ "$a" = "--show-bin-path" ] && { echo "$FAKE_BINDIR"; exit 0; }; done
exit 0
"""
STUB_GATE = """import os, sys
with open(os.environ["STUB_GATE_SEEN"], "w") as f:
    f.write(" ".join(sorted(k for k in ("THATONE_CODESIGN", "SHYN_GATE_USERNAME", "SHYN_GATE_TEST_DELAY_MS",
                                        "THATONE_GATE") if k in os.environ)) + "\\n" + " ".join(sys.argv[1:]) + "\\n"
            + "isolated=%d\\n" % sys.flags.isolated)
sys.exit(int(os.environ["STUB_GATE_RC"]))
"""
ALWAYS_OK = "import sys\nsys.exit(0)\n"
FAKE_PY3 = '#!/bin/sh\necho "fake python3 $*" >> "$FAKE_PY3_LOG"\nexit 0\n'


@pytest.fixture()
def rel(base):
    d = tempfile.mkdtemp(prefix="rel-", dir=base)
    for sub in ("app/scripts", "app/Resources", "engine/scripts", "shim", "bin/SQLCipher.framework"):
        os.makedirs(os.path.join(d, sub))
    for src in (BUILD_SH, PACKAGE_SH):
        shutil.copy(src, os.path.join(d, "app", "scripts"))
    write(os.path.join(d, "app/Resources/Info.plist"),
          '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleShortVersionString</key>'
          '<string>9.9.9</string></dict></plist>')
    write(os.path.join(d, "engine/scripts/fetch-sqlcipher.sh"), "#!/bin/sh\nexit 0\n")
    write(os.path.join(d, "bin/ThatOne"), "bin")
    for n, body in (("swift", SWIFT_SHIM), ("security", SECURITY_SHIM), ("codesign", "#!/bin/sh\nexit 0\n"),
                    ("install_name_tool", "#!/bin/sh\nexit 0\n")):
        write(os.path.join(d, "shim", n), body)
    for p in ("shim/swift", "shim/security", "shim/codesign", "shim/install_name_tool", "engine/scripts/fetch-sqlcipher.sh",
              "app/scripts/build-app.sh", "app/scripts/package-release.sh"):
        os.chmod(os.path.join(d, p), 0o755)
    write(os.path.join(d, "scripts", "check-artifact-leaks.py"), STUB_GATE)  # the fixed gate path
    write(os.path.join(d, "always-ok.py"), ALWAYS_OK)
    return d


def run_build(rel, gate_rc, **extra):
    env = dict(os.environ)
    for k in ("THATONE_RELEASE_IDENTITY", "THATONE_SIGN_IDENTITY", "THATONE_ALLOWED_AUTHORITIES", "THATONE_GATE",
              "SHYN_LEAK_DENYLIST", "SHYN_ARTIFACT_ALLOW"):
        env.pop(k, None)
    env.update({
        "PATH": os.path.join(rel, "shim") + ":" + os.environ["PATH"],
        "FAKE_LOG": os.path.join(rel, "fake.log"), "FAKE_BINDIR": os.path.join(rel, "bin"),
        "STUB_GATE_RC": str(gate_rc), "STUB_GATE_SEEN": os.path.join(rel, "gate-seen.txt"),
        "FAKE_PY3_LOG": os.path.join(rel, "fake-py3.log"),
        "THATONE_CODESIGN": "/nonexistent-fake", "SHYN_GATE_USERNAME": NAME, "SHYN_GATE_TEST_DELAY_MS": "5",
        "HOME": pwd.getpwuid(os.getuid()).pw_dir,  # a release refuses any other HOME
    })
    for k in [k for k in env if k in ("BASH_ENV", "ENV", "SHELLOPTS", "BASHOPTS", "PS4") or k.startswith("BASH_FUNC_")]:
        env.pop(k)
    args = extra.pop("_args", ["--release"])
    env.update(extra)
    r = subprocess.run(["/bin/bash", os.path.join(rel, "app/scripts/build-app.sh")] + args, cwd=rel,
                       capture_output=True, text=True, timeout=TIMEOUT, env=env)
    return r.returncode, r.stdout + r.stderr


def pkg(rel):
    return os.path.join(rel, "dist", "release", "ThatOne-v9.9.9-darwin-arm64.tar.gz")


def test_release_package_named_only_after_gate_passes(rel):
    rc, out = run_build(rel, 0)
    assert rc == 0, out
    assert os.path.isfile(pkg(rel)) and not os.path.exists(pkg(rel) + ".partial")
    assert not os.path.exists(pkg(rel) + ".rejected")
    seen = open(os.path.join(rel, "gate-seen.txt")).read().splitlines()
    assert seen[0] == ""  # no test hook (nor THATONE_GATE) reached the gate
    assert seen[1].endswith("ThatOne-v9.9.9-darwin-arm64.tar.gz.partial") and seen[1].startswith("--release --tarball ")
    assert seen[2] == "isolated=1"  # /usr/bin/python3 -I
    assert "NOTICE" not in out


def test_release_rejected_package_never_keeps_the_publish_name(rel):
    rc, out = run_build(rel, 0)
    assert rc == 0, out  # an earlier, gated package exists
    rc, out = run_build(rel, 1)
    assert rc == 1, out
    assert os.path.isfile(pkg(rel) + ".rejected")
    assert not os.path.exists(pkg(rel)) and not os.path.exists(pkg(rel) + ".partial")
    assert "not releasing" in out


def test_release_identity_refused_before_swift(rel):
    log = os.path.join(rel, "fake.log")
    for env in ({"THATONE_RELEASE_IDENTITY": "Other Authority"},):
        rc, out = run_build(rel, 0, **env)
        assert rc == 1, out
        assert "THATONE_RELEASE_IDENTITY" in out and "THATONE_ALLOWED_AUTHORITIES" in out
        assert not os.path.exists(log) and not os.path.exists(pkg(rel))
    # allowed when listed (exact, comma separated); THATONE_SIGN_IDENTITY is ignored by --release
    rc, out = run_build(rel, 0, THATONE_RELEASE_IDENTITY="Other Authority",
                        THATONE_ALLOWED_AUTHORITIES="Shyn Dev, Other Authority")
    assert rc == 0, out
    os.remove(log)
    rc, out = run_build(rel, 0, THATONE_SIGN_IDENTITY="Other Authority")
    assert rc == 0, out
    assert "signed with \"Shyn Dev\"" in out


# --------------------------------------------------------------------------
# residual fix: fixed gate path and interpreter, allowlist and environment overrides
# --------------------------------------------------------------------------


def test_release_ignores_exported_thatone_gate(rel):
    # an exported THATONE_GATE pointing at a gate that always passes must not replace the real one
    rc, out = run_build(rel, 1, THATONE_GATE=os.path.join(rel, "always-ok.py"))
    assert rc == 1, out
    assert os.path.isfile(pkg(rel) + ".rejected")
    assert not os.path.exists(pkg(rel)) and not os.path.exists(pkg(rel) + ".partial")


def test_release_gate_never_uses_python3_on_path(rel):
    write(os.path.join(rel, "shim", "python3"), FAKE_PY3)
    os.chmod(os.path.join(rel, "shim", "python3"), 0o755)
    rc, out = run_build(rel, 1)
    assert rc == 1, out  # the fake would have passed
    assert os.path.isfile(pkg(rel) + ".rejected") and not os.path.exists(pkg(rel))
    assert not os.path.exists(os.path.join(rel, "fake-py3.log"))
    rc, out = run_build(rel, 0)
    assert rc == 0, out
    assert not os.path.exists(os.path.join(rel, "fake-py3.log"))
    assert open(os.path.join(rel, "gate-seen.txt")).read().splitlines()[2] == "isolated=1"


@pytest.mark.parametrize("value", ["", " ", ",", " , ,"], ids=["empty", "space", "comma", "commas-spaces"])
def test_release_empty_allowlist_refused_before_swift(rel, value):
    rc, out = run_build(rel, 0, THATONE_ALLOWED_AUTHORITIES=value)
    assert rc == 1, out
    assert "THATONE_ALLOWED_AUTHORITIES" in out and "no entries" in out
    assert not os.path.exists(os.path.join(rel, "fake.log")) and not os.path.exists(pkg(rel))


def test_release_allowlist_notice_counts_never_names(rel):
    rc, out = run_build(rel, 0, THATONE_ALLOWED_AUTHORITIES="Shyn Dev, Other Authority,")
    assert rc == 0, out
    notice = [ln for ln in out.splitlines() if ln.startswith("NOTICE:")]
    assert notice == ["NOTICE: signing authorities set by THATONE_ALLOWED_AUTHORITIES (2 entries)"], out
    # unset: the default, no notice
    rc, out = run_build(rel, 0)
    assert rc == 0, out
    assert "NOTICE" not in out


@pytest.mark.parametrize("var", ["SHYN_LEAK_DENYLIST", "SHYN_ARTIFACT_ALLOW"])
@pytest.mark.parametrize("value", ["", "zq7-override-path"], ids=["empty", "value"])
def test_release_refuses_private_config_override_before_swift(rel, var, value):
    rc, out = run_build(rel, 0, **{var: value})
    assert rc == 1, out
    assert var in out and (not value or value not in out)
    assert not os.path.exists(os.path.join(rel, "fake.log")) and not os.path.exists(pkg(rel))


def test_release_refuses_runner_home_before_swift(rel):
    rc, out = run_build(rel, 0, HOME="/Users/runner")
    assert rc == 1, out
    assert "CI mode" in out
    assert not os.path.exists(os.path.join(rel, "fake.log")) and not os.path.exists(pkg(rel))


def test_release_refuses_foreign_home_before_swift(rel):
    home = tempfile.mkdtemp(prefix="home-", dir=rel)
    rc, out = run_build(rel, 0, HOME=home)
    assert rc == 1, out
    assert "HOME is not this user's home dir" in out and home not in out
    assert not os.path.exists(os.path.join(rel, "fake.log")) and not os.path.exists(pkg(rel))


ENV_FN = "() { exit 0; }"


@pytest.mark.parametrize("kind", ["bash_env", "bash_env_full_path_function", "env_var", "exported_function",
                                  "exported_builtin_function", "shellopts", "bashopts", "ps4"])
def test_release_refuses_command_replacing_shell_environment(rel, kind):
    startup = write(os.path.join(rel, "startup.sh"), "env() { exit 0; }\n")
    full = write(os.path.join(rel, "startup-full.sh"), "/usr/bin/env() { exit 0; }\n")
    # an exported `builtin` used to hide every other function from `builtin declare -F`
    extra = {"bash_env": {"BASH_ENV": startup}, "bash_env_full_path_function": {"BASH_ENV": full},
             "env_var": {"ENV": startup}, "exported_function": {"BASH_FUNC_env%%": ENV_FN},
             "exported_builtin_function": {"BASH_FUNC_builtin%%": ENV_FN, "BASH_FUNC_env%%": ENV_FN},
             "shellopts": {"SHELLOPTS": "braceexpand:hashall:interactive-comments:xtrace"},
             "bashopts": {"BASHOPTS": "extglob"}, "ps4": {"PS4": "+ "}}[kind]
    rc, out = run_build(rel, 1, **extra)
    assert rc == 1, out
    assert "BASH_ENV, ENV, an exported shell function or inherited shell options" in out
    assert not os.path.exists(os.path.join(rel, "fake.log"))
    assert not os.path.exists(pkg(rel)) and not os.path.exists(pkg(rel) + ".partial")


def test_release_decision_tools_never_come_from_path(rel):
    # env, mv and tail first on PATH that would pass the build (or misplace the package) are never used
    log = os.path.join(rel, "fake-tools.log")
    for n in ("env", "mv", "tail"):
        write(os.path.join(rel, "shim", n), '#!/bin/sh\necho "fake %s" >> "%s"\nexit 0\n' % (n, log))
        os.chmod(os.path.join(rel, "shim", n), 0o755)
    rc, out = run_build(rel, 1)
    assert rc == 1, out
    assert os.path.isfile(pkg(rel) + ".rejected") and not os.path.exists(pkg(rel))
    rc, out = run_build(rel, 0)
    assert rc == 0, out
    assert os.path.isfile(pkg(rel)) and not os.path.exists(pkg(rel) + ".partial")
    assert not os.path.exists(log)


def test_release_refuses_ci_flag(rel):
    rc, out = run_build(rel, 0, _args=["--release", "--ci"])
    assert rc == 2, out
    assert not os.path.exists(os.path.join(rel, "fake.log"))


# --- the gate's side ----------------------------------------------------------


@pytest.mark.parametrize("value", ["", " ", ",", " , ,"], ids=["empty", "space", "comma", "commas-spaces"])
def test_gate_empty_allowlist_is_usage_error(base, value):
    tb = tar_of(base, "auth-empty.tar.gz", {"a.txt": "x\n"})
    code, out = run_gate(base, ["--tarball", tb], THATONE_ALLOWED_AUTHORITIES=value)
    assert code == 2, out
    assert "THATONE_ALLOWED_AUTHORITIES" in out


def test_gate_allowlist_notice_and_default(base):
    tb, dvv = _app_tar(base, "auth-notice.tar.gz",
                       SHYN_DEV_DVV.replace("Authority=Shyn Dev", "Authority=Neutral Test Identity"))
    code, out = run_gate(base, ["--tarball", tb], FAKE_CODESIGN_DVV=dvv,
                         THATONE_ALLOWED_AUTHORITIES="Shyn Dev, Neutral Test Identity")
    assert code == 0, out
    notice = [ln for ln in out.splitlines() if ln.startswith("NOTICE: signing")]
    assert notice == ["NOTICE: signing authorities set by THATONE_ALLOWED_AUTHORITIES (2 entries)"]
    # unset means the default "Shyn Dev": no notice, and the default identity passes
    tb2 = tar_of(base, "auth-default.tar.gz", {"a.txt": "x\n"})
    code, out = run_gate(base, ["--tarball", tb2], THATONE_ALLOWED_AUTHORITIES=None)
    assert code == 0, out
    assert "NOTICE: signing" not in out
    assert "signing: allowed authorities: Shyn Dev" in out


def _release_home(base):
    """A temp home holding a synthetic denylist at the default location (no allowlist)."""
    home = tempfile.mkdtemp(prefix="home-", dir=base)
    write(os.path.join(home, ".config", "shyn", "leak-denylist.txt"), "# synthetic\n" + TERM + "\n")
    return home


def _release_env(base, **extra):
    env = {"HOME": _release_home(base), "SHYN_LEAK_DENYLIST": None, "SHYN_ARTIFACT_ALLOW": None,
           "THATONE_ALLOWED_AUTHORITIES": None}
    env.update(extra)
    return env


def test_gate_release_clean_environment_passes_without_notices(base):
    tb = tar_of(base, "rel-clean.tar.gz", {"a.txt": "x\n"})
    code, out = run_gate(base, ["--release", "--tarball", tb], **_release_env(base))
    assert code == 0, out
    assert "NOTICE" not in out
    assert "denylist: 1 term(s)" in out
    tb2 = tar_of(base, "rel-hit.tar.gz", {"a.txt": TERM + "\n"})
    assert run_gate(base, ["--release", "--tarball", tb2], **_release_env(base))[0] == 1


@pytest.mark.parametrize("var", ["SHYN_LEAK_DENYLIST", "SHYN_ARTIFACT_ALLOW"])
@pytest.mark.parametrize("empty", [False, True], ids=["value", "empty"])
def test_gate_release_refuses_private_config_override(base, var, empty):
    tb = tar_of(base, "rel-ovr.tar.gz", {"a.txt": "x\n"})
    value = "" if empty else os.path.join(base, "zq7-override.txt")
    code, out = run_gate(base, ["--release", "--tarball", tb], **_release_env(base, **{var: value}))
    assert code == 2, out
    assert var in out and "--release" in out
    assert empty or value not in out
    assert "scanning" not in out


def test_gate_release_refuses_ci_flag_and_runner_home(base):
    tb = tar_of(base, "rel-ci.tar.gz", {"a.txt": "x\n"})
    code, out = run_gate(base, ["--release", "--ci", "--tarball", tb], **_release_env(base))
    assert code == 2, out
    assert "--ci" in out and "scanning" not in out
    code, out = run_gate(base, ["--release", "--tarball", tb], **_release_env(base, HOME="/Users/runner"))
    assert code == 2, out
    assert "CI mode" in out and "scanning" not in out


def test_gate_notices_outside_release(base):
    tb = tar_of(base, "notice.tar.gz", {"a.txt": "x\n"})
    al = allow(base, "al-notice.txt", "a.txt|" + TERM)
    code, out = run_gate(base, ["--tarball", tb], SHYN_ARTIFACT_ALLOW=al)
    assert code == 0, out
    lines = out.splitlines()
    assert "NOTICE: SHYN_LEAK_DENYLIST overrides the default" in lines
    assert "NOTICE: SHYN_ARTIFACT_ALLOW overrides the default" in lines
    assert "NOTICE: CI mode on (GitHub runner home detected)" not in lines
    assert al not in out and os.path.join(base, "deny-acme.txt") not in out
    code, out = run_gate(base, ["--tarball", tb], HOME="/Users/runner")
    assert code == 0, out
    assert "NOTICE: CI mode on (GitHub runner home detected)" in out.splitlines()
    # without overrides and outside CI: none of these notices
    code, out = run_gate(base, ["--tarball", tb], **_release_env(base))
    assert code == 0, out
    assert "NOTICE" not in out


def test_help_documents_release_flag(base):
    code, out = run_gate(base, ["--help"])
    assert code == 0
    assert "--release" in out and "THATONE_GATE" not in out
