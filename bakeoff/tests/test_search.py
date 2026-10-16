import numpy as np

from bakeoff.index import IndexResult
from bakeoff.search import SearchIndex, rrf, tokenize
from bakeoff.segments import Segment


def unit(*xs):
    v = np.array(xs, dtype=np.float32)
    return v / np.linalg.norm(v)


def test_tokenize():
    assert tokenize("Invoice #4471, Kite-order!") == ["invoice", "4471", "kite", "order"]


def test_rrf_sums_ranks():
    s = rrf([["a", "b"], ["b", "c"]], k=60)
    assert s["b"] > s["a"] > s["c"]


def build():
    segs = [
        Segment("pdf:0", "pdf", "pdf", "text", {"page": 1}, text="biochar soil carbon report"),
        Segment("pdf:1", "pdf", "pdf", "text", {"page": 2}, text="biochar appendix tables"),
        Segment("doc:0", "doc", "doc", "text", {}, text="biochar meeting notes"),
        Segment("img:0", "img", "image", "image", {}, text="", media="/p.png"),
    ]
    # text vectors all sit near the query; the image is less similar in raw cosine (modality gap)
    idx = IndexResult(
        ids={"text": ["pdf:0", "pdf:1", "doc:0"], "image": ["img:0"]},
        vectors={"text": np.stack([unit(1, 0.1, 0), unit(1, 0.2, 0), unit(1, 0.3, 0)]),
                 "image": np.stack([unit(0.6, 0, 0.8)])},
    )
    return SearchIndex(segs, idx)


# "zzz" has no keyword hits, so these two tests isolate the vector lists.
def test_combined_lets_text_crowd_out_image():
    ranked = build().search("zzz", unit(1, 0, 0), "combined", k=3)
    assert ranked == ["pdf", "doc", "img"]


def test_per_modality_lifts_image_and_groups_files():
    ranked = build().search("zzz", unit(1, 0, 0), "per_modality", k=10)
    assert ranked.index("img") < ranked.index("doc")
    assert len(ranked) == len(set(ranked)) == 3


def test_keyword_only():
    ranked = build().search("appendix tables", None, "keyword", k=10)
    assert ranked[0] == "pdf"


def test_keyword_keeps_matches_when_term_is_in_every_segment():
    segs = [Segment("a:0", "a", "doc", "text", {}, text="biochar trial notes"),
            Segment("a:1", "a", "doc", "text", {}, text="biochar trial notes again")]
    idx = SearchIndex(segs, IndexResult())
    assert idx.search("biochar trial", None, "keyword") == ["a"]


def test_tokenize_keeps_kannada_and_hindi_words_whole():
    assert tokenize("ಬೆಂಗಳೂರು ಮನೆ दस्तावेज़") == ["ಬೆಂಗಳೂರು", "ಮನೆ", "दस्तावेज़"]


def build_with_audio():
    s = build()
    s.index.ids["audio"] = ["clip:0"]
    s.index.vectors["audio"] = np.stack([unit(1, 0, 0)])
    s.file_of["clip:0"] = "clip"
    return s


def test_text_only_variant_uses_keyword_and_text_lists():
    ranked = build_with_audio().search("zzz", unit(1, 0, 0), "text_only", k=10)
    assert set(ranked) == {"pdf", "doc"}


def test_no_audio_variant_drops_audio_list():
    ranked = build_with_audio().search("zzz", unit(1, 0, 0), "no_audio", k=10)
    assert "clip" not in ranked and "img" in ranked
