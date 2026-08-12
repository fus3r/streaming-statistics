# Summary stability gate

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
