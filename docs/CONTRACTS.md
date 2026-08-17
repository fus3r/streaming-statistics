# Statistical contracts

This document fixes the target behavior for v0.1 before the implementation is
added. A capability enters the public API only with the behavior and tests that
protect its contract.

## Input domain and failures

Numeric accumulators accept finite IEEE-754 binary64 values. `NaN` and both
infinities are rejected before state changes. Standalone reservoir sampling is
polymorphic and does not impose this numeric restriction.

`Summary` and `Bivariate` observation counts use `int64`. An update or merge
that would exceed `Int64.max_int` reports `Count_overflow` without changing its
input.

`Kll` also uses an `int64` observation count. An addition at
`Int64.max_int`, or a non-finite addition, is rejected before changing its
levels or consuming randomness.

`Reservoir` also uses an `int64` observation count. An addition at
`Int64.max_int` reports `Count_overflow` before changing its sample or random
state.

## Empty and degenerate states

- count is defined for every state;
- extrema, means, variances, and quantiles return `None` for an empty stream;
- sample variance and covariance require at least two observations;
- correlation is undefined when either marginal variance is zero;
- simple regression is undefined when the explanatory variance is zero;
- correlation and regression return `None` if their normalized result cannot be
  represented as a finite binary64 value. Correlation also returns `None` when
  accumulated roundoff puts it materially outside `[-1, 1]`; only an endpoint
  overshoot within eight binary64 epsilons is rounded to that endpoint.

Population quantities divide by `n`; sample quantities divide by `n - 1`.
Undefined statistics use `option` rather than a sentinel float.

## Floating-point results

`Summary` uses Welford updates and `Bivariate` uses the corresponding centred
co-moment update. Their pairwise merges use Chan's formulas. These operations
are exact in real arithmetic, not in binary64. Insertion order, partitioning,
and reduction shape can change low-order bits. Bitwise associativity is not
promised. Finite inputs can also produce a non-finite result when an
intermediate or final moment exceeds binary64 range.

Merge operations return a new state and leave both inputs unchanged. An empty
`Summary` or `Bivariate` is an identity for its merge, and the result is still a
fresh state. Their merge functions can report only `Count_overflow`, because
their inputs contain observations that have already passed validation.

## Quantiles

For `n` observations and `q` in `[0, 1]`, the lower empirical quantile uses the
zero-based index:

```text
floor(q * (n - 1))
```

The binary64 value of `q` is interpreted exactly when this index is formed.
Exact median instead averages the two middle observations for an even count.
Approximate rank error treats equal values as the whole interval occupied by
the tie.

`Exact_median` keeps the lower half in a max-heap and the upper half in a
min-heap. It inserts in `O(log n)`, reads the heap roots in `O(1)`, retains all
observations in `O(n)` storage, and does not expose a merge operation.

The current `Kll` API exposes its seeded compaction hierarchy, not queries or
merge. Level `i` has weight `2^i`. With `h` levels, its capacity is the
configured capacity reduced `h - i - 1` times by `ceil(2k/3)`, with a minimum
of eight. Compaction sorts an overflowing level and randomly promotes one
parity; an odd population keeps one randomly selected endpoint at its current
weight. The configured capacity controls this schedule but is neither a strict
item ceiling nor, by itself, a claimed rank-error guarantee.

## Randomness and compatibility

Randomized structures require an explicit seed and own their random state.
Equal seeds and operation sequences reproduce with a fixed OCaml toolchain.

`Reservoir` implements Algorithm R with a fixed positive capacity. It returns a
copy of its retained slots and does not expose a merge operation. KLL merge
requires equal capacity parameters and an explicit seed for compactions in the
result. A merged sketch need not equal one built from the concatenated raw
streams.

## Planned capability matrix

| Component | Exact | Fixed-size state | Merge | Randomized |
| --- | --- | --- | --- | --- |
| `Summary` | real-arithmetic moments | yes | yes | no |
| `Bivariate` | real-arithmetic moments | yes | yes | no |
| `Exact_median` | yes | no | no | no |
| `Reservoir` | uniform sample | capacity-bounded | no | yes |
| `Kll` | approximate ranks | capacity-controlled | compatible sketches | yes |
| `Bundle` | follows its components | no | no | if configured |

The absence of a universal `merge` or `remove` operation is intentional.
