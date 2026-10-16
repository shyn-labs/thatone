import numpy as np
import regex
from rank_bm25 import BM25Okapi

from bakeoff.index import IndexResult
from bakeoff.segments import Segment

RRF_K = 60
POOL = 100
VARIANTS = ("per_modality", "no_audio", "text_only", "combined", "keyword")
_MODALITIES = {"per_modality": None, "no_audio": ("text", "image"), "text_only": ("text",)}


def tokenize(text: str) -> list[str]:
    # \w misses combining vowel signs, which splits Kannada/Hindi words into fragments.
    return regex.findall(r"[\p{L}\p{M}\p{N}_]+", text.lower())


def rrf(lists: list[list[str]], k: int = RRF_K) -> dict[str, float]:
    scores: dict[str, float] = {}
    for ranked in lists:
        for rank, item in enumerate(ranked):
            scores[item] = scores.get(item, 0.0) + 1.0 / (k + rank + 1)
    return scores


def _knn(qvec: np.ndarray, ids: list[str], mat: np.ndarray, n: int) -> list[str]:
    sims = mat @ qvec
    order = np.argsort(-sims)[:n]
    return [ids[i] for i in order]


class SearchIndex:
    def __init__(self, segments: list[Segment], index: IndexResult):
        self.file_of = {s.seg_id: s.file_id for s in segments}
        self.index = index
        self.text_ids = [s.seg_id for s in segments if s.text.strip()]
        tokens = [tokenize(s.text) for s in segments if s.text.strip()]
        self.token_sets = [set(t) for t in tokens]
        self.bm25 = BM25Okapi(tokens) if self.text_ids else None

    def _keyword(self, query: str) -> list[str]:
        if not self.bm25:
            return []
        q = tokenize(query)
        scores = self.bm25.get_scores(q)
        # BM25Okapi gives terms present in most segments a negative weight, so filter on
        # token overlap rather than score > 0.
        order = [i for i in np.argsort(-scores) if self.token_sets[i].intersection(q)][:POOL]
        return [self.text_ids[i] for i in order]

    def search(self, query: str, qvec, variant: str, k: int = 10) -> list[str]:
        lists = [self._keyword(query)]
        if variant in _MODALITIES:
            keep = _MODALITIES[variant]
            for mod, mat in self.index.vectors.items():
                if keep is None or mod in keep:
                    lists.append(_knn(qvec, self.index.ids[mod], mat, POOL))
        elif variant == "combined":
            mods = list(self.index.vectors)
            if mods:
                ids = [i for m in mods for i in self.index.ids[m]]
                lists.append(_knn(qvec, ids, np.concatenate([self.index.vectors[m] for m in mods]), POOL))
        elif variant != "keyword":
            raise ValueError(variant)
        best: dict[str, float] = {}
        for seg_id, s in rrf(lists).items():
            f = self.file_of[seg_id]
            best[f] = max(best.get(f, 0.0), s)
        return [f for f, _ in sorted(best.items(), key=lambda kv: -kv[1])][:k]
