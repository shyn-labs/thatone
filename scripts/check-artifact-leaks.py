#!/usr/bin/env python3
"""Release gate for thatone: scans the artifacts that would ship (the extracted
release tarball, or a directory) for the builder's machine identity and for
the PRIVATE denylist (real names, employers, domains), and checks that every
app and framework bundle in them is signed by an allowed, neutral identity.
A hit fails the release build (app/scripts/build-app.sh --release runs this on
the package it just made, as <name>.partial, and renames it to its publish name
only when this exits 0). Each scanned archive's sha256 is printed so an upload
can be matched to the gated file. Test-only environment hooks (THATONE_CODESIGN,
SHYN_GATE_USERNAME, SHYN_GATE_TEST_DELAY_MS) print a WARNING line naming them.

--release (build-app.sh always passes it, running this file by its fixed path
as `/usr/bin/python3 -I`) refuses, with exit 2, anything in the environment that
would weaken the release scan: SHYN_LEAK_DENYLIST or SHYN_ARTIFACT_ALLOW set
(even empty), --ci, or a /Users/runner home (CI mode). Without --release each
of these prints a NOTICE instead. THATONE_ALLOWED_AUTHORITIES set but without
entries is a usage error (exit 2); set, it prints a NOTICE with the number of
entries (never the names); unset means "Shyn Dev".

Ported from the shyn project's gate (scripts/check-artifact-leaks.mjs and
scripts/lib/artifact-scan.mjs in that repo): same flags, environment
variables, policy, output and exit codes. Python 3 stdlib only (3.9+).

What it checks (builder values count anywhere, exact; denylist terms are whole
words, with the printable-run noise rule inside binaries):
  1. every regular file of the extracted tarball / --dir (contents)
  2. the RAW decompressed tar stream (builder values only): owner names, path
     names, link targets, extended headers
  3. every relative path and symlink target of the scanned trees (builder
     values and denylist terms), reported as name: / link:
  4. signing (not in shyn's gate): every code item, i.e. every bundle
     directory (.app .framework .xpc .appex .bundle .plugin .kext
     .systemextension, any case) and every Mach-O file (by magic bytes), must
     pass `codesign --verify --strict --deep`, every Authority= line of
     `codesign -dvv` must be on the allowlist (default "Shyn Dev"), the
     signature must not be ad-hoc and TeamIdentifier must be "not set". A
     symlink with a bundle suffix and a tarball without any .app are hits too.
     Failures are hits reported as signing:. All signing data is collected
     BEFORE anything is printed, and every identity it shows (Authority, team
     id, certificate subject fields) is redacted from all output.
  5. extraction (tarball): entries are listed and refused when unsafe or
     duplicated; the extracted tree must equal that listing and hold only
     regular files, directories and symlinks; the raw .gz bytes (gzip header
     name and comment) are scanned for builder values too.

Known limits (deliberately not handled): regex punctuation boundaries (a term
that starts or ends with punctuation still gets the letter/digit boundary),
the <4-character rule counts characters not bytes, non-ASCII case folding,
extraction size limits, UTF-16 and case-variant builder needles, denylist
terms in archive headers (only builder values are scanned there), whole-file
reads (mmap), and the denylist regexes use Python's `re` dialect. There is no
timeout against a catastrophic regex in the owner's own denylist. The context
window (120 bytes each side) can cut a very long needle, so a context may show
part of a value that is longer than the window. `codesign -dvv` reports the
host architecture's slice only: another slice of a universal binary signed
differently is not authority-checked (--verify --deep still checks it).

Never prints a denylist term (matches show as <denylist-term-N>, N = the
entry's index in the file) and never prints the builder's username, home or
checkout path (shown as <username>, <home>, <checkout>); codesign output is
never printed except Authority values that are on the allowlist.
"""

import gzip
import hashlib
import mmap
import os
import pwd
import re
import shutil
import signal
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import warnings

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEMP_PREFIX = "thatone-artifact-gate-"
TAR = "/usr/bin/tar"  # bsdtar (libarchive): refuses absolute and ../ entries and extraction through symlinks

