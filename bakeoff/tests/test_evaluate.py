import pytest
import yaml

from bakeoff.evaluate import aggregate, decide, load_golden, render_report, score


def test_score():
    assert score(["a", "b", "c"], {"b"}) == (1, 0.5)
    assert score(["a"] * 10 + ["b"], {"b"}) == (0, 0.0)


def test_load_golden_maps_paths_and_rejects_unknown(tmp_path):
    manifest = [{"id": "f1", "path": "/x/a.png"}, {"id": "f2", "path": "/x/b.pdf"}]
    g = tmp_path / "golden.yaml"
    g.write_text(yaml.safe_dump([{"id": "q1", "query": "a", "tag": "image", "relevant": ["/x/a.png"]}]))
    assert load_golden(g, manifest)[0]["relevant_ids"] == {"f1"}
    g.write_text(yaml.safe_dump([{"id": "q2", "query": "z", "tag": "pdf", "relevant": ["/x/zzz.pdf"]}]))
    with pytest.raises(ValueError, match="zzz.pdf"):
        load_golden(g, manifest)


def rows(model, variant, hits):
    return [{"model": model, "variant": variant, "tag": tag, "hit": h, "rr": float(h)}
            for tag, h in hits]


def test_aggregate_and_decide_gemma_by_default():
    data = rows("gemma", "per_modality", [("image", 1), ("pdf", 1), ("doc", 0)]) + \
           rows("gemma", "no_audio", [("image", 1), ("pdf", 1), ("doc", 0)]) + \
           rows("gemma", "combined", [("image", 0), ("pdf", 1), ("doc", 0)]) + \
           rows("qwen-vl", "no_audio", [("image", 1), ("pdf", 1), ("doc", 0)])
    t = aggregate(data)
    assert t[("gemma", "per_modality")]["image"]["hit10"] == 1.0
    assert t[("gemma", "per_modality")]["all"]["n"] == 3
    d = decide(t)
    assert "EmbeddingGemma 2" in d and "per-modality kept" in d


def test_decide_qwen_wins_by_margin():
    data = rows("gemma", "no_audio", [("image", 0), ("pdf", 1), ("doc", 1)]) + \
           rows("gemma", "combined", [("image", 0), ("pdf", 1), ("doc", 1)]) + \
           rows("qwen-vl", "no_audio", [("image", 1), ("pdf", 1), ("doc", 1)])
    assert "Qwen3-VL" in decide(aggregate(data))


def test_render_report_has_tables():
    t = aggregate(rows("gemma", "per_modality", [("image", 1)]))
    md = render_report(t, {"gemma": {"p50_ms": 40.0, "p95_ms": 90.0}}, {"gemma": {"failed": 0}}, "x")
    assert "| gemma | per_modality |" in md and "p95" in md


def test_decide_uses_no_audio_variant_for_model_choice():
    data = rows("gemma", "no_audio", [("image", 1), ("pdf", 1), ("doc", 1)]) + \
           rows("gemma", "per_modality", [("image", 0), ("pdf", 0), ("doc", 0)]) + \
           rows("gemma", "combined", [("image", 0), ("pdf", 0), ("doc", 0)]) + \
           rows("qwen-vl", "no_audio", [("image", 1), ("pdf", 1), ("doc", 1)]) + \
           rows("qwen-vl", "per_modality", [("image", 1), ("pdf", 1), ("doc", 1)])
    assert "EmbeddingGemma 2" in decide(aggregate(data))


def test_unindexed_golden_listed():
    from bakeoff.evaluate import unindexed_golden
    golden = [{"id": "q1", "relevant_ids": {"f1"}}, {"id": "q2", "relevant_ids": {"f2", "f3"}}]
    indexed_files = {"f1", "f3"}
    assert unindexed_golden(golden, indexed_files) == [("q2", "f2")]


def test_render_report_lists_integrity_problems():
    t = aggregate(rows("gemma", "per_modality", [("image", 1)]))
    md = render_report(t, {}, {}, "x", integrity={"gemma": [("q2", "f2")]})
    assert "Run integrity" in md and "q2" in md
