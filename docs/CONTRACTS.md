# Statistical contracts

This document fixes the target behavior for v0.1 before the implementation is
added. A capability enters the public API only with the behavior and tests that
protect its contract.

## Input domain and failures

Numeric accumulators accept finite IEEE-754 binary64 values. `NaN` and both
infinities are rejected before state changes. Standalone reservoir sampling is
polymorphic and does not impose this numeric restriction.

Observation counts use `int64`. An update or merge that would exceed
`Int64.max_int` reports `Count_overflow` without changing its input.

## Empty and degenerate states

- count is defined for every state;
- extrema, means, variances, and quantiles return `None` for an empty stream;
- sample variance and covariance require at least two observations;
- correlation is undefined when either marginal variance is zero;
- simple regression is undefined when the explanatory variance is zero.

Population quantities divide by `n`; sample quantities divide by `n - 1`.
Undefined statistics use `option` rather than a sentinel float.

## Floating-point results

Moment updates and merges are exact in real arithmetic, not in binary64.
Insertion order, partitioning, and reduction shape can change low-order bits.
Bitwise associativity is not promised. Finite inputs can also produce a
non-finite result when an intermediate or final moment exceeds binary64 range.

Merge operations return a new state and leave both inputs unchanged.

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

## Randomness and compatibility

Randomized structures require an explicit seed and own their random state.
Equal seeds and operation sequences reproduce with a fixed OCaml toolchain.

Reservoir sampling does not expose a merge operation. KLL merge requires equal
capacity parameters and an explicit seed for compactions in the result. A
merged sketch need not equal one built from the concatenated raw streams.

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