HELP = """usage: check-artifact-leaks.py [--tarball P] [--dir P] [--ci] [--release] [--show-noise]

Scans the shipped artifacts for the builder's username, home directory and
checkout path, and for every term of the private denylist, and checks the code
signature of every code item in them (every bundle type and every Mach-O file). Exit 0 only when there are
no hits and nothing was unreadable.

With no target flags it scans the newest
dist/release/ThatOne-v*-darwin-arm64.tar.gz of this repo (it must exist).

options:
  --tarball <path>  scan this .tar.gz (listed and checked first, then extracted
                    with /usr/bin/tar into a temp dir that is always removed)
  --dir <path>      scan this directory in place (no extraction)
                    (explicit targets replace the default; they can be combined)
  --ci              no private denylist is expected (it is absent in CI): the
                    home and username needles are dropped (vendored third-party
                    files legitimately contain /Users/runner), the checkout
                    needle and an existing denylist still apply. The same
                    happens automatically when the home dir is /Users/runner.
                    Without --ci a missing or empty denylist is a failure.
                    Zero scanned files fail even with --ci.
  --release         the release build's mode (build-app.sh --release passes it):
                    exits 2 before scanning when SHYN_LEAK_DENYLIST or
                    SHYN_ARTIFACT_ALLOW is set (even empty), when --ci is given
                    or when the home dir is /Users/runner (CI mode would turn
                    on). Without --release each of these prints a NOTICE line.
  --show-noise      also list the files that contained ignored binary noise
                    (file names only, never terms)
  -h, --help        this text

environment:
  SHYN_LEAK_DENYLIST       denylist file (default ~/.config/shyn/leak-denylist.txt):
                           one regex per line, # comments, case-insensitive
  SHYN_ARTIFACT_ALLOW      optional owner allowlist (default ~/.config/shyn/artifact-leak-allow.txt),
                           one entry per line: <glob relative to the extraction root>|<term>
                           (* and **; the last path segment must be literal; the term must equal a
                           denylist line). Matching hits are reported as allowlisted, not failures.
  SHYN_GATE_USERNAME       override the builder username needle (tests)
  SHYN_DIST_DIR            where the default target is looked up (default: dist/)
  SHYN_GATE_TEST_DELAY_MS  test hook: sleep this long per scanned file
  THATONE_ALLOWED_AUTHORITIES  comma-separated signing authorities allowed
                           (exact match; unset means "Shyn Dev"; set but with no
                           entries is a usage error; set prints "NOTICE: signing
                           authorities set by THATONE_ALLOWED_AUTHORITIES (<n> entries)")
  THATONE_CODESIGN         the codesign binary (default /usr/bin/codesign; tests
                           point it at a fake, PATH is not consulted); missing
                           means fail closed
  (SHYN_GATE_USERNAME, SHYN_GATE_TEST_DELAY_MS and THATONE_CODESIGN are test-only: when any is
  set the gate prints "WARNING: test override active: <NAME>"; build-app.sh unsets them)

output also includes "sha256: <hex>" of every archive scanned: upload only the
file whose hash it printed, named exactly ThatOne-v<version>-darwin-arm64.tar.gz.

rules:
  denylist       terms match as whole words (no ASCII letter/digit directly
                 before or after); non-ASCII terms match as UTF-8
  text files     denylist terms match anywhere (whole word)
  binary files   (NUL in the first 8 KiB) a denylist match counts only inside a
                 run of >= 6 printable ASCII bytes that contains it; shorter
                 runs, and any term shorter than 4 characters, are "ignored
                 binary noise" (counted, never hidden)
  builder values count wherever they occur, text or binary
  signing        for every bundle (.app .framework .xpc .appex .bundle .plugin
                 .kext .systemextension, any case) and every Mach-O file:
                 codesign --verify --strict --deep must pass; every Authority
                 must be allowed; no ad-hoc signature; TeamIdentifier=not set.
                 A bundle-named symlink, or a tarball without a .app, is a hit.
  output         per hit: file (relative to the extraction root), byte offset,
                 <= 60 chars of context; at most 20 hits per file and 200 in
                 total are printed but ALL are counted

exit codes: 0 clean, 1 hits / unreadable files / denylist problem, 2 usage error
"""

TEST_HOOKS = ("THATONE_CODESIGN", "SHYN_GATE_USERNAME", "SHYN_GATE_TEST_DELAY_MS")
# Owner-config overrides: refused under --release, a NOTICE otherwise.
CONFIG_OVERRIDES = ("SHYN_LEAK_DENYLIST", "SHYN_ARTIFACT_ALLOW")
RUNNER_HOME = "/Users/runner"


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


WINDOW = 120
RUN_MIN = 6
MAX_CONTEXT = 60
PER_FILE_CAP = 20
TOTAL_CAP = 200
CODESIGN_TIMEOUT = 120
TAR_TIMEOUT = 300
WORD_L = rb"(?<![A-Za-z0-9])"
WORD_R = rb"(?![A-Za-z0-9])"


def _is_print(b):
    return 0x20 <= b <= 0x7E or b == 9


_PRINT_TABLE = bytes(b if 0x20 <= b <= 0x7E or b == 9 else 0x2E for b in range(256))


class Exit(Exception):
    def __init__(self, code, msg):
        super().__init__(msg)
        self.code = code


# --------------------------------------------------------------------------
# cleanup: the temp dir goes away on every exit path, signals included
# --------------------------------------------------------------------------

_work_dir = None
_child = None


def _make_writable(p):
    """chmod every directory under p (not following symlinks) to 0700 so rmtree can empty it, even when
    an archive extracted directories as 0555 or 0000."""
    try:
        st = os.lstat(p)
    except OSError:
        return
    if not stat.S_ISDIR(st.st_mode):
        return
    try:
        os.chmod(p, 0o700)
    except OSError:
        pass
    try:
        names = os.listdir(p)
    except OSError:
        return
    for n in names:
        _make_writable(os.path.join(p, n))


def force_rmtree(p):
    _make_writable(p)
    shutil.rmtree(p, ignore_errors=True)


def cleanup():
    global _work_dir
    if _work_dir:
        force_rmtree(_work_dir)
        _work_dir = None


def _on_signal(signum, _frame):
    child = _child
    if child is not None and child.poll() is None:
        try:
            child.kill()
            child.wait(timeout=5)
        except Exception:  # noqa: BLE001 - best effort, we are exiting
            pass
    cleanup()
    try:
        sys.stdout.flush()
    except Exception:  # noqa: BLE001
        pass
    os._exit(128 + int(signum))  # SIGHUP 129, SIGINT 130, SIGQUIT 131, SIGTERM 143


def run_child(argv, timeout):
    """Runs argv (a list, never a shell) and returns (returncode, stdout, stderr) as bytes.
    The child is tracked so a signal can kill it before the temp dir is removed."""
    global _child
    p = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    _child = p
    try:
        out, err = p.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        p.kill()
        p.communicate()
        raise
    finally:
        _child = None
    return p.returncode, out, err


# --------------------------------------------------------------------------
# needles, denylist, sanitizing
# --------------------------------------------------------------------------


def builder_needles(env):
    try:
        user = pwd.getpwuid(os.getuid()).pw_name
    except KeyError:
        user = ""
    candidates = [
        ("username", env.get("SHYN_GATE_USERNAME") or user),
        ("home", os.path.expanduser("~")),
        ("checkout", REPO_ROOT),
    ]
    seen = set()
    out = []
    for label, value in candidates:
        if not value or value in seen:
            continue
        seen.add(value)
        out.append((label, value))
    return out


