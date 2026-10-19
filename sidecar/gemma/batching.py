"""Length-aware batch planning for text embedding. Pure: no MLX, so it is testable without the model.

The model pads every text in a batch to the longest one, so activation memory scales with
(texts in the batch) x (longest text). Grouping texts of similar length and capping that product
keeps one long code chunk from costing a whole batch of maximum-length rows.
"""

TOKEN_BUDGET = 8192  # padded tokens per forward pass: max length in the sub-batch x number of texts
MAX_TEXTS = 16


def plan_batches(lengths, budget=TOKEN_BUDGET, max_texts=MAX_TEXTS):
    """Split input indices into sub-batches, shortest first.

    Each sub-batch satisfies max(lengths in it) * len(sub-batch) <= budget and len <= max_texts,
    except that a single text longer than the budget runs alone. Every index appears exactly once.
    """
    order = sorted(range(len(lengths)), key=lambda i: (lengths[i], i))
    batches, cur = [], []
    for i in order:
        # Sorted ascending, so the candidate is the longest in the batch if added.
        if cur and (len(cur) + 1 > max_texts or lengths[i] * (len(cur) + 1) > budget):
            batches.append(cur)
            cur = []
        cur.append(i)
    if cur:
        batches.append(cur)
    return batches
