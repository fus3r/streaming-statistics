# streaming-statistics

An OCaml library for statistics that update one observation at a time. Its API
keeps three distinctions visible: exact versus approximate results,
bounded versus growing storage, and summaries that can or cannot be merged.

`Summary` maintains extrema, a compensated sum, Welford's mean, and population
or sample variance. `Bivariate` maintains covariance, Pearson correlation, and
simple linear regression. Both use constant-size state and merge independent
partitions with centred-moment formulas.

`Exact_median` retains finite observations in a max-heap and a min-heap. An
insertion costs `O(log n)`, reading the median costs `O(1)`, and storage is
`O(n)`. It deliberately exposes no merge operation.

`Reservoir` implements Algorithm R for polymorphic streams. Its capacity and
seed are explicit, it retains at most `k` observations, and `sample` returns a
copy of its slots. It deliberately exposes no merge operation.

`Kll` now provides the seeded compaction core for finite floating-point
streams. It keeps weighted levels under a concrete decreasing-capacity
schedule and exposes both the accepted count and the number of retained
values. Rank/quantile queries and sketch merging remain separate planned
capabilities; no epsilon guarantee is inferred from the capacity parameter.
It applies the compactor principle from the
[KLL paper](https://arxiv.org/abs/1603.05346) but is not a byte-compatible port
of Apache DataSketches.

## Build and install

OCaml 5.1 or later and Dune 3.12 or later are required.

```sh
dune build @all
dune runtest
opam install .
```

```ocaml
open Streaming_statistics

let stats = Summary.create ()

let () =
  List.iter
    (fun x ->
      match Summary.add stats x with
      | Ok () -> ()
      | Error `Non_finite -> invalid_arg "finite observations only"
      | Error `Count_overflow -> failwith "observation count overflow")
    [ 1.; 2.; 3.; 4. ];
  Option.iter (Printf.printf "mean = %.2f\n") (Summary.mean stats)
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

## Numerical check

`dune runtest` also compares sequential Welford updates and a partitioned Chan
merge with a high-precision oracle on a small cancellation-prone corpus. The
private naive baseline and tolerances are documented in
[experiments/README.md](experiments/README.md).

## Scope

Version 0.1 is append-only. Sliding windows, retractions, serialization,
weighted observations, concurrency, servers, and market-data infrastructure are
outside its scope. No performance or error bound is claimed before a
reproducible experiment measures it.

## License

MIT