class Term:
    def __init__(self, index, term, hit_re, ctx_re):
        self.index = index
        self.term = term
        self.short = len(term) < 4
        self.hit_re = hit_re  # bytes, whole word, decides hits
        self.ctx_re = ctx_re  # latin-1 str, any substring, only hides terms in printed text


def parse_denylist(text):
    entries, bad = [], []
    for i, raw in enumerate(text.split("\n")):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        try:
            # any warning while compiling (e.g. "possible nested set") makes the line invalid: it is raised
            # here, reported by line number only, and never reaches stderr with the term in it
            with warnings.catch_warnings():
                warnings.simplefilter("error")
                re.compile(line, re.I)  # the line as the owner wrote it
                raw_bytes = line.encode("utf-8")
                hit_re = re.compile(WORD_L + b"(?:" + raw_bytes + b")" + WORD_R, re.I)
                ctx_re = re.compile(raw_bytes.decode("latin-1"), re.I)
        except Exception:  # noqa: BLE001 - re.error, a Warning, anything: the line is unusable
            bad.append(i + 1)
            continue
        entries.append(Term(len(entries), line, hit_re, ctx_re))
    return entries, bad


# Signing identities seen by the signing check (team ids, disallowed Authority strings, emails in them):
# redacted from every printed string, never used as hit needles. Filled before any content is scanned.
_SIGNING_REDACT = []
# Generic shapes that are personal wherever they appear in printed text: an email address, and an
# Apple team id in parentheses as certificate names carry it ("... (ABCDE12345)").
_EMAIL_RE = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+")
_TEAM_RE = re.compile(r"\([A-Z0-9]{10}\)")
# A bare 10-character upper-case id with letters and digits (the team id or the developer UID inside an
# embedded certificate): redacted too. Over-redacts some binary noise in contexts; that is fine.
_ID_RE = re.compile(r"(?<![A-Za-z0-9])(?=[A-Z0-9]*[0-9])(?=[A-Z0-9]*[A-Z])[A-Z0-9]{10}(?![A-Za-z0-9])")
# A printable run holding one of these is a certificate name: the whole run is redacted, and so is any
# token of 10+ upper-case letters/digits inside it or within 64 bytes of it (no boundary needed: in DER a
# value is glued to the next tag byte, e.g. "1").
_MARKERS = ("Development:", "Developer ID", "Distribution:", "Mac Developer:")
_LONG_ID_RE = re.compile(r"[A-Z0-9]{10,}")
_NEAR = 64


def _marker_spans(w, isp):
    spans = []
    for mk in _MARKERS:
        i = w.find(mk)
        while i != -1:
            s, e = i, i + len(mk)
            while s > 0 and isp(s - 1):
                s -= 1
            while e < len(w) and isp(e):
                e += 1
            spans.append((s, e, "<signing-identity>", False))
            lo, hi = max(0, s - _NEAR), min(len(w), e + _NEAR)
            for m in _LONG_ID_RE.finditer(w, lo):
                if m.start() >= hi:
                    break
                spans.append((m.start(), m.end(), "<id>", False))
            i = w.find(mk, i + 1)
    return spans


def _sanitize_spans(w, own, needles, denylist, raw=None):
    """w: a latin-1 str. own: (start, end, label) of the hit itself or None. raw: the bytes w was made
    from (a binary window), to tell printable runs apart; None for plain text.
    Returns (text, q): sanitized text and where `own` starts in it."""
    spans = []
    if own:
        spans.append((own[0], own[1], own[2], True))
    if raw is not None:
        spans.extend(_marker_spans(w, lambda k: _is_print(raw[k])))
    else:
        spans.extend(_marker_spans(w, lambda k: w[k] == "\t" or not (ord(w[k]) < 0x20 or ord(w[k]) == 0x7F)))
    for m in _EMAIL_RE.finditer(w):
        spans.append((m.start(), m.end(), "<email>", False))
    for m in _TEAM_RE.finditer(w):
        spans.append((m.start(), m.end(), "(<team-id>)", False))
    for m in _ID_RE.finditer(w):
        spans.append((m.start(), m.end(), "<id>", False))
    lw = w.lower()
    ci = len(lw) == len(w)
    for label, value in list(needles) + _SIGNING_REDACT:
        v = value.encode("utf-8").decode("latin-1")
        hay = lw if ci else w
        nd = v.lower() if ci else v
        if len(nd) != len(v):
            continue
        i = hay.find(nd)
        while i != -1:
            spans.append((i, i + len(v), "<%s>" % label, False))
            i = hay.find(nd, i + 1)
    for d in denylist:
        for m in d.ctx_re.finditer(w):
            if m.end() > m.start():
                spans.append((m.start(), m.end(), "<denylist-term-%d>" % d.index, False))
    # Longest span first at the same start; a span overlapping an earlier one extends that redaction
    # (so the tail of an email or an authority is never left visible next to a placeholder).
    spans.sort(key=lambda s: (s[0], -s[1], 0 if s[3] else 1))
    out, cursor, q = [], 0, 0
    length = last_label_at = 0
    for start, end, label, first in spans:
        if start < cursor:
            if first:  # the hit itself lies inside an earlier redaction: point at that one
                q = last_label_at
            cursor = max(cursor, end)
            continue
        piece = w[cursor:start]
        out.append(piece)
        length += len(piece)
        if first:
            q = length
        last_label_at = length
        out.append(label)
        length += len(label)
        cursor = end
    out.append(w[cursor:])
    return "".join(out), q


class Sanitizer:
    def __init__(self, needles):
        self.needles = needles
        self.denylist = []

    def __call__(self, text):
        latin = str(text).encode("utf-8", "surrogateescape").decode("latin-1")
        res, _ = _sanitize_spans(latin, None, self.needles, self.denylist)
        return res.encode("latin-1").decode("utf-8", "replace")


