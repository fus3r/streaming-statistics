# Changes

## 0.1.0 (unreleased)

- Add mergeable univariate and bivariate moment accumulators.
- Return an undefined correlation when binary64 roundoff moves its ratio
  materially outside `[-1, 1]` instead of clamping it to an endpoint.
- Add exact median maintenance and seeded reservoir sampling.
- Add a seeded weighted KLL hierarchy with lower empirical quantiles and
  compatible-capacity merges.
- Add one-pass composition while preserving each component's storage and merge
  contract.
- Add deterministic tests, runnable examples, and reproducible moment and
  quantile experiments against independent oracles.
