# streaming-statistics

An OCaml library for statistics that update one observation at a time. The API
keeps exact and approximate results, bounded and growing storage, and mergeable
and non-mergeable accumulators distinct.

Version 0.1 is append-only. It contains no rolling-window, serialization, or
concurrency framework.

## Install and use

The package requires OCaml 5.1 or later and Dune 3.12 or later. CI tests the
release candidate on OCaml 5.1.1 and 5.5.0.

From a checkout:

```sh
opam install . --deps-only --with-test --with-doc
dune build @all @doc
dune runtest
dune exec examples/basic.exe
dune exec examples/quantiles.exe
```

Install the package in the current switch with:

```sh
opam install . --with-test --with-doc
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
    [ 101.2; 100.8; 101.6; 102.0; 100.4 ];
  Option.iter (Printf.printf "mean = %.4f\n") (Summary.mean stats)
```

## Capabilities

| Module | Result | Update | Storage | Merge |
| --- | --- | --- | --- | --- |
| `Summary` | moments, extrema, compensated sum | `O(1)` | `O(1)` | yes |
| `Bivariate` | covariance, Pearson correlation, simple OLS | `O(1)` | `O(1)` | yes |
| `Exact_median` | exact median | `O(log n)` | `O(n)` | no |
| `Reservoir` | uniform sample of at most `k` items | expected `O(1)` | `O(k)` | no |
| `Kll` | approximate empirical quantiles | amortized compaction | capacity-controlled | equal capacities |
| `Bundle` | configured univariate components in one pass | follows components | follows components | no |

`Summary` uses Welford updates and Chan's pairwise merge formulas. `Bivariate`
uses the corresponding centred co-moment formulas. `Reservoir` implements
Algorithm R. `Kll` is a seeded weighted compactor hierarchy, not a
byte-compatible port of Apache DataSketches.

The conventions for empty streams, estimators, non-finite values, quantiles,
seeds, and merges are fixed in [docs/CONTRACTS.md](docs/CONTRACTS.md). The
unreleased changes are listed in [CHANGES.md](CHANGES.md).

## Reproduce the numerical evidence

One command regenerates the two CSV tables, two SVG figures, and their compact
manifest:

```sh
python3 -m pip install -r requirements-experiments.txt
python3 experiments/run_experiments.py
```

The fixed moment protocol includes a sorted stream near `1e12` whose population
variance oracle is `0.0008499154`. Sequential Welford returns `0.003354809`, a
balanced Chan reduction over 257-value chunks returns `0.0008513299`, and the
naive identity returns about `8.75e10`. This demonstrates sensitivity to
conditioning and reduction shape, not a universally preferable merge tree.

In the fixed signed-Pareto trials, the sequential capacity-32 KLL sketch with
seed 83 has `0.895%` normalized rank error at `q = 0.99` and `397.3%` relative
value error. This retained observation shows that small rank error need not
imply small value error in a sparse tail; it is not a bound or a risk model.

See the [protocol](docs/EXPERIMENTS.md),
[moment table](results/moment_stability.csv),
[quantile table](results/quantile_accuracy.csv), and
[manifest](results/manifest.json) before interpreting the
[moment](figures/moment_stability.svg) and
[quantile](figures/quantile_accuracy.svg) figures.

## Limits

- Numeric accumulators and `Bundle` accept only finite binary64 observations;
  standalone `Reservoir` is polymorphic.
- Floating-point merges are not bitwise associative.
- Covariance, correlation, and OLS accuracy depend on scale and centering.
- Exact median retains the full stream, and Reservoir deliberately has no
  merge operation.
- KLL `capacity` is neither a strict retained-item ceiling nor a promised
  epsilon. Rank error does not bound value error.
- Sliding windows, retractions, serialization, weighted observations,
  concurrency, servers, and market-data infrastructure are outside `v0.1`.

## License

MIT
