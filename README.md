# streaming-statistics

An OCaml library for statistics that update one observation at a time. Its API
will keep three distinctions visible: exact versus approximate results,
bounded versus growing storage, and summaries that can or cannot be merged.

This first commit fixes the package boundary and statistical contracts. It does
not yet expose a statistical accumulator.

## Build and install

OCaml 5.1 or later and Dune 3.12 or later are required.

```sh
dune build @all
dune runtest
opam install .
```

## Planned v0.1 capabilities

| Component | Result | Update | Storage | Merge |
| --- | --- | --- | --- | --- |
| `Summary` | moments, extrema, compensated sum | `O(1)` | `O(1)` | yes |
| `Bivariate` | covariance, correlation, simple OLS | `O(1)` | `O(1)` | yes |
| `Exact_median` | exact median | `O(log n)` | `O(n)` | no |
| `Reservoir` | uniform sample | expected `O(1)` | `O(k)` | no |
| `Kll` | approximate empirical quantiles | amortized compaction | capacity-controlled | compatible sketches |
| `Bundle` | configured one-pass composition | follows components | follows components | no |

The conventions for empty streams, estimators, non-finite values, quantiles,
seeds, and merges are fixed in [docs/CONTRACTS.md](docs/CONTRACTS.md).

## Scope

Version 0.1 is append-only. Sliding windows, retractions, serialization,
weighted observations, concurrency, servers, and market-data infrastructure are
outside its scope. No performance or error bound is claimed before a
reproducible experiment measures it.

## License

MIT
