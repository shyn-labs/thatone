"""Pure tests for length-aware batch planning. No model, never skipped."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from batching import MAX_TEXTS, TOKEN_BUDGET, plan_batches  # noqa: E402


def check(lengths, batches, budget=TOKEN_BUDGET, max_texts=MAX_TEXTS):
    flat = [i for b in batches for i in b]
    assert sorted(flat) == list(range(len(lengths)))  # every input exactly once
    for b in batches:
        assert 1 <= len(b) <= max_texts
        if len(b) > 1:
            assert max(lengths[i] for i in b) * len(b) <= budget


def test_empty_input():
    assert plan_batches([]) == []


def test_short_texts_fill_one_batch_of_sixteen():
    lengths = [100] * 16
    batches = plan_batches(lengths)
    assert batches == [list(range(16))]


def test_max_texts_respected_even_when_budget_allows():
    lengths = [10] * 40
    batches = plan_batches(lengths)
    check(lengths, batches)
    assert [len(b) for b in batches] == [16, 16, 8]


def test_budget_respected_for_long_texts():
    lengths = [2000] * 16
    batches = plan_batches(lengths)
    check(lengths, batches)
    assert all(len(b) == 4 for b in batches)  # 4 x 2000 = 8000 <= 8192


def test_single_over_budget_text_runs_alone():
    lengths = [50, 9000, 60]
    batches = plan_batches(lengths, budget=8192)
    check(lengths, batches)
    assert [1] in batches
    assert sorted(len(b) for b in batches) == [1, 2]


def test_one_long_text_does_not_inflate_the_short_ones():
    lengths = [100] * 15 + [2048]
    batches = plan_batches(lengths)
    check(lengths, batches)
    assert batches[-1] == [15]
    assert sorted(i for b in batches[:-1] for i in b) == list(range(15))


def test_sorted_ascending_and_stable_for_ties():
    lengths = [300, 10, 300, 20]
    batches = plan_batches(lengths)
    assert [i for b in batches for i in b] == [1, 3, 0, 2]


def test_order_can_be_restored():
    import random
    rng = random.Random(7)
    lengths = [rng.randint(1, 2048) for _ in range(16)]
    batches = plan_batches(lengths)
    check(lengths, batches)
    # Simulate embedding each sub-batch and scattering back by index.
    out = [None] * len(lengths)
    for b in batches:
        for i in b:
            out[i] = lengths[i]
    assert out == lengths


def test_mixed_lengths_respect_budget():
    lengths = [350, 1100, 2000, 40, 2048, 800, 120, 1500, 600, 30, 1990, 5, 700, 2047, 400, 900]
    check(lengths, plan_batches(lengths))