# --------------------------------------------------------------------------
# allowlist
# --------------------------------------------------------------------------


def parse_allowlist(text, denylist):
    known = {d.term.lower(): d.index for d in denylist}
    entries, bad = [], []
    for i, raw in enumerate(text.split("\n")):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        cut = line.rfind("|")
        glob = line[:cut].strip() if cut > 0 else ""
        term = line[cut + 1:].strip().lower() if cut > 0 else ""
        last = glob.split("/")[-1] if glob else ""
        if not glob or term not in known or not last or "*" in last:
            bad.append(i + 1)
            continue
        parts = []
        for dbl in glob.split("**"):
            parts.append("[^/]*".join(re.escape(x) for x in dbl.split("*")))
        entries.append((re.compile("^" + ".*".join(parts) + "$"), known[term]))
    return entries, bad


# --------------------------------------------------------------------------
# scanning
# --------------------------------------------------------------------------


class Stats:
    def __init__(self):
        self.files = 0
        self.bytes = 0
        self.noise = 0
        self.unreadable = 0
        self.noise_files = set()
        self.unreadable_files = []


def _printable(buf, start, end):
    return bytes(buf[start:end]).translate(_PRINT_TABLE).decode("ascii")


def _context(buf, off, length, own_label, needles, denylist):
    ws = max(0, off - WINDOW)
    we = min(len(buf), off + length + WINDOW)
    raw = bytes(buf[ws:we])
    w = raw.translate(_PRINT_TABLE).decode("ascii")
    text, q = _sanitize_spans(w, (off - ws, off - ws + length, own_label), needles, denylist, raw)
    frm = max(0, q - MAX_CONTEXT // 3)
    return text[frm:frm + MAX_CONTEXT]


def _in_printable_run(buf, start, end):
    # inside the match itself, UTF-8 bytes of a non-ASCII term count as printable
    for i in range(start, end):
        if not _is_print(buf[i]) and buf[i] < 0x80:
            return False
    n = end - start
    i = start - 1
    while i >= 0 and n < RUN_MIN and _is_print(buf[i]):
        n += 1
        i -= 1
    i = end
    while i < len(buf) and n < RUN_MIN and _is_print(buf[i]):
        n += 1
        i += 1
    return n >= RUN_MIN


def scan_file(path, rel, needles, denylist, stats, on_hit):
    try:
        with open(path, "rb") as f:
            size = os.fstat(f.fileno()).st_size
            buf = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) if size else b""
    except (OSError, ValueError):
        stats.unreadable += 1
        stats.unreadable_files.append(rel)
        return
    try:
        stats.files += 1
        stats.bytes += len(buf)
        binary = b"\x00" in buf[:8192]
        for label, value in needles:
            nb = value.encode("utf-8")
            i = buf.find(nb)
            while i != -1:
                on_hit(rel, i, "builder", label, None,
                       lambda i=i, nb=nb, label=label: _context(buf, i, len(nb), "<%s>" % label, needles, denylist))
                i = buf.find(nb, i + 1)
        for d in denylist:
            for m in d.hit_re.finditer(buf):
                s, e = m.start(), m.end()
                if e == s:
                    continue
                if binary and (d.short or not _in_printable_run(buf, s, e)):
                    stats.noise += 1
                    stats.noise_files.add(rel)
                else:
                    lab = "denylist-term-%d" % d.index
                    on_hit(rel, s, "denylist", lab, d.index,
                           lambda s=s, e=e, lab=lab: _context(buf, s, e - s, "<%s>" % lab, needles, denylist))
    finally:
        if isinstance(buf, mmap.mmap):
            buf.close()


def scan_tree(root, needles, denylist, stats, on_hit, delay):
    def walk(d):
        try:
            entries = sorted(os.scandir(d), key=lambda e: e.name)
        except OSError:
            stats.unreadable += 1
            stats.unreadable_files.append(os.path.relpath(d, root))
            return
        for e in entries:
            if e.is_dir(follow_symlinks=False):
                walk(e.path)
            elif e.is_file(follow_symlinks=False):
                if delay:
                    time.sleep(delay)
                scan_file(e.path, os.path.relpath(e.path, root), needles, denylist, stats, on_hit)
            # symlinks, sockets, fifos: contents skipped on purpose (names and link targets: scan_names)

    walk(root)


def scan_names(root, needles, denylist, on_hit):
    def check(rel, where, text):
        for label, value in needles:
            if value in text:
                on_hit(rel, where, label)
        b = text.encode("utf-8", "surrogateescape")
        for d in denylist:
            if d.hit_re.search(b):
                on_hit(rel, where, "denylist-term-%d" % d.index)

    def walk(d):
        try:
            entries = sorted(os.scandir(d), key=lambda e: e.name)
        except OSError:
            return
        for e in entries:
            rel = os.path.relpath(e.path, root)
            check(rel, "name", rel)
            if e.is_symlink():
                try:
                    check(rel, "link", os.readlink(e.path))
                except OSError:
                    pass
            elif e.is_dir(follow_symlinks=False):
                walk(e.path)

    walk(root)


# --------------------------------------------------------------------------
# signing
# --------------------------------------------------------------------------


BUNDLE_SUFFIXES = (".app", ".framework", ".xpc", ".appex", ".bundle", ".plugin", ".kext", ".systemextension")
# Mach-O thin 32/64 (both byte orders) and fat/universal (0xcafebabe, also Java's class magic: none ship)
# and fat64 (0xcafebabf), as the first 4 bytes of a file.
MACHO_MAGICS = {bytes.fromhex(h) for h in ("feedface", "cefaedfe", "feedfacf", "cffaedfe",
                                           "cafebabe", "bebafeca", "cafebabf", "bfbafeca")}


