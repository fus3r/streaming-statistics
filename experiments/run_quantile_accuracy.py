#!/usr/bin/env python3
"""Regenerate the J11 quantile-accuracy table, figure, and manifest entries."""

from __future__ import annotations

import bisect
import csv
import hashlib
import json
import math
import os
import platform
import random
import statistics
import subprocess
from collections import defaultdict
from fractions import Fraction
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402


ROOT = Path(__file__).resolve().parents[1]
GENERATED = ROOT / "experiments" / "generated"
RESULTS = ROOT / "results"
FIGURES = ROOT / "figures"
DRIVER = ROOT / "_build" / "default" / "experiments" / "experiment_driver.exe"

CAPACITIES = (32, 64, 128)
SEEDS = (11, 29, 47, 83, 101)
QUANTILES = (0.01, 0.1, 0.25, 0.5, 0.75, 0.9, 0.99)
EXPECTED_ROWS = 844
DATASET_SIZE = 20_000
NORMAL_SEED = 1103
NORMAL_MEAN = 0.0
NORMAL_STANDARD_DEVIATION = 1.0
HEAVY_TAIL_SEED = 2207
HEAVY_TAIL_SHAPE = 1.5
HEAVY_TAIL_NEGATIVE_PROBABILITY = 0.5
REGIME_SEED = 3301
REGIME_FIRST = (-2.0, 0.5)
REGIME_SECOND = (3.0, 1.2)
MANY_TIES_SEED = 4409
MANY_TIES_VALUES = (-3.0, -1.0, 0.0, 1.0, 5.0)
MANY_TIES_WEIGHTS = (5, 15, 50, 20, 10)
MERGE_PARTITION_SIZE = 257
MERGE_SEED_BASE = 20_260_812


