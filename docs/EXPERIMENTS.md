# Numerical experiments

These experiments characterize fixed synthetic inputs. They are numerical
checks, not throughput benchmarks, market models, or general error guarantees.

## 1. Moment stability and reduction shape

The first experiment measures how stream order, partition size, and reduction
shape affect binary64 moment estimates.

### Protocol

Five univariate streams and three paired streams each contain 12,000
observations. The base deviation at position `i` is

```text
(((i * 37) mod 101) - 50) * 0.001
```

The univariate cases vary scale, a `1e12` offset, and interleaved, sorted, or
seed-731 shuffled order. The paired cases isolate centred, large-offset, and
scale-imbalanced covariance and regression calculations. They are numerical
stress cases, not data models.

For chunk sizes 31, 257, and 1,024, the experiment compares:

- the deliberately fragile `sum_sq / n - mean * mean` variance identity;
- sequential Welford updates;
- Chan merges over a left fold and a balanced tree;
- 32 random-pair schedules fixed by seeds 0 through 31.

For a random-pair schedule, the OCaml driver repeatedly draws two distinct
positions from the current list of partial summaries, treats the first draw as
the left operand and the second as the right operand, and returns the merged
summary to the list. A seed therefore fixes the pairings, orientation, and tree
shape. This procedure is not a uniform sample of binary trees.

All datasets have the same length and use the same chunk sizes, so a given seed
induces the same schedule for `Summary` and `Bivariate`. Deterministic methods
appear once per dataset, statistic, and chunk-size cell. All 32 `chan_random`
observations remain in the CSV. The expected total is exactly 2,880 data rows.

### Oracles and outputs

The Python oracle first parses the generated decimal text as binary64, then
uses `Decimal.from_float` at 80-digit precision for univariate statistics and
100-digit precision for centred bivariate co-moments. The CSV records absolute,
relative, and ULP-scaled error, plus each estimate's binary64 bit pattern.

Undefined correlation or regression results stay as `nan`; they are not
replaced with a plausible endpoint. The manifest counts undefined correlation
rows separately and excludes non-finite errors from finite maximum summaries.

The figure uses the 257-value partition. For `chan_random`, each bar is the
median error and its whisker is the observed minimum-to-maximum range across
the 32 schedules. These ranges are neither confidence intervals, worst cases,
nor error bounds. Identical results across all schedules are retained as a
valid negative result.

### Reproduction

Using Python 3.10 or later:

```sh
python3 -m pip install -r requirements-experiments.txt
python3 experiments/run_experiments.py
```

The command builds the OCaml driver and rewrites both experiment CSV files,
both SVG figures, and `results/manifest.json`. Each figure is generated only
after its CSV has been written and reloaded. Temporary generated inputs are
ignored by Git. A second run in the same recorded environment must reproduce
all five tracked outputs byte for byte.

The protocol is motivated by Higham's analysis of summation order and by
Demmel and Nguyen's work on reproducible reductions. Those references explain
why order and tree shape are measured; they do not provide a transferable bound
for this implementation.

- Nicholas J. Higham, "The Accuracy of Floating Point Summation", 1993:
  <https://doi.org/10.1137/0914050>
- James Demmel and Hong Diep Nguyen, "Fast Reproducible Floating-Point
  Summation", 2013: <https://doi.org/10.1109/ARITH.2013.9>

## 2. Quantile rank error, value error, and retained items

The second experiment evaluates normal, signed heavy-tailed, regime-change,
and duplicate-heavy streams at seven normalized ranks. Each stream contains
20,000 values. The fixed KLL capacities are 32, 64, and 128; the fixed seeds
are 11, 29, 47, 83, and 101.

`Exact_median` is checked against a full sort. Each KLL trial is built twice:
once by sequential insertion, and once by a balanced merge of consecutive
257-value partitions. The quantile seed initializes the stream of
per-partition seeds, while `20260812 + seed` initializes the stream of merge
seeds. This is one topology fixed before execution, not a search over
favourable partitions or trees.

### Oracles and error measures

The KLL oracle is the lower empirical quantile at
`floor(q * (n - 1))`. The target index is computed with the exact rational
value of the binary64 query rather than through an intermediate rounded count.
Every KLL row records the returned value, the sorted oracle, absolute value
error, target index, tie interval, normalized rank error, and retained-item
count.

For a returned value occupying sorted indices `[lower, upper]`, rank error is
the distance from the target index to that interval, divided by `n - 1`. It is
zero when the target lies inside the interval. This prevents duplicate-heavy
inputs from assigning an artificial error to a correct tied value.

The exact-median rows leave the rank fields empty. With an even number of
observations, the exact median can be the average of two values rather than an
empirical lower quantile.

Retained items measure the logical KLL payload. They exclude unused allocated
slots, allocator overhead, and process RSS. The figure reports the worst rank
error observed across the fixed datasets, queries, and seeds, plus mean
retained count. Neither curve is a bound.

### Observed distinction between rank and value error

The manifest summarizes relative value error only at `q = 0.01` and
`q = 0.99` for the signed Pareto stream, where both oracle values are nonzero.
The largest fixed observation occurs at `q = 0.99`, capacity 32, seed 83, with
sequential insertion: normalized rank error is `0.00895045`, while relative
value error is `3.97312`. The returned value is about `68.6947`, versus a
sorted oracle of about `13.8132`.

This is an observed consequence of sparse tail spacing, not an accuracy
guarantee, a worst case, or a financial-risk model. Rank error is the quantity
KLL is designed to control; small rank error must not be restated as small
error in the units of the data.

### Reproduction

The complete reproduction command above also regenerates this experiment. Its
quantile stage:

```sh
python3 experiments/run_quantile_accuracy.py
```

The command validates the tracked J10 artifact hashes, builds the shared OCaml
driver, and rewrites `results/quantile_accuracy.csv`,
`figures/quantile_accuracy.svg`, and the J11 sections of
`results/manifest.json`. The table has exactly 844 data rows: four exact-median
rows and the complete 840-row KLL grid. A missing oracle, value error, rank
error, seed, construction, capacity, or query makes generation fail.

`experiments/run_experiments.py` runs the moment stage first, so this validation
is satisfied from a clean checkout, then verifies the dataset and artifact
hashes recorded in the completed manifest.

The rank-error protocol follows the quantity controlled by KLL; the value-error
columns make the distinct, distribution-dependent error visible:

- Zohar Karnin, Kevin Lang, and Edo Liberty, "Optimal Quantile Approximation in
  Streams", 2016: <https://arxiv.org/abs/1603.05346>
- Charles Masson, Jee E. Rim, and Homin K. Lee, "DDSketch: A Fast and Fully-
  Mergeable Quantile Sketch with Relative-Error Guarantees", 2019:
  <https://arxiv.org/abs/1908.10693>

This project does not implement DDSketch.