def _is_bundle_name(name):
    return name.lower().endswith(BUNDLE_SUFFIXES)


def discover_code(root):
    """Returns (items, problems, apps): items = [(path, rel)] for every bundle directory and every Mach-O
    file (symlinks are never followed); problems = [(rel, reason)]; apps = number of real .app dirs."""
    items, problems = [], []
    apps = 0
    top = os.path.basename(root.rstrip("/")) or root

    def rel_of(p):
        return top if p == root else os.path.relpath(p, root)

    if _is_bundle_name(top):
        if os.path.islink(root):
            problems.append((top, "bundle is a symlink"))
        elif os.path.isdir(root):
            items.append((root, top))
            apps += top.lower().endswith(".app")

    def walk(d):
        nonlocal apps
        try:
            entries = sorted(os.scandir(d), key=lambda e: e.name)
        except OSError:
            return  # counted as unreadable by the content scan
        for e in entries:
            if e.is_symlink():
                if _is_bundle_name(e.name):
                    problems.append((rel_of(e.path), "bundle is a symlink"))
                continue
            if e.is_dir(follow_symlinks=False):
                if _is_bundle_name(e.name):
                    items.append((e.path, rel_of(e.path)))
                    apps += e.name.lower().endswith(".app")
                walk(e.path)
            elif e.is_file(follow_symlinks=False):
                try:
                    with open(e.path, "rb") as f:
                        magic = f.read(4)
                except OSError:
                    continue
                if magic in MACHO_MAGICS:
                    items.append((e.path, rel_of(e.path)))

    walk(root)
    return items, problems, apps


def codesign_path():
    p = os.environ.get("THATONE_CODESIGN") or "/usr/bin/codesign"
    if not (os.path.isfile(p) and os.access(p, os.X_OK)):
        raise Exit(1, "codesign not found at %s: the signing check cannot run, failing closed" % p)
    return p


def _der_strings(der):
    out = []
    for i in range(len(der) - 2):
        n = der[i + 1]
        if der[i] in (0x0C, 0x13, 0x14, 0x16) and n < 0x80 and i + 2 + n <= len(der):
            v = der[i + 2:i + 2 + n]
            if n >= 4 and all(0x20 <= c < 0x7F for c in v):
                out.append(v.decode("ascii"))
    return out


def _leaf_certificate_fields(codesign, path):
    """Every DER string field (UTF8String, PrintableString, T61String, IA5String) of the leaf signing
    certificate: name, organisation, team id, developer UID. Best effort; never printed."""
    d = tempfile.mkdtemp(prefix="certs-", dir=_work_dir)
    try:
        run_child([codesign, "-d", "--extract-certificates=" + os.path.join(d, "cert-"), path], CODESIGN_TIMEOUT)
        with open(os.path.join(d, "cert-0"), "rb") as f:
            return _der_strings(f.read())
    except (OSError, subprocess.TimeoutExpired):
        return []
    finally:
        force_rmtree(d)


def check_signing(codesign, path, allowed):
    """Runs the codesign checks for one code item. Returns (problems, authorities, secrets): problems are
    short REDACTED reasons, authorities the allowed ones seen, secrets the identity values to redact."""
    problems, secrets = [], []
    try:
        rc, _o, _e = run_child([codesign, "--verify", "--strict", "--deep", path], CODESIGN_TIMEOUT)
        if rc != 0:
            problems.append("verification failed (codesign --verify --strict --deep exit %d)" % rc)
        rc, out, err = run_child([codesign, "-dvv", path], CODESIGN_TIMEOUT)
    except subprocess.TimeoutExpired:
        return problems + ["codesign timed out"], [], secrets
    if rc != 0:
        return problems + ["cannot read the signature (codesign -dvv exit %d)" % rc], [], secrets
    lines = [ln.strip() for ln in (err + b"\n" + out).decode("utf-8", "replace").splitlines()]
    authorities = [ln[len("Authority="):] for ln in lines if ln.startswith("Authority=")]
    teams = [ln[len("TeamIdentifier="):] for ln in lines if ln.startswith("TeamIdentifier=")]
    for a in authorities:
        if a not in allowed:
            secrets.append(("signing-authority", a))
            secrets.extend(("email", m.group(0)) for m in _EMAIL_RE.finditer(a))
    secrets.extend(("team-id", t) for t in teams if t != "not set" and len(t) >= 4)
    secrets.extend(("cert-field", v) for v in _leaf_certificate_fields(codesign, path) if v not in allowed)
    adhoc = any(ln == "Signature=adhoc" for ln in lines)
    if adhoc:
        problems.append("ad-hoc signature")
    if not authorities and not adhoc:
        problems.append("no signing authority reported")
    if any(a not in allowed for a in authorities):
        problems.append("authority not allowed (<redacted>)")
    if not teams:
        problems.append("TeamIdentifier not reported")
    elif any(t != "not set" for t in teams):
        problems.append("TeamIdentifier set (<redacted>)")
    return problems, ([a for a in authorities if a in allowed] if not problems else []), secrets


def add_redactions(secrets):
    seen = {v for _l, v in _SIGNING_REDACT}
    for label, v in secrets:
        if v and v not in seen:
            seen.add(v)
            _SIGNING_REDACT.append((label, v))
    _SIGNING_REDACT.sort(key=lambda n: -len(n[1]))


# --------------------------------------------------------------------------
# targets and extraction
# --------------------------------------------------------------------------