def run(command: list[str], *, cwd: Path = ROOT) -> str:
    completed = subprocess.run(
        command,
        cwd=cwd,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return completed.stdout.strip()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def source_paths() -> list[Path]:
    return [
        ROOT / "dune-project",
        ROOT / "requirements-experiments.txt",
        ROOT / "lib" / "dune",
        ROOT / "experiments" / "dune",
        ROOT / "experiments" / "experiment_driver.ml",
        ROOT / "experiments" / "run_moment_stability.py",
        ROOT / "experiments" / "run_quantile_accuracy.py",
        ROOT / "experiments" / "run_experiments.py",
        *sorted((ROOT / "lib").glob("*.ml")),
        *sorted((ROOT / "lib").glob("*.mli")),
    ]


def source_digest() -> str:
    digest = hashlib.sha256()
    for path in source_paths():
        relative = path.relative_to(ROOT).as_posix().encode()
        digest.update(len(relative).to_bytes(4, "big"))
        digest.update(relative)
        payload = path.read_bytes()
        digest.update(len(payload).to_bytes(8, "big"))
        digest.update(payload)
    return digest.hexdigest()


def load_moment_manifest(path: Path) -> dict[str, object]:
    manifest = json.loads(path.read_text(encoding="utf-8"))
    artifacts = manifest.get("artifacts")
    if not isinstance(artifacts, dict):
        raise AssertionError("the existing manifest has no artifact hashes")
    for relative in (
        "results/moment_stability.csv",
        "figures/moment_stability.svg",
    ):
        expected = artifacts.get(relative)
        artifact = ROOT / relative
        if not isinstance(expected, str) or not artifact.is_file():
            raise AssertionError(f"missing J10 artifact contract: {relative}")
        observed = sha256(artifact)
        if observed != expected:
            raise AssertionError(
                f"J10 artifact differs from its manifest hash: {relative}"
            )
    return manifest


def write_values(name: str, values: list[float]) -> Path:
    path = GENERATED / f"quantiles_{name}.txt"
    with path.open("w", encoding="utf-8", newline="\n") as output:
        for value in values:
            if not math.isfinite(value):
                raise ValueError(f"{name} contains a non-finite value")
            output.write(f"{value:.17g}\n")
    return path


def quantile_datasets() -> dict[str, list[float]]:
    normal_rng = random.Random(NORMAL_SEED)
    tail_rng = random.Random(HEAVY_TAIL_SEED)
    regime_rng = random.Random(REGIME_SEED)
    duplicate_rng = random.Random(MANY_TIES_SEED)
    half = DATASET_SIZE // 2
    return {
        "normal": [
            normal_rng.gauss(NORMAL_MEAN, NORMAL_STANDARD_DEVIATION)
            for _ in range(DATASET_SIZE)
        ],
        "heavy_tail": [
            (-1.0 if tail_rng.random() < HEAVY_TAIL_NEGATIVE_PROBABILITY else 1.0)
            * tail_rng.paretovariate(HEAVY_TAIL_SHAPE)
            for _ in range(DATASET_SIZE)
        ],
        "regime_change": [
            *[regime_rng.gauss(*REGIME_FIRST) for _ in range(half)],
            *[regime_rng.gauss(*REGIME_SECOND) for _ in range(DATASET_SIZE - half)],
        ],
        "many_ties": duplicate_rng.choices(
            MANY_TIES_VALUES,
            weights=MANY_TIES_WEIGHTS,
            k=DATASET_SIZE,
        ),
    }


def parse_csv(output: str) -> list[dict[str, str]]:
    return list(csv.DictReader(output.splitlines()))


def rank_interval(sorted_values: list[float], value: float) -> tuple[int, int]:
    lower = bisect.bisect_left(sorted_values, value)
    upper = bisect.bisect_right(sorted_values, value) - 1
    if lower > upper:
        raise AssertionError("a sketch returned a value outside the input stream")
    return lower, upper


def rank_error(target: int, lower: int, upper: int, count: int) -> float:
    if lower <= target <= upper:
        distance = 0
    else:
        distance = min(abs(target - lower), abs(target - upper))
    return distance / max(1, count - 1)


def run_quantile_experiment(
    datasets: dict[str, list[float]], dataset_paths: dict[str, Path]
) -> tuple[list[dict[str, object]], dict[str, float]]:
    rows: list[dict[str, object]] = []
    median_errors: dict[str, float] = {}
    for dataset, values in datasets.items():
        sorted_values = sorted(values)
        expected_median = statistics.median(sorted_values)
        recorded_exact = False
        for capacity in CAPACITIES:
            for seed in SEEDS:
                merge_seed = MERGE_SEED_BASE + seed
                commands = [
                    (
                        "sequential",
                        "",
                        "",
                        [
                            os.fspath(DRIVER),
                            "quantiles",
                            os.fspath(dataset_paths[dataset]),
                            str(capacity),
                            str(seed),
                            *[str(value) for value in QUANTILES],
                        ],
                    ),
                    (
                        "balanced_merge",
                        MERGE_PARTITION_SIZE,
                        merge_seed,
                        [
                            os.fspath(DRIVER),
                            "quantiles-merged",
                            os.fspath(dataset_paths[dataset]),
                            str(capacity),
                            str(seed),
                            str(MERGE_PARTITION_SIZE),
                            str(merge_seed),
                            *[str(value) for value in QUANTILES],
                        ],
                    ),
                ]
                for (
                    construction,
                    partition_size,
                    recorded_merge_seed,
                    command,
                ) in commands:
                    output = parse_csv(run(command))
                    if len(output) != len(QUANTILES) + 1:
                        raise AssertionError(
                            "quantile driver returned an incomplete grid"
                        )
                    exact_row = output[0]
                    if (
                        exact_row["kind"] != "exact_median"
                        or exact_row["construction"] != "exact"
                        or int(exact_row["count"]) != len(values)
                        or int(exact_row["retained"]) != len(values)
                    ):
                        raise AssertionError("invalid exact-median driver row")
                    exact_median = float(exact_row["value"])
                    median_error = abs(exact_median - expected_median)
                    median_errors[dataset] = max(
                        median_errors.get(dataset, 0.0), median_error
                    )
                    if not recorded_exact:
                        rows.append(
                            {
                                "dataset": dataset,
                                "n": len(values),
                                "method": "exact_median",
                                "construction": "exact",
                                "capacity": "",
                                "seed": "",
                                "partition_size": "",
                                "merge_seed": "",
                                "q": "",
                                "value": f"{exact_median:.17g}",
                                "oracle_value": f"{expected_median:.17g}",
                                "value_error": f"{median_error:.17g}",
                                "target_index": "",
                                "tie_lower_index": "",
                                "tie_upper_index": "",
                                "rank_error": "",
                                "retained": len(values),
                                "retained_fraction": "1",
                            }
                        )
                        recorded_exact = True
                    for expected_q, result in zip(QUANTILES, output[1:], strict=True):
                        if result["kind"] != "kll":
                            raise AssertionError("unexpected quantile driver row")
                        if result["construction"] != construction:
                            raise AssertionError("quantile construction mismatch")
                        if int(result["count"]) != len(values):
                            raise AssertionError(
                                "KLL count differs from the input size"
                            )
                        if result["partition_size"] != str(partition_size):
                            raise AssertionError("KLL partition metadata mismatch")
                        if result["merge_seed"] != str(recorded_merge_seed):
                            raise AssertionError("KLL merge-seed metadata mismatch")
                        q = float(result["q"])
                        if q != expected_q:
                            raise AssertionError("quantile driver changed query order")
                        value = float(result["value"])
                        retained = int(result["retained"])
                        if not math.isfinite(value):
                            raise AssertionError("KLL returned a non-finite quantile")
                        if not 0 < retained <= len(values):
                            raise AssertionError("KLL retained count is out of range")
                        exact_target = Fraction.from_float(q) * (len(values) - 1)
                        target = exact_target.numerator // exact_target.denominator
                        oracle_value = sorted_values[target]
                        value_error = abs(value - oracle_value)
                        lower, upper = rank_interval(sorted_values, value)
                        error = rank_error(target, lower, upper, len(values))
                        rows.append(
                            {
                                "dataset": dataset,
                                "n": len(values),
                                "method": "kll",
                                "construction": construction,
                                "capacity": capacity,
                                "seed": seed,
                                "partition_size": partition_size,
                                "merge_seed": recorded_merge_seed,
                                "q": f"{q:.17g}",
                                "value": f"{value:.17g}",
                                "oracle_value": f"{oracle_value:.17g}",
                                "value_error": f"{value_error:.17g}",
                                "target_index": target,
                                "tie_lower_index": lower,
                                "tie_upper_index": upper,
                                "rank_error": f"{error:.17g}",
                                "retained": retained,
                                "retained_fraction": f"{retained / len(values):.17g}",
                            }
                        )
    if any(error != 0.0 for error in median_errors.values()):
        raise AssertionError(f"exact median disagrees with sort: {median_errors}")
    return rows, median_errors


FIELDNAMES = [
    "dataset",
    "n",
    "method",
    "construction",
    "capacity",
    "seed",
    "partition_size",
    "merge_seed",
    "q",
    "value",
    "oracle_value",
    "value_error",
    "target_index",
    "tie_lower_index",
    "tie_upper_index",
    "rank_error",
    "retained",
    "retained_fraction",
]


def write_csv(path: Path, rows: list[dict[str, object]]) -> None:
    with path.open("w", encoding="utf-8", newline="") as output:
        writer = csv.DictWriter(output, fieldnames=FIELDNAMES, lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


def validate_protocol(rows: list[dict[str, str]]) -> None:
    if len(rows) != EXPECTED_ROWS:
        raise AssertionError(f"expected {EXPECTED_ROWS} rows, got {len(rows)}")
    exact_rows = [row for row in rows if row["method"] == "exact_median"]
    kll_rows = [row for row in rows if row["method"] == "kll"]
    expected_datasets = {"normal", "heavy_tail", "regime_change", "many_ties"}
    if (
        len(exact_rows) != len(expected_datasets)
        or {row["dataset"] for row in exact_rows} != expected_datasets
    ):
        raise AssertionError("exact-median rows are incomplete or duplicated")
    if any(float(row["value_error"]) != 0.0 for row in exact_rows):
        raise AssertionError("exact median disagrees with its sort oracle")
    if any(row["rank_error"] != "" for row in exact_rows):
        raise AssertionError("exact median must not be assigned an empirical rank")
    expected_kll_rows = (
        len(expected_datasets) * len(CAPACITIES) * len(SEEDS) * 2 * len(QUANTILES)
    )
    if len(kll_rows) != expected_kll_rows:
        raise AssertionError("KLL grid is incomplete")
    groups: dict[tuple[str, int, int, str], list[dict[str, str]]] = defaultdict(list)
    for row in kll_rows:
        for field in (
            "value",
            "oracle_value",
            "value_error",
            "target_index",
            "tie_lower_index",
            "tie_upper_index",
            "rank_error",
            "retained",
        ):
            if row[field] == "":
                raise AssertionError(f"KLL row is missing {field}")
        error = float(row["rank_error"])
        if not 0.0 <= error <= 1.0:
            raise AssertionError("normalized rank error is outside [0, 1]")
        groups[
            (
                row["dataset"],
                int(row["capacity"]),
                int(row["seed"]),
                row["construction"],
            )
        ].append(row)
    expected_queries = set(QUANTILES)
    for key, group in groups.items():
        if (
            len(group) != len(QUANTILES)
            or {float(row["q"]) for row in group} != expected_queries
        ):
            raise AssertionError(f"{key}: incomplete quantile query grid")
    if len(groups) != len(expected_datasets) * len(CAPACITIES) * len(SEEDS) * 2:
        raise AssertionError("KLL construction grid is incomplete")


def configure_plots() -> None:
    matplotlib.rcdefaults()
    matplotlib.rcParams.update(
        {
            "font.family": "DejaVu Sans",
            "font.size": 9,
            "axes.spines.top": False,
            "axes.spines.right": False,
            "svg.hashsalt": "streaming-statistics-j11",
        }
    )


def normalize_svg_whitespace(path: Path) -> None:
    lines = path.read_text(encoding="utf-8").splitlines()
    path.write_text(
        "\n".join(line.rstrip(" \t") for line in lines) + "\n", encoding="utf-8"
    )


def plot_quantiles(rows: list[dict[str, str]], path: Path) -> None:
    kll_rows = [row for row in rows if row["method"] == "kll"]
    grouped_errors: dict[tuple[str, int], list[float]] = defaultdict(list)
    grouped_retained: dict[tuple[str, int], list[int]] = defaultdict(list)
    for row in kll_rows:
        key = (row["construction"], int(row["capacity"]))
        grouped_errors[key].append(float(row["rank_error"]))
        grouped_retained[key].append(int(row["retained"]))
    constructions = list(dict.fromkeys(row["construction"] for row in kll_rows))
    colors = {"sequential": "#005f73", "balanced_merge": "#ca6702"}
    labels = {"sequential": "sequential", "balanced_merge": "balanced merge"}
    figure, (error_axis, size_axis) = plt.subplots(
        1, 2, figsize=(9.4, 4.2), constrained_layout=True
    )
    for construction in constructions:
        maximum_errors = [
            max(grouped_errors[(construction, capacity)]) for capacity in CAPACITIES
        ]
        error_axis.plot(
            CAPACITIES,
            maximum_errors,
            marker="o",
            color=colors[construction],
            label=labels[construction],
        )
        average_retained = [
            statistics.fmean(grouped_retained[(construction, capacity)])
            for capacity in CAPACITIES
        ]
        size_axis.plot(
            CAPACITIES,
            average_retained,
            marker="o",
            color=colors[construction],
            label=labels[construction],
        )
    error_axis.set_title("Worst observed rank error across fixed queries")
    error_axis.set_xlabel("KLL capacity parameter")
    error_axis.set_ylabel("normalized rank error")
    error_axis.grid(alpha=0.18)
    size_axis.set_title("Retained values")
    size_axis.set_xlabel("KLL capacity parameter")
    size_axis.set_ylabel("mean retained count")
    size_axis.grid(alpha=0.18)
    for axis in (error_axis, size_axis):
        axis.set_xticks(CAPACITIES)
        axis.set_xlim(24, 136)
    error_axis.legend(frameon=False)
    size_axis.legend(frameon=False)
    figure.set_constrained_layout_pads(w_pad=0.12, h_pad=0.08)
    figure.savefig(path, format="svg", metadata={"Date": None})
    plt.close(figure)


def heavy_tail_value_error_summary(rows: list[dict[str, str]]) -> dict[str, object]:
    selected = [
        row
        for row in rows
        if row["method"] == "kll"
        and row["dataset"] == "heavy_tail"
        and float(row["q"]) in {0.01, 0.99}
    ]
    if not selected:
        raise AssertionError("missing heavy-tail KLL endpoint rows")

    def relative_value_error(row: dict[str, str]) -> float:
        oracle = float(row["oracle_value"])
        if oracle == 0.0:
            raise AssertionError("heavy-tail endpoint oracle is zero")
        return float(row["value_error"]) / abs(oracle)

    worst = max(selected, key=relative_value_error)
    return {
        "dataset": "heavy_tail",
        "quantiles": [0.01, 0.99],
        "maximum_relative_value_error": relative_value_error(worst),
        "corresponding_absolute_value_error": float(worst["value_error"]),
        "corresponding_rank_error": float(worst["rank_error"]),
        "construction": worst["construction"],
        "capacity": int(worst["capacity"]),
        "seed": int(worst["seed"]),
        "q": float(worst["q"]),
        "oracle_value": float(worst["oracle_value"]),
        "observed_value": float(worst["value"]),
    }


def tool_version(command: list[str]) -> str:
    return run(command).splitlines()[0]


def update_manifest(
    manifest: dict[str, object],
    dataset_paths: dict[str, Path],
    csv_path: Path,
    figure_path: Path,
    rows: list[dict[str, str]],
    median_errors: dict[str, float],
) -> dict[str, object]:
    kll_rows = [row for row in rows if row["method"] == "kll"]
    constructions = list(dict.fromkeys(row["construction"] for row in kll_rows))
    max_rank_error = {
        construction: {
            str(capacity): max(
                float(row["rank_error"])
                for row in kll_rows
                if row["construction"] == construction
                and int(row["capacity"]) == capacity
            )
            for capacity in CAPACITIES
        }
        for construction in constructions
    }
    retained_range = {
        construction: {
            str(capacity): {
                "minimum": min(
                    int(row["retained"])
                    for row in kll_rows
                    if row["construction"] == construction
                    and int(row["capacity"]) == capacity
                ),
                "maximum": max(
                    int(row["retained"])
                    for row in kll_rows
                    if row["construction"] == construction
                    and int(row["capacity"]) == capacity
                ),
            }
            for capacity in CAPACITIES
        }
        for construction in constructions
    }
    manifest["schema_version"] = 3
    manifest.pop("command", None)
    manifest["commands"] = {
        "all": "python3 experiments/run_experiments.py",
        "moment_stability": "python3 experiments/run_moment_stability.py",
        "quantile_accuracy": "python3 experiments/run_quantile_accuracy.py",
    }
    manifest["experiment_source_sha256"] = source_digest()
    manifest["source_provenance"] = {
        "identity_field": "experiment_source_sha256",
        "included_paths": [
            path.relative_to(ROOT).as_posix() for path in source_paths()
        ],
        "kind": "repository_source_snapshot",
        "repository": "https://github.com/fus3r/streaming-statistics",
    }
    manifest["environment"] = {
        "platform": platform.platform(),
        "python": platform.python_version(),
        "ocaml": tool_version(["ocamlc", "-version"]),
        "dune": tool_version(["dune", "--version"]),
        "matplotlib": matplotlib.__version__,
    }
    parameters = manifest.setdefault("parameters", {})
    if not isinstance(parameters, dict):
        raise AssertionError("manifest parameters must be an object")
    parameters["quantile_accuracy"] = {
        "capacities": list(CAPACITIES),
        "seeds": list(SEEDS),
        "quantiles": list(QUANTILES),
        "dataset_size": DATASET_SIZE,
        "dataset_generation": {
            "normal": {
                "seed": NORMAL_SEED,
                "mean": NORMAL_MEAN,
                "standard_deviation": NORMAL_STANDARD_DEVIATION,
            },
            "heavy_tail": {
                "seed": HEAVY_TAIL_SEED,
                "pareto_shape": HEAVY_TAIL_SHAPE,
                "negative_probability": HEAVY_TAIL_NEGATIVE_PROBABILITY,
            },
            "regime_change": {
                "seed": REGIME_SEED,
                "split_index": DATASET_SIZE // 2,
                "first_mean": REGIME_FIRST[0],
                "first_standard_deviation": REGIME_FIRST[1],
                "second_mean": REGIME_SECOND[0],
                "second_standard_deviation": REGIME_SECOND[1],
            },
            "many_ties": {
                "seed": MANY_TIES_SEED,
                "values": list(MANY_TIES_VALUES),
                "weights": list(MANY_TIES_WEIGHTS),
            },
        },
        "balanced_merge": {
            "partition_size": MERGE_PARTITION_SIZE,
            "partition_seed": "quantile seed initializes per-partition seeds",
            "merge_seed": f"{MERGE_SEED_BASE} + quantile seed",
        },
    }
    datasets = manifest.setdefault("datasets", {})
    if not isinstance(datasets, dict):
        raise AssertionError("manifest datasets must be an object")
    datasets.update(
        {
            name: {
                "path": path.relative_to(ROOT).as_posix(),
                "sha256": sha256(path),
                "rows": sum(1 for _ in path.open(encoding="utf-8")),
            }
            for name, path in sorted(dataset_paths.items())
        }
    )
    artifacts = manifest.setdefault("artifacts", {})
    if not isinstance(artifacts, dict):
        raise AssertionError("manifest artifacts must be an object")
    artifacts.update(
        {
            csv_path.relative_to(ROOT).as_posix(): sha256(csv_path),
            figure_path.relative_to(ROOT).as_posix(): sha256(figure_path),
        }
    )
    checks = manifest.setdefault("checks", {})
    if not isinstance(checks, dict):
        raise AssertionError("manifest checks must be an object")
    checks.update(
        {
            "exact_median_max_absolute_error": max(median_errors.values()),
            "kll_max_observed_rank_error_by_construction_and_capacity": (
                max_rank_error
            ),
            "kll_retained_range_by_construction_and_capacity": retained_range,
            "kll_heavy_tail_max_observed_relative_value_error": (
                heavy_tail_value_error_summary(kll_rows)
            ),
        }
    )
    protocol = manifest.setdefault("protocol", {})
    if not isinstance(protocol, dict):
        raise AssertionError("manifest protocol must be an object")
    protocol["quantile_accuracy"] = {
        "expected_data_rows": EXPECTED_ROWS,
        "observed_data_rows": len(rows),
        "lower_quantile_target": "floor(q * (n - 1)) using exact binary64-rational q",
        "rank_error": "distance from the target index to the returned value's tie interval, divided by n - 1",
        "balanced_merge_topology": "fixed balanced tree over consecutive 257-value partitions",
    }
    limitations = manifest.setdefault("limitations", [])
    if not isinstance(limitations, list):
        raise AssertionError("manifest limitations must be an array")
    for limitation in (
        "KLL rows characterize fixed datasets and seeds; they are not a proof of a tail bound.",
        "KLL controls rank error, not value error; value-error observations depend on the distribution and scale.",
        "The balanced KLL construction is one fixed 257-item partition tree, not a survey of every merge topology.",
        "Retained values measure logical sketch payload; unused allocated slots, process RSS, and allocator overhead are excluded.",
    ):
        if limitation not in limitations:
            limitations.append(limitation)
    return manifest


def main() -> None:
    for directory in (GENERATED, RESULTS, FIGURES):
        directory.mkdir(parents=True, exist_ok=True)
    manifest_path = RESULTS / "manifest.json"
    manifest = load_moment_manifest(manifest_path)
    run(["dune", "build", "experiments/experiment_driver.exe"])

    datasets = quantile_datasets()
    dataset_paths = {
        name: write_values(name, values) for name, values in datasets.items()
    }
    rows, median_errors = run_quantile_experiment(datasets, dataset_paths)
    csv_path = RESULTS / "quantile_accuracy.csv"
    write_csv(csv_path, rows)
    with csv_path.open(encoding="utf-8", newline="") as source:
        persisted_rows = list(csv.DictReader(source))
    validate_protocol(persisted_rows)

    configure_plots()
    figure_path = FIGURES / "quantile_accuracy.svg"
    plot_quantiles(persisted_rows, figure_path)
    normalize_svg_whitespace(figure_path)

    manifest = update_manifest(
        manifest,
        dataset_paths,
        csv_path,
        figure_path,
        persisted_rows,
        median_errors,
    )
    manifest_path.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )

    print(f"wrote {csv_path.relative_to(ROOT)}")
    print(f"wrote {figure_path.relative_to(ROOT)}")
    print(f"updated {manifest_path.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
