from collections import defaultdict
from pathlib import Path

import yaml

IMAGE_DOC_TAGS = ("image", "pdf", "doc")
MARGIN = 0.05


def load_golden(path: Path, manifest: list[dict]) -> list[dict]:
    by_path = {str(Path(m["path"]).resolve()): m["id"] for m in manifest}
    queries, unknown = [], []
    for q in yaml.safe_load(Path(path).read_text(encoding="utf-8")):
        ids = set()
        for rel in q["relevant"]:
            fid = by_path.get(str(Path(rel).expanduser().resolve()))
            if fid is None:
                unknown.append(f"{q['id']}: {rel}")
            else:
                ids.add(fid)
        queries.append({"id": q["id"], "query": q["query"], "tag": q["tag"], "relevant_ids": ids})
    if unknown:
        raise ValueError("relevant files not in manifest:\n" + "\n".join(unknown))
    return queries


def score(ranked: list[str], relevant: set[str], k: int = 10) -> tuple[int, float]:
    for i, f in enumerate(ranked[:k]):
        if f in relevant:
            return 1, 1.0 / (i + 1)
    return 0, 0.0


def aggregate(rows: list[dict]) -> dict:
    acc = defaultdict(lambda: defaultdict(lambda: [0, 0.0, 0]))
    for r in rows:
        for tag in (r["tag"], "all"):
            cell = acc[(r["model"], r["variant"])][tag]
            cell[0] += r["hit"]
            cell[1] += r["rr"]
            cell[2] += 1
    return {key: {tag: {"hit10": h / n, "mrr": rr / n, "n": n} for tag, (h, rr, n) in tags.items()}
            for key, tags in acc.items()}


def _mean_hit(table: dict, key: tuple, tags) -> float | None:
    cells = [table[key][t]["hit10"] for t in tags if key in table and t in table[key]]
    return sum(cells) / len(cells) if cells else None


def decide(table: dict) -> str:
    lines = []
    # no_audio gives both models the same lists (keyword, text, image); Qwen-VL has no audio.
    g = _mean_hit(table, ("gemma", "no_audio"), IMAGE_DOC_TAGS)
    q = _mean_hit(table, ("qwen-vl", "no_audio"), IMAGE_DOC_TAGS)
    if g is None:
        lines.append("Model: no Gemma results; decision blocked.")
    elif q is not None and q - g >= MARGIN:
        lines.append(f"Model: Qwen3-VL-Embedding-2B (image/pdf/doc hit@10 {q:.3f} vs Gemma {g:.3f}, "
                     f"margin ≥ {MARGIN}).")
    else:
        lines.append(f"Model: EmbeddingGemma 2 (image/pdf/doc hit@10 {g:.3f}"
                     + (f" vs Qwen3-VL {q:.3f}" if q is not None else ", Qwen3-VL did not run") + ").")
    pm = table.get(("gemma", "per_modality"), {}).get("all", {}).get("hit10")
    cb = table.get(("gemma", "combined"), {}).get("all", {}).get("hit10")
    if pm is not None and cb is not None:
        lines.append("Search: per-modality kept." if pm >= cb else
                     f"Search: combined beat per-modality ({cb:.3f} vs {pm:.3f}); revisit spec §6.")
    return "\n".join(lines)


def unindexed_golden(golden: list[dict], indexed_files: set[str]) -> list[tuple[str, str]]:
    """Golden (query, file) pairs whose file has no embedded segment: guaranteed misses."""
    return sorted((q["id"], f) for q in golden for f in q["relevant_ids"] if f not in indexed_files)


def render_report(table: dict, latency: dict, index_stats: dict, decision: str,
                  integrity: dict | None = None) -> str:
    tags = sorted({t for cells in table.values() for t in cells if t != "all"}) + ["all"]
    out = ["## Decision", "", decision, ""]
    if integrity:
        out += ["## Run integrity", "", "Golden files with no indexed segment (scored as misses):", ""]
        for model, pairs in sorted(integrity.items()):
            out.append(f"- {model}: " + (", ".join(f"{q}→{f}" for q, f in pairs) or "none"))
        out.append("")
    out += ["## hit@10 / MRR by tag", "",
           "| model | variant | " + " | ".join(tags) + " |",
           "|---|---|" + "---|" * len(tags)]
    for (model, variant), cells in sorted(table.items()):
        vals = [f"{cells[t]['hit10']:.2f} / {cells[t]['mrr']:.2f} (n={cells[t]['n']})" if t in cells else "–"
                for t in tags]
        out.append(f"| {model} | {variant} | " + " | ".join(vals) + " |")
    out += ["", "## Query embedding latency", "", "| model | p50 ms | p95 ms |", "|---|---|---|"]
    for model, lat in sorted(latency.items()):
        out.append(f"| {model} | {lat['p50_ms']:.0f} | {lat['p95_ms']:.0f} |")
    out += ["", "## Indexing", "", "| model | stats |", "|---|---|"]
    for model, stats in sorted(index_stats.items()):
        out.append(f"| {model} | {stats} |")
    return "\n".join(out) + "\n"