def parse_args(argv):
    o = {"ci": False, "release": False, "show_noise": False, "tarball": None, "dir": None, "help": False}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ("--help", "-h"):
            o["help"] = True
        elif a == "--ci":
            o["ci"] = True
        elif a == "--release":
            o["release"] = True
        elif a == "--show-noise":
            o["show_noise"] = True
        elif a in ("--tarball", "--dir"):
            i += 1
            v = argv[i] if i < len(argv) else None
            if not v or v.startswith("--"):
                raise Exit(2, "%s needs a path (see --help)" % a)
            o[a[2:]] = os.path.abspath(v)
        else:
            raise Exit(2, "unknown argument: %s (see --help)" % a)
        i += 1
    return o


def default_tarball():
    dist = os.path.abspath(os.environ["SHYN_DIST_DIR"]) if os.environ.get("SHYN_DIST_DIR") else os.path.join(REPO_ROOT, "dist")
    rel = os.path.join(dist, "release")
    if not os.path.isdir(rel):
        return None
    pat = re.compile(r"^ThatOne-v.*-darwin-arm64\.tar\.gz$")
    found = [os.path.join(rel, n) for n in os.listdir(rel) if pat.match(n)]
    if not found:
        return None
    return max(found, key=lambda p: os.stat(p).st_mtime)


def _unsafe_name(name):
    return (name.startswith("/") or re.match(r"^[A-Za-z]:", name) is not None
            or ".." in re.split(r"[\\/]", name) or "\n" in name or "\r" in name or "\\" in name)


def _norm(name):
    while name.startswith("./"):
        name = name[2:]
    return name.rstrip("/")


def extract_tarball(path, dest, san):
    try:
        with tarfile.open(path, "r:gz") as tf:
            members = tf.getmembers()
    except (OSError, tarfile.TarError, EOFError) as e:
        raise Exit(1, "cannot list tarball entries: %s" % str(e).split("\n")[0])
    bad = []
    links = set()
    seen = set()
    dups = []
    for m in members:
        name = m.name
        key = _norm(name)
        if key not in ("", "."):
            if key in seen:
                dups.append(name)
            seen.add(key)
        if _unsafe_name(name) or m.ischr() or m.isblk() or m.isfifo():
            bad.append(name)
        elif m.islnk() and _unsafe_name(m.linkname):
            bad.append(name)
        if m.issym():
            links.add(_norm(name))
    if not bad and links:
        # an entry below a symlink entry would be written through the link
        for m in members:
            parts = _norm(m.name).split("/")
            for k in range(1, len(parts)):
                if "/".join(parts[:k]) in links:
                    bad.append(m.name)
                    break
    if dups:
        raise Exit(1, "refusing tarball: %d duplicate entr%s (first: %s)"
                   % (len(dups), "y" if len(dups) == 1 else "ies", san(repr(dups[0]))))
    if bad:
        raise Exit(1, "refusing tarball: %d entr%s would escape the extraction dir (first: %s)"
                   % (len(bad), "y" if len(bad) == 1 else "ies", san(repr(bad[0]))))
    os.makedirs(dest)
    try:
        # --no-mac-metadata/--no-xattrs/--no-acls/--no-fflags: nothing from the archive is applied as
        # metadata. bsdtar on macOS still drops AppleDouble "._x" members, so an archive carrying them fails
        # the tree-equals-listing check below (release packages are made without them).
        rc, _o, err = run_child([TAR, "-xzf", path, "--no-mac-metadata", "--no-xattrs", "--no-acls", "--no-fflags",
                                 "-C", dest], TAR_TIMEOUT)
    except subprocess.TimeoutExpired:
        raise Exit(1, "extracting tarball timed out")
    if rc != 0:
        raise Exit(1, "extracting tarball failed: %s" % err.decode("utf-8", "replace").strip().split("\n")[0])
    return [m.name for m in members]


def compare_extracted(dest, names):
    """The extracted tree must be exactly the listed members (plus their implied parent directories) and
    hold only regular files, directories and symlinks. Returns problem strings (names never included:
    the caller prints counts only)."""
    expected = set()
    for n in names:
        key = _norm(n)
        if key in ("", "."):
            continue
        parts = key.split("/")
        for k in range(1, len(parts) + 1):
            expected.add("/".join(parts[:k]))
    actual, odd, unreadable = set(), 0, 0

    def walk(d):
        nonlocal odd, unreadable
        try:
            entries = list(os.scandir(d))
        except OSError:
            unreadable += 1
            return
        for e in entries:
            rel = os.path.relpath(e.path, dest)
            actual.add(rel)
            if e.is_symlink():
                continue
            if e.is_dir(follow_symlinks=False):
                walk(e.path)
            elif not e.is_file(follow_symlinks=False):
                odd += 1

    walk(dest)
    problems = []
    missing, extra = expected - actual, actual - expected
    if missing or extra:
        problems.append("extracted tree differs from the listing: %d missing, %d extra" % (len(missing), len(extra)))
    if odd:
        problems.append("%d extracted entr%s not a regular file, directory or symlink" % (odd, "y is" if odd == 1 else "ies are"))
    if unreadable:
        problems.append("%d extracted director%s unreadable" % (unreadable, "y" if unreadable == 1 else "ies"))
    return problems


def raw_stream(path, out_path):
    try:
        with gzip.open(path, "rb") as src, open(out_path, "wb") as dst:
            shutil.copyfileobj(src, dst, 1 << 20)
    except (OSError, EOFError):
        raise Exit(1, "cannot decompress the tarball stream")


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------


