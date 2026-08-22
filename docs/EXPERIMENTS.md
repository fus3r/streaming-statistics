# Moment stability experiment

This experiment measures how stream order, partition size, and reduction shape
affect binary64 moment estimates. It is a numerical characterization of fixed
synthetic inputs, not a throughput benchmark or a general error guarantee.

## Protocol

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

## Oracles and outputs

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

## Reproduction

Using Python 3.10 or later:

```sh
python3 -m pip install -r requirements-experiments.txt
python3 experiments/run_moment_stability.py
```

The command builds the OCaml driver and rewrites
`results/moment_stability.csv`, `figures/moment_stability.svg`, and
`results/manifest.json`. Temporary generated inputs are ignored by Git. A
second run in the same recorded environment must reproduce all three tracked
artifacts byte for byte.

The protocol is motivated by Higham's analysis of summation order and by
Demmel and Nguyen's work on reproducible reductions. Those references explain
why order and tree shape are measured; they do not provide a transferable bound
for this implementation.

- Nicholas J. Higham, "The Accuracy of Floating Point Summation", 1993:
  <https://doi.org/10.1137/0914050>
- James Demmel and Hong Diep Nguyen, "Fast Reproducible Floating-Point
  Summation", 2013: <https://doi.org/10.1109/ARITH.2013.9>
