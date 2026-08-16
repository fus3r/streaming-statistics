# Numerical checks

## Reservoir uniformity diagnostic

The reservoir check runs the fixed Algorithm R protocol over 50,000 explicit
seeds, a stream of 32 distinct positions, and capacity 4:

```sh
dune exec experiments/reservoir_uniformity.exe
```

Each position has marginal inclusion probability `4 / 32`. The command reports
the largest absolute deviation from the expected hit count in binomial standard
deviations, and fails above a pre-specified six-standard-deviation limit. This
is a diagnostic for material positional bias in this fixed protocol, not proof
of pseudorandom independence or a general statistical guarantee. It is kept
outside the `runtest` alias so CI checks only deterministic contracts.

## Summary stability gate

This directory keeps numerical experiments outside the library API. The J3 gate
uses twelve exactly representable integer-valued observations near `1e9`, where
the direct `sum_sq / n - mean * mean` identity is vulnerable to cancellation.

`summary_stability.ml` emits three rows:

- the deliberately fragile `sum`/`sum_sq` baseline;
- sequential Welford updates;
- a left-fold Chan merge over four partitions of three observations.

`check_summary_stability.py` rebuilds the oracle at 80 decimal digits from the
exact binary64 values consumed by OCaml. Welford and Chan must stay within these
absolute tolerances on this fixed corpus:

| Statistic | Tolerance |
| --- | ---: |
| Sum | `1e-5` |
| Mean | `1e-7` |
| Population variance | `1e-8` |

The naive row is diagnostic and has no pass threshold. These tolerances are a
regression gate for this corpus, not a general floating-point error bound.

Run the check with:

```sh
dune runtest
```