def main(san):
    global _work_dir
    opts = parse_args(sys.argv[1:])
    if opts["help"]:
        sys.stdout.write(HELP)
        return 0
    # Test-only hooks weaken the gate; build-app.sh strips them, and a manual run that has one set says so loudly
    # (names only, never the values).
    home = os.path.expanduser("~")
    runner = home == RUNNER_HOME
    # Environment that weakens the scan: refused in the release build, announced otherwise (names only).
    if opts["release"]:
        for name in CONFIG_OVERRIDES:
            if name in os.environ:
                raise Exit(2, "--release: %s is set: a release is gated with the owner's default denylist and "
                              "allowlist only; unset it" % name)
        if opts["ci"]:
            raise Exit(2, "--release: --ci is not allowed: a release needs the private denylist and every "
                          "builder needle")
        if runner:
            raise Exit(2, "--release: the home dir is the GitHub runner's, which would turn on CI mode (no "
                          "home/username needles): run the release gate on the owner's machine")
    else:
        for name in CONFIG_OVERRIDES:
            if os.environ.get(name):
                print("NOTICE: %s overrides the default" % name)
        if runner:
            print("NOTICE: CI mode on (GitHub runner home detected)")
    for hook in TEST_HOOKS:
        if os.environ.get(hook):
            print("WARNING: test override active: %s" % hook)

    targets = []
    if opts["tarball"] or opts["dir"]:
        if opts["tarball"]:
            targets.append(("tarball", opts["tarball"]))
        if opts["dir"]:
            targets.append(("dir", opts["dir"]))
    else:
        d = default_tarball()
        if d:
            targets.append(("tarball", d))
    for kind, p in targets:
        if not os.path.exists(p):
            raise Exit(2, "%s not found: %s" % (kind, p))
        if kind == "dir" and not os.path.isdir(p):
            raise Exit(2, "not a directory: %s" % p)
        if kind == "tarball" and not os.path.isfile(p):
            raise Exit(2, "not a file: %s" % p)
    if not targets:
        raise Exit(2, "no targets: build first (app/scripts/build-app.sh --release makes "
                      "dist/release/ThatOne-v*-darwin-arm64.tar.gz) or pass --tarball/--dir")

    raw_auth = os.environ.get("THATONE_ALLOWED_AUTHORITIES")  # unset: the default; set but empty: refused
    allowed = [a.strip() for a in (raw_auth if raw_auth is not None else "Shyn Dev").split(",") if a.strip()]
    if not allowed:
        raise Exit(2, "THATONE_ALLOWED_AUTHORITIES is set but has no entries: unset it for the default "
                      "\"Shyn Dev\" or list the allowed authorities")
    if raw_auth is not None:
        print("NOTICE: signing authorities set by THATONE_ALLOWED_AUTHORITIES (%d entries)" % len(allowed))

    # --- needles and denylist ---------------------------------------------
    ci_mode = opts["ci"] or runner
    needles = builder_needles(os.environ)
    if ci_mode:
        needles = [n for n in needles if n[0] == "checkout"]
    denylist_path = os.environ.get("SHYN_LEAK_DENYLIST") or os.path.join(home, ".config/shyn/leak-denylist.txt")
    shown = denylist_path.replace(home, "<home>")
    denylist = []
    if not os.path.exists(denylist_path):
        if not ci_mode:
            raise Exit(1, "denylist missing at %s: the gate cannot run. Create it (one regex per line, # for "
                          "comments), set SHYN_LEAK_DENYLIST, or pass --ci." % shown)
        note = "denylist: not present (--ci): only the remaining builder checks ran"
    else:
        try:
            with open(denylist_path, encoding="utf-8") as f:
                text = f.read()
        except (OSError, UnicodeDecodeError):
            raise Exit(1, "cannot read the denylist at %s" % shown)
        denylist, bad = parse_denylist(text)
        if bad:
            raise Exit(1, "denylist has invalid regex on line(s): %s (%s)" % (", ".join(map(str, bad)), shown))
        if not denylist:
            if not ci_mode:
                raise Exit(1, "denylist at %s has no active terms: an empty list would pass everything. "
                              "Add terms, or pass --ci." % shown)
            note = "denylist: no active terms (--ci): only the remaining builder checks ran"
        else:
            note = "denylist: %d term(s) (never printed; reported as <denylist-term-N>)" % len(denylist)
    san.denylist = denylist
    allow_path = os.environ.get("SHYN_ARTIFACT_ALLOW") or os.path.join(home, ".config/shyn/artifact-leak-allow.txt")
    allow = []
    if os.path.exists(allow_path):
        try:
            with open(allow_path, encoding="utf-8") as f:
                atext = f.read()
        except (OSError, UnicodeDecodeError):
            raise Exit(1, "cannot read the allowlist")
        allow, abad = parse_allowlist(atext, denylist)
        if abad:
            raise Exit(1, "allowlist has invalid entr%s on line(s): %s (need <glob with a literal basename>|"
                          "<term in the denylist>)" % ("y" if len(abad) == 1 else "ies", ", ".join(map(str, abad))))
    try:
        delay = max(0.0, float(os.environ.get("SHYN_GATE_TEST_DELAY_MS") or 0) / 1000.0)
    except ValueError:
        delay = 0.0

    print("builder needles used: %s%s%s" % (
        ", ".join(n[0] for n in needles) or "none",
        " (GitHub runner home detected: home and username dropped)" if ci_mode and not opts["ci"] else "",
        " (--ci: home and username dropped)" if opts["ci"] else ""))
    print(note)
    print("signing: allowed authorities: %s" % san(", ".join(allowed)))

    # --- extract + scan ----------------------------------------------------
    _work_dir = tempfile.mkdtemp(prefix=TEMP_PREFIX)
    stats = Stats()
    st = {"hits": 0, "printed": 0, "allowlisted": 0, "label": ""}
    per_file = {}
    allowed_hits = {}

    def emit(line, key=None):
        if key is not None:
            per_file[key] = per_file.get(key, 0) + 1
            if per_file[key] > PER_FILE_CAP:
                return
        if st["printed"] < TOTAL_CAP:
            st["printed"] += 1
            print(line)

    def on_hit(rel, offset, kind, label, term_index, context):
        if kind == "denylist" and any(ti == term_index and rx.match(rel) for rx, ti in allow):
            st["allowlisted"] += 1
            k = (st["label"], rel, term_index)
            allowed_hits[k] = allowed_hits.get(k, 0) + 1
            return
        st["hits"] += 1
        key = "%s:%s" % (st["label"], rel)
        if per_file.get(key, 0) < PER_FILE_CAP and st["printed"] < TOTAL_CAP:
            emit("  %s:%s  @%d  [%s]  %s" % (st["label"], san(rel), offset, label, context()), key)
        else:
            per_file[key] = per_file.get(key, 0) + 1

    def on_name_hit(rel, where, label):
        st["hits"] += 1
        emit("  %s:%s  %s:  [%s]" % (st["label"], san(rel), where, label))

    # Phase 1, nothing printed: extract every target and run every signing check, so the identities the
    # checks see are in the redaction set before the first hit line is printed.
    codesign = None
    prepared = []
    for kind, path in targets:
        root = path
        extract_problems = []
        if kind == "tarball":
            root = os.path.join(_work_dir, "tarball-%d" % len(prepared))
            names = extract_tarball(path, root, san)
            extract_problems = compare_extracted(root, names)
        items, sign_problems, apps = discover_code(root)
        if kind == "tarball" and apps == 0:
            sign_problems.append(("<tarball>", "no .app bundle in the tarball"))
        results = []
        if items:
            codesign = codesign or codesign_path()
        for item, rel in items:
            problems, auths, secrets = check_signing(codesign, item, allowed)
            add_redactions(secrets)
            results.append((rel, problems, auths))
        prepared.append((kind, path, root, extract_problems, sign_problems, results))

    # Phase 2: report and scan.
    for kind, path, root, extract_problems, sign_problems, results in prepared:
        st["label"] = kind
        print("scanning %s: %s" % (kind, san(path)))
        if kind == "tarball":
            try:
                print("sha256: %s" % sha256_of(path))
            except OSError:
                pass  # the content scan reports an unreadable archive
        for p in extract_problems:
            st["hits"] += 1
            emit("  %s:<extraction>  extraction:  %s" % (kind, san(p)))
        for rel, p in sign_problems:
            st["hits"] += 1
            emit("  %s:%s  signing:  %s" % (kind, san(rel), san(p)))
        for rel, problems, auths in results:
            for p in problems:
                st["hits"] += 1
                emit("  %s:%s  signing:  %s" % (kind, san(rel), san(p)))
            if not problems:
                print("signing: %s:%s ok (Authority=%s; TeamIdentifier=not set)"
                      % (kind, san(rel), san(", ".join(auths))))
        if kind == "tarball":
            scratch = Stats()
            st["label"] = "tarball-gz"
            scan_file(path, "gzip file", needles, [], scratch, on_hit)  # gzip header name/comment
            raw = os.path.join(_work_dir, "tarball.raw.tar")
            raw_stream(path, raw)
            st["label"] = "tarball-raw"
            scan_file(raw, "raw stream", needles, [], scratch, on_hit)
            stats.unreadable += scratch.unreadable
            stats.unreadable_files.extend("tarball:" + f for f in scratch.unreadable_files)
            os.remove(raw)
            st["label"] = kind
        scan_tree(root, needles, denylist, stats, on_hit, delay)
        scan_names(root, needles, denylist, on_name_hit)

    if stats.files == 0:
        raise Exit(1, "scanned 0 files: nothing to check (empty or unreadable archive?)")
    for (label, rel, idx), n in allowed_hits.items():
        print("allowlisted: %s:%s x%d (<denylist-term-%d>)" % (label, san(rel), n, idx))
    if st["hits"] > st["printed"]:
        print("  (%d more hit(s) not shown; all are counted)" % (st["hits"] - st["printed"]))
    for f in stats.unreadable_files[:20]:
        print("  unreadable: %s" % san(f))
    if opts["show_noise"]:
        for f in sorted(stats.noise_files):
            print("  ignored binary noise in: %s" % san(f))
    print("scanned %d files, %.1f MB, hits %d, allowlisted %d, ignored binary noise %d, unreadable %d"
          % (stats.files, stats.bytes / 1048576, st["hits"], st["allowlisted"], stats.noise, stats.unreadable))
    if st["hits"] == 0 and stats.unreadable == 0:
        print("OK: no builder identity, denylist term or disallowed signature in the artifacts")
        return 0
    print("FAIL: the artifacts must not ship; fix the source of each hit and rebuild")
    return 1


