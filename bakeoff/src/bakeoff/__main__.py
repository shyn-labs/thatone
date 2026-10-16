import argparse
import os
import statistics
import sys
import time
from pathlib import Path

import yaml

from bakeoff import paths
from bakeoff.evaluate import aggregate, decide, load_golden, render_report, score, unindexed_golden
from bakeoff.extract_media import WHISPER_REPO, extract_audio, extract_video
from bakeoff.extract_text import extract_code, extract_doc, extract_image, extract_pdf
from bakeoff.index import check_digest, embed_segments, load_index, save_index, segments_digest
from bakeoff.models import MODELS, client_for, offline_env
from bakeoff.sample import build_manifest, read_jsonl, write_jsonl
from bakeoff.search import VARIANTS, SearchIndex
from bakeoff.segments import Segment

EXTRACTORS = {"image": extract_image, "pdf": extract_pdf, "doc": extract_doc,
              "code": extract_code, "audio": extract_audio, "video": extract_video}
QUOTAS = {"image": 150, "pdf": 50, "doc": 40, "audio": 15, "video": 10, "code": 30}


def cmd_prefetch(args):
    for name in args.models:
        with client_for(name, offline=False) as c:
            print(name, c.info())
    import mlx_whisper  # noqa: F401
    from huggingface_hub import snapshot_download
    snapshot_download(WHISPER_REPO)


def cmd_sample(args):
    golden = yaml.safe_load(Path(args.golden).read_text(encoding="utf-8"))
    forced = [Path(r).expanduser() for q in golden for r in q["relevant"]]
    manifest = build_manifest([Path(r).expanduser() for r in args.roots], QUOTAS, forced)
    write_jsonl(paths.manifest_path(), manifest)
    by_kind = {}
    for m in manifest:
        by_kind[m["kind"]] = by_kind.get(m["kind"], 0) + 1
    print(f"{len(manifest)} files ({sum(m['forced'] for m in manifest)} golden): {by_kind}")


def cmd_extract(args):
    os.environ.update(offline_env())  # whisper must not reach the network; prefetch did the download
    segs, errors = [], []
    manifest = read_jsonl(paths.manifest_path())
    for i, entry in enumerate(manifest, 1):
        try:
            segs += EXTRACTORS[entry["kind"]](entry)
        except Exception as e:  # noqa: BLE001 — one bad file never stops the run
            errors.append({"file_id": entry["id"], "path": entry["path"], "error": f"{type(e).__name__}: {e}"})
        print(f"\r{i}/{len(manifest)} files, {len(segs)} segments, {len(errors)} errors", end="", file=sys.stderr)
    write_jsonl(paths.segments_path(), [s.to_dict() for s in segs])
    write_jsonl(paths.errors_path(), errors)
    print(f"\n{len(segs)} segments, {len(errors)} files failed (see errors.jsonl)")


def cmd_index(args):
    segs = [Segment.from_dict(d) for d in read_jsonl(paths.segments_path())]
    digest = segments_digest(paths.segments_path())
    for name in args.models:
        try:
            with client_for(name) as c:
                r = embed_segments(c, segs, restart=lambda: client_for(name))
        except Exception as e:  # noqa: BLE001 — one model failing must not stop the others
            print(f"{name}: FAILED {type(e).__name__}: {e}", file=sys.stderr)
            continue
        save_index(name, r, digest=digest)
        print(name, {m: len(v) for m, v in r.ids.items()}, "failed", len(r.failed),
              "skipped", r.skipped_modalities, "seconds", {m: round(s) for m, s in r.seconds.items()})


def cmd_eval(args):
    manifest = read_jsonl(paths.manifest_path())
    segs = [Segment.from_dict(d) for d in read_jsonl(paths.segments_path())]
    golden = load_golden(Path(args.golden), manifest)
    digest = segments_digest(paths.segments_path())
    file_of = {s.seg_id: s.file_id for s in segs}
    rows, latency, stats, integrity = [], {}, {}, {}
    for name in args.models:
        idx = load_index(name)
        check_digest(idx, digest)
        integrity[name] = unindexed_golden(golden, {file_of[i] for ids in idx.ids.values() for i in ids})
        stats[name] = {"segments": {m: len(v) for m, v in idx.ids.items()}, "failed": len(idx.failed),
                       "skipped": idx.skipped_modalities,
                       "seconds": {m: round(s) for m, s in idx.seconds.items()}}
        search, times = SearchIndex(segs, idx), []
        with client_for(name) as c:
            for q in golden:
                t0 = time.perf_counter()
                qvec = c.embed("text", "query", [q["query"]])[0]
                times.append((time.perf_counter() - t0) * 1000)
                for variant in VARIANTS:
                    hit, rr = score(search.search(q["query"], qvec, variant), q["relevant_ids"])
                    rows.append({"model": name, "variant": variant, "tag": q["tag"], "hit": hit, "rr": rr,
                                 "query_id": q["id"]})
        times.sort()
        latency[name] = {"p50_ms": statistics.median(times), "p95_ms": times[int(0.95 * (len(times) - 1))]}
    table = aggregate(rows)
    report = render_report(table, latency, stats, decide(table), integrity=integrity)
    write_jsonl(paths.results_dir() / "rows.jsonl", rows)
    Path(args.out).write_text(report, encoding="utf-8")
    print(report)


def main():
    p = argparse.ArgumentParser(prog="bakeoff")
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("prefetch"); s.add_argument("--models", nargs="+", default=list(MODELS)); s.set_defaults(f=cmd_prefetch)
    s = sub.add_parser("sample"); s.add_argument("--golden", required=True); s.add_argument("--roots", nargs="+", required=True); s.set_defaults(f=cmd_sample)
    s = sub.add_parser("extract"); s.set_defaults(f=cmd_extract)
    s = sub.add_parser("index"); s.add_argument("--models", nargs="+", default=list(MODELS)); s.set_defaults(f=cmd_index)
    s = sub.add_parser("eval"); s.add_argument("--golden", required=True); s.add_argument("--out", required=True)
    s.add_argument("--models", nargs="+", default=list(MODELS)); s.set_defaults(f=cmd_eval)
    args = p.parse_args()
    args.f(args)


if __name__ == "__main__":
    main()