def entry():
    try:
        sys.stdout.reconfigure(line_buffering=True)
    except AttributeError:
        pass
    for sig in (signal.SIGHUP, signal.SIGINT, signal.SIGQUIT, signal.SIGTERM):
        signal.signal(sig, _on_signal)
    # Everything printed that is not an already-sanitized context goes through san().
    san = Sanitizer(builder_needles(os.environ))
    # Load the denylist for redaction before anything (a usage error naming a path included) is printed;
    # main() validates it properly and fails on problems.
    try:
        with open(os.environ.get("SHYN_LEAK_DENYLIST")
                  or os.path.join(os.path.expanduser("~"), ".config/shyn/leak-denylist.txt"), encoding="utf-8") as f:
            san.denylist = parse_denylist(f.read())[0]
    except (OSError, UnicodeDecodeError):
        pass
    code = 1
    try:
        code = main(san)
    except Exit as e:
        print("check-artifact-leaks: %s" % san(str(e)), file=sys.stderr)
        code = e.code
    except Exception as e:  # noqa: BLE001 - any failure fails the gate, sanitized
        print("check-artifact-leaks: unexpected error: %s: %s" % (type(e).__name__, san(str(e))), file=sys.stderr)
        code = 1
    finally:
        cleanup()
    sys.stdout.flush()
    return code


if __name__ == "__main__":
    sys.exit(entry())
