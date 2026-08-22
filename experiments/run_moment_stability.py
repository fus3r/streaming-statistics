#!/usr/bin/env python3
"""Regenerate the J10 moment-stability table, figure, and manifest."""

from __future__ import annotations

import csv
import hashlib
import json
import math
import os
import platform
import random
import statistics
import struct
import subprocess
from collections import defaultdict
from decimal import Decimal, localcontext
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402


ROOT = Path(__file__).resolve().parents[1]
GENERATED = ROOT / "experiments" / "generated"
RESULTS = ROOT / "results"
FIGURES = ROOT / "figures"
DRIVER = ROOT / "_build" / "default" / "experiments" / "experiment_driver.exe"

CHUNK_SIZES = (31, 257, 1_024)
PLOT_CHUNK_SIZE = 257
MERGE_SEEDS = tuple(range(32))
EXPECTED_ROWS = 2_880
DATASET_SIZE = 12_000
CYCLE_MULTIPLIER = 37
CYCLE_MODULUS = 101
CYCLE_CENTER = 50
BASE_SCALE = 0.001
WIDE_SCALE = 1_000.0
LARGE_OFFSET = 1.0e12
SHUFFLE_SEED = 731


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


def source_digest() -> str:
    paths = [
        ROOT / "dune-project",
        ROOT / "requirements-experiments.txt",
        ROOT / "lib" / "dune",
        ROOT / "experiments" / "dune",
        ROOT / "experiments" / "experiment_driver.ml",
        ROOT / "experiments" / "run_moment_stability.py",
        *sorted((ROOT / "lib").glob("*.ml")),
        *sorted((ROOT / "lib").glob("*.mli")),
    ]
    digest = hashlib.sha256()
    for path in paths:
        relative = path.relative_to(ROOT).as_posix().encode()
        digest.update(len(relative).to_bytes(4, "big"))
        digest.update(relative)
        payload = path.read_bytes()
        digest.update(len(payload).to_bytes(8, "big"))
        digest.update(payload)
    return digest.hexdigest()


def write_values(name: str, values: list[float]) -> Path:
    path = GENERATED / f"{name}.txt"
    with path.open("w", encoding="utf-8", newline="\n") as output:
        for value in values:
            if not math.isfinite(value):
                raise ValueError(f"{name} contains a non-finite value")
            output.write(f"{value:.17g}\n")
    return path


def write_pairs(name: str, pairs: list[tuple[float, float]]) -> Path:
    path = GENERATED / f"{name}.csv"
    with path.open("w", encoding="utf-8", newline="\n") as output:
        for x, y in pairs:
            if not (math.isfinite(x) and math.isfinite(y)):
                raise ValueError(f"{name} contains a non-finite pair")
            output.write(f"{x:.17g},{y:.17g}\n")
    return path


def base_deviations() -> list[float]:
    return [
        (((index * CYCLE_MULTIPLIER) % CYCLE_MODULUS) - CYCLE_CENTER) * BASE_SCALE
        for index in range(DATASET_SIZE)
    ]


def univariate_datasets() -> dict[str, list[float]]:
    deviations = base_deviations()
    offset = [LARGE_OFFSET + value for value in deviations]
    shuffled = offset.copy()
    random.Random(SHUFFLE_SEED).shuffle(shuffled)
    return {
        "centered": deviations.copy(),
        "centered_wide": [value * WIDE_SCALE for value in deviations],
        "large_offset_interleaved": offset,
        "large_offset_sorted": sorted(offset),
        "large_offset_shuffled": shuffled,
    }


def bivariate_datasets() -> dict[str, list[tuple[float, float]]]:
    deviations = base_deviations()
    noise = [((index * 53) % 97) - 48 for index in range(DATASET_SIZE)]
    centered_x = [value * WIDE_SCALE for value in deviations]
    offset_x = [LARGE_OFFSET + value for value in deviations]
    return {
        "paired_centered": [
            (x, (-0.75 * x) + (0.02 * error))
            for x, error in zip(centered_x, noise, strict=True)
        ],
        "paired_large_offset": [
            (x, (-3.0 * LARGE_OFFSET) + (2.5 * value) + (0.00002 * error))
            for x, value, error in zip(offset_x, deviations, noise, strict=True)
        ],
        "paired_scale_imbalanced": [
            (x, (2.0e-6 * value) + (1.0e-9 * error))
            for x, value, error in zip(offset_x, deviations, noise, strict=True)
        ],
    }


def decimal_oracles(path: Path) -> dict[str, Decimal]:
    with localcontext() as context:
        context.prec = 80
        values = [
            Decimal.from_float(float(line)) for line in path.read_text().splitlines()
        ]
        count = Decimal(len(values))
        total = sum(values, Decimal(0))
        mean = total / count
        variance = sum(((value - mean) ** 2 for value in values), Decimal(0)) / count
        return {"sum": total, "mean": mean, "population_variance": variance}


def bivariate_decimal_oracles(path: Path) -> dict[str, Decimal]:
    with localcontext() as context:
        context.prec = 100
        with path.open(encoding="utf-8", newline="") as source:
            pairs = [
                (Decimal.from_float(float(x)), Decimal.from_float(float(y)))
                for x, y in csv.reader(source)
            ]
        count = Decimal(len(pairs))
        mean_x = sum((x for x, _ in pairs), Decimal(0)) / count
        mean_y = sum((y for _, y in pairs), Decimal(0)) / count
        m2_x = sum(((x - mean_x) ** 2 for x, _ in pairs), Decimal(0))
        m2_y = sum(((y - mean_y) ** 2 for _, y in pairs), Decimal(0))
        co_moment = sum(((x - mean_x) * (y - mean_y) for x, y in pairs), Decimal(0))
        covariance = co_moment / count
        correlation = co_moment / (m2_x * m2_y).sqrt()
        slope = co_moment / m2_x
        intercept = mean_y - (slope * mean_x)
        return {
            "population_covariance": covariance,
            "correlation": correlation,
            "slope": slope,
            "intercept": intercept,
        }


def parse_csv(output: str) -> list[dict[str, str]]:
    return list(csv.DictReader(output.splitlines()))


def bit_pattern(value: float) -> str:
    return struct.pack(">d", value).hex()


def numerical_errors(
    estimate: float, reference: Decimal
) -> tuple[Decimal, Decimal, float]:
    with localcontext() as context:
        context.prec = 80
        estimate_decimal = Decimal.from_float(estimate)
        absolute_decimal = abs(estimate_decimal - reference)
        relative_decimal = (
            absolute_decimal / abs(reference) if reference != 0 else absolute_decimal
        )
        unit = Decimal.from_float(math.ulp(float(reference)))
        ulp = float(absolute_decimal / unit) if unit != 0 else math.inf
    return absolute_decimal, relative_decimal, ulp


def write_csv(path: Path, rows: list[dict[str, object]]) -> None:
    fieldnames = [
        "dataset",
        "n",
        "chunk_size",
        "merge_seed",
        "method",
        "statistic",
        "estimate",
        "oracle_decimal",
        "absolute_error",
        "relative_error",
        "ulp_error",
        "binary64",
    ]
    with path.open("w", encoding="utf-8", newline="") as output:
        writer = csv.DictWriter(output, fieldnames=fieldnames, lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


def run_random_pair_schedules(
    command_prefix: list[str],
) -> list[tuple[int | None, dict[str, str]]]:
    """Run fixed schedules, retaining deterministic estimates only once."""
    output: list[tuple[int | None, dict[str, str]]] = []
    deterministic_reference: list[dict[str, str]] | None = None
    for seed in MERGE_SEEDS:
        estimates = parse_csv(run([*command_prefix, str(seed)]))
        deterministic = [row for row in estimates if row["method"] != "chan_random"]
        random_pair = [row for row in estimates if row["method"] == "chan_random"]
        if len(random_pair) != 1:
            raise AssertionError("expected one random-pair estimate per seed")
        if deterministic_reference is None:
            deterministic_reference = deterministic
            output.extend((None, row) for row in deterministic)
        elif deterministic != deterministic_reference:
            raise AssertionError(
                "deterministic reduction changed across random-pair seeds"
            )
        output.append((seed, random_pair[0]))
    return output


def result_row(
    dataset: str,
    count: int,
    chunk_size: int,
    merge_seed: int | None,
    method: str,
    statistic: str,
    estimate: float,
    reference: Decimal,
) -> dict[str, object]:
    absolute, relative, ulp = numerical_errors(estimate, reference)
    return {
        "dataset": dataset,
        "n": count,
        "chunk_size": chunk_size,
        "merge_seed": "" if merge_seed is None else merge_seed,
        "method": method,
        "statistic": statistic,
        "estimate": f"{estimate:.17g}",
        "oracle_decimal": str(reference),
        "absolute_error": str(absolute),
        "relative_error": str(relative),
        "ulp_error": f"{ulp:.17g}",
        "binary64": bit_pattern(estimate),
    }


def run_univariate_experiment(
    dataset_paths: dict[str, Path],
) -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    for dataset, path in dataset_paths.items():
        oracles = decimal_oracles(path)
        expected_count = len(path.read_text(encoding="utf-8").splitlines())
        for chunk_size in CHUNK_SIZES:
            estimates = run_random_pair_schedules(
                [os.fspath(DRIVER), "stability", os.fspath(path), str(chunk_size)]
            )
            for merge_seed, estimate_row in estimates:
                observed_count = int(estimate_row["count"])
                if observed_count != expected_count:
                    raise AssertionError(
                        f"{dataset}/{estimate_row['method']}: count {observed_count}"
                    )
                for statistic in ("sum", "mean", "population_variance"):
                    rows.append(
                        result_row(
                            dataset,
                            expected_count,
                            chunk_size,
                            merge_seed,
                            estimate_row["method"],
                            statistic,
                            float(estimate_row[statistic]),
                            oracles[statistic],
                        )
                    )
    return rows


def run_bivariate_experiment(
    dataset_paths: dict[str, Path],
) -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    statistics_names = ("population_covariance", "correlation", "slope", "intercept")
    for dataset, path in dataset_paths.items():
        oracles = bivariate_decimal_oracles(path)
        expected_count = sum(1 for _ in path.open(encoding="utf-8"))
        for chunk_size in CHUNK_SIZES:
            estimates = run_random_pair_schedules(
                [
                    os.fspath(DRIVER),
                    "bivariate-stability",
                    os.fspath(path),
                    str(chunk_size),
                ]
            )
            for merge_seed, estimate_row in estimates:
                observed_count = int(estimate_row["count"])
                if observed_count != expected_count:
                    raise AssertionError(
                        f"{dataset}/{estimate_row['method']}: count {observed_count}"
                    )
                for statistic_name in statistics_names:
                    rows.append(
                        result_row(
                            dataset,
                            expected_count,
                            chunk_size,
                            merge_seed,
                            estimate_row["method"],
                            statistic_name,
                            float(estimate_row[statistic_name]),
                            oracles[statistic_name],
                        )
                    )
    return rows


def validate_protocol(rows: list[dict[str, object]]) -> None:
    if len(rows) != EXPECTED_ROWS:
        raise AssertionError(f"expected {EXPECTED_ROWS} rows, got {len(rows)}")
    groups: dict[tuple[object, ...], list[dict[str, object]]] = defaultdict(list)
    for row in rows:
        key = (row["dataset"], row["n"], row["chunk_size"], row["statistic"])
        groups[key].append(row)
    expected_seeds = set(MERGE_SEEDS)
    for key, group in groups.items():
        random_rows = [row for row in group if row["method"] == "chan_random"]
        observed_seeds = {int(row["merge_seed"]) for row in random_rows}
        if len(random_rows) != len(MERGE_SEEDS) or observed_seeds != expected_seeds:
            raise AssertionError(f"{key}: incomplete random-pair schedule sweep")
        deterministic_methods = (
            {"naive", "welford", "chan_left", "chan_balanced"}
            if key[3] in {"sum", "mean", "population_variance"}
            else {"welford", "chan_left", "chan_balanced"}
        )
        deterministic_rows = [row for row in group if row["method"] != "chan_random"]
        if {row["method"] for row in deterministic_rows} != deterministic_methods:
            raise AssertionError(f"{key}: deterministic methods are incomplete")
        if len(deterministic_rows) != len(deterministic_methods):
            raise AssertionError(f"{key}: deterministic rows were duplicated")
        if any(row["merge_seed"] != "" for row in deterministic_rows):
            raise AssertionError(f"{key}: deterministic row has a merge seed")


def configure_plots() -> None:
    matplotlib.rcdefaults()
    matplotlib.rcParams.update(
        {
            "font.family": "DejaVu Sans",
            "font.size": 9,
            "axes.spines.top": False,
            "axes.spines.right": False,
            "svg.hashsalt": "streaming-statistics-j10",
        }
    )


def normalize_svg_whitespace(path: Path) -> None:
    lines = path.read_text(encoding="utf-8").splitlines()
    path.write_text(
        "\n".join(line.rstrip(" \t") for line in lines) + "\n", encoding="utf-8"
    )


def plot_stability(rows: list[dict[str, str]], path: Path) -> None:
    variance_rows = [
        row
        for row in rows
        if row["statistic"] == "population_variance"
        and int(row["chunk_size"]) == PLOT_CHUNK_SIZE
    ]
    covariance_rows = [
        row
        for row in rows
        if row["statistic"] == "population_covariance"
        and int(row["chunk_size"]) == PLOT_CHUNK_SIZE
    ]
    variance_datasets = list(dict.fromkeys(row["dataset"] for row in variance_rows))
    covariance_datasets = list(dict.fromkeys(row["dataset"] for row in covariance_rows))
    variance_methods = list(dict.fromkeys(row["method"] for row in variance_rows))
    covariance_methods = list(dict.fromkeys(row["method"] for row in covariance_rows))
    figure, (variance_axis, covariance_axis) = plt.subplots(
        1, 2, figsize=(10.2, 4.5), constrained_layout=True
    )
    colors = {
        "naive": "#9b2226",
        "welford": "#005f73",
        "chan_left": "#0a9396",
        "chan_balanced": "#94d2bd",
        "chan_random": "#ca6702",
    }
    method_labels = {
        "naive": "naive",
        "welford": "Welford",
        "chan_left": "Chan left",
        "chan_balanced": "Chan balanced",
        "chan_random": "random-pair schedule",
    }
    variance_labels = {
        "centered": "centered",
        "centered_wide": "centered\nwide spread",
        "large_offset_interleaved": "offset\ninterleaved",
        "large_offset_sorted": "offset\nsorted",
        "large_offset_shuffled": "offset\nshuffled",
    }
    covariance_labels = {
        "paired_centered": "centered",
        "paired_large_offset": "large\noffset",
        "paired_scale_imbalanced": "scale\nimbalanced",
    }

    def bars(
        axis,
        selected_rows: list[dict[str, str]],
        datasets: list[str],
        methods: list[str],
        labels: dict[str, str],
        value_field: str,
    ) -> None:
        width = 0.76 / len(methods)
        centers = list(range(len(datasets)))
        for offset, method in enumerate(methods):
            positions = [
                center + (offset - (len(methods) - 1) / 2) * width for center in centers
            ]
            heights: list[float] = []
            lower_errors: list[float] = []
            upper_errors: list[float] = []
            for dataset in datasets:
                values = [
                    float(row[value_field])
                    for row in selected_rows
                    if row["dataset"] == dataset and row["method"] == method
                ]
                expected = len(MERGE_SEEDS) if method == "chan_random" else 1
                if len(values) != expected:
                    raise AssertionError(
                        f"{dataset}/{method}: expected {expected} plotted values"
                    )
                center = statistics.median(values)
                heights.append(center)
                lower_errors.append(center - min(values))
                upper_errors.append(max(values) - center)
            error_options = (
                {
                    "yerr": [lower_errors, upper_errors],
                    "error_kw": {
                        "elinewidth": 0.9,
                        "capsize": 2.0,
                        "capthick": 0.9,
                    },
                }
                if method == "chan_random"
                else {}
            )
            axis.bar(
                positions,
                heights,
                width=width,
                label=method_labels[method],
                color=colors[method],
                **error_options,
            )
        axis.set_xticks(centers, [labels[dataset] for dataset in datasets])
        axis.set_xlim(-0.65, len(datasets) - 0.35)
        axis.grid(axis="y", which="both", alpha=0.18)

    bars(
        variance_axis,
        variance_rows,
        variance_datasets,
        variance_methods,
        variance_labels,
        "ulp_error",
    )
    variance_axis.set_yscale("symlog", linthresh=0.5)
    variance_axis.set_ylabel("absolute error (ULP-scaled)")
    variance_axis.set_title(f"Variance error\n{PLOT_CHUNK_SIZE}-value chunks")
    bars(
        covariance_axis,
        covariance_rows,
        covariance_datasets,
        covariance_methods,
        covariance_labels,
        "relative_error",
    )
    covariance_axis.set_yscale("symlog", linthresh=1.0e-16)
    covariance_axis.set_ylabel("relative error")
    covariance_axis.set_title(f"Covariance error\n{PLOT_CHUNK_SIZE}-pair chunks")
    handles, legend_labels = variance_axis.get_legend_handles_labels()
    figure.legend(
        handles,
        legend_labels,
        ncol=3,
        frameon=False,
        loc="outside upper center",
    )
    figure.savefig(path, format="svg", metadata={"Date": None})
    plt.close(figure)


def finite_summary(value: float) -> float | str:
    if math.isfinite(value):
        return value
    if math.isnan(value):
        return "nan"
    return "infinity" if value > 0 else "negative_infinity"


def random_pair_sensitivity_summary(rows: list[dict[str, str]]) -> dict[str, object]:
    specifications = {
        "population_variance": "ulp_error",
        "population_covariance": "relative_error",
    }
    summaries: dict[str, object] = {}
    for statistic_name, error_field in specifications.items():
        selected = [
            row
            for row in rows
            if row["method"] == "chan_random"
            and row["statistic"] == statistic_name
            and int(row["chunk_size"]) == PLOT_CHUNK_SIZE
        ]
        dataset_summaries: dict[str, object] = {}
        for dataset in dict.fromkeys(row["dataset"] for row in selected):
            dataset_rows = [row for row in selected if row["dataset"] == dataset]
            if len(dataset_rows) != len(MERGE_SEEDS):
                raise AssertionError(f"{dataset}: incomplete plotted schedule sweep")
            errors = [float(row[error_field]) for row in dataset_rows]
            dataset_summaries[dataset] = {
                "error_metric": error_field,
                "minimum": finite_summary(min(errors)),
                "median": finite_summary(statistics.median(errors)),
                "maximum": finite_summary(max(errors)),
                "distinct_binary64_results": len(
                    {row["binary64"] for row in dataset_rows}
                ),
            }
        summaries[statistic_name] = dataset_summaries
    return {
        "chunk_size": PLOT_CHUNK_SIZE,
        "schedule_count": len(MERGE_SEEDS),
        "summaries": summaries,
    }


def max_finite_error_by_method(
    rows: list[dict[str, str]], statistic_name: str, error_field: str
) -> dict[str, float | str]:
    selected = [row for row in rows if row["statistic"] == statistic_name]
    summary: dict[str, float | str] = {}
    for method in dict.fromkeys(row["method"] for row in selected):
        values = [
            float(row[error_field])
            for row in selected
            if row["method"] == method and math.isfinite(float(row[error_field]))
        ]
        summary[method] = max(values) if values else "undefined"
    return summary


def tool_version(command: list[str]) -> str:
    return run(command).splitlines()[0]


def main() -> None:
    for directory in (GENERATED, RESULTS, FIGURES):
        directory.mkdir(parents=True, exist_ok=True)
    run(["dune", "build", "experiments/experiment_driver.exe"])

    moment_paths = {
        name: write_values(f"moments_{name}", values)
        for name, values in univariate_datasets().items()
    }
    bivariate_paths = {
        name: write_pairs(f"moments_{name}", pairs)
        for name, pairs in bivariate_datasets().items()
    }
    rows = run_univariate_experiment(moment_paths)
    rows.extend(run_bivariate_experiment(bivariate_paths))
    validate_protocol(rows)

    csv_path = RESULTS / "moment_stability.csv"
    write_csv(csv_path, rows)
    with csv_path.open(encoding="utf-8", newline="") as source:
        persisted_rows = list(csv.DictReader(source))

    configure_plots()
    figure_path = FIGURES / "moment_stability.svg"
    plot_stability(persisted_rows, figure_path)
    normalize_svg_whitespace(figure_path)

    undefined_correlation_rows = [
        row
        for row in persisted_rows
        if row["statistic"] == "correlation"
        and not math.isfinite(float(row["estimate"]))
    ]
    dataset_paths = {**moment_paths, **bivariate_paths}
    manifest = {
        "schema_version": 1,
        "command": "python3 experiments/run_moment_stability.py",
        "experiment_source_sha256": source_digest(),
        "environment": {
            "platform": platform.platform(),
            "python": platform.python_version(),
            "ocaml": tool_version(["ocamlc", "-version"]),
            "dune": tool_version(["dune", "--version"]),
            "matplotlib": matplotlib.__version__,
        },
        "parameters": {
            "dataset_size": DATASET_SIZE,
            "cycle_multiplier": CYCLE_MULTIPLIER,
            "cycle_modulus": CYCLE_MODULUS,
            "cycle_center": CYCLE_CENTER,
            "base_scale": BASE_SCALE,
            "wide_scale": WIDE_SCALE,
            "large_offset": LARGE_OFFSET,
            "shuffle_seed": SHUFFLE_SEED,
            "chunk_sizes": list(CHUNK_SIZES),
            "plot_chunk_size": PLOT_CHUNK_SIZE,
            "merge_seeds": list(MERGE_SEEDS),
        },
        "protocol": {
            "expected_data_rows": EXPECTED_ROWS,
            "observed_data_rows": len(persisted_rows),
            "random_pair_schedule": (
                "Draw two distinct list positions in order, merge left into right, "
                "and repeat; this is not a uniform sample of binary trees."
            ),
            "deterministic_rows_are_not_repeated_per_seed": True,
            "summary_and_bivariate_schedules_are_paired": True,
        },
        "datasets": {
            name: {
                "path": path.relative_to(ROOT).as_posix(),
                "sha256": sha256(path),
                "rows": sum(1 for _ in path.open(encoding="utf-8")),
            }
            for name, path in sorted(dataset_paths.items())
        },
        "artifacts": {
            csv_path.relative_to(ROOT).as_posix(): sha256(csv_path),
            figure_path.relative_to(ROOT).as_posix(): sha256(figure_path),
        },
        "checks": {
            "random_pair_schedule_sensitivity": random_pair_sensitivity_summary(
                persisted_rows
            ),
            "variance_max_ulp_error_by_method": max_finite_error_by_method(
                persisted_rows, "population_variance", "ulp_error"
            ),
            "covariance_max_relative_error_by_method": max_finite_error_by_method(
                persisted_rows, "population_covariance", "relative_error"
            ),
            "correlation_max_absolute_error_by_method": max_finite_error_by_method(
                persisted_rows, "correlation", "absolute_error"
            ),
            "slope_max_relative_error_by_method": max_finite_error_by_method(
                persisted_rows, "slope", "relative_error"
            ),
            "intercept_max_absolute_error_by_method": max_finite_error_by_method(
                persisted_rows, "intercept", "absolute_error"
            ),
            "undefined_correlation_rows": {
                "total": len(undefined_correlation_rows),
                "by_method": {
                    method: sum(
                        row["method"] == method for row in undefined_correlation_rows
                    )
                    for method in dict.fromkeys(
                        row["method"] for row in undefined_correlation_rows
                    )
                },
            },
        },
        "limitations": [
            "The inputs are controlled synthetic streams, not a market model.",
            "The 32 random-pair schedules are a fixed empirical sample, not a uniform sample of binary trees or an error bound.",
            "Floating-point merge results are not expected to be bitwise associative.",
            "Regression intercept error is strongly conditioned by predictor centering and should not be read as a universal OLS accuracy score.",
        ],
    }
    manifest_path = RESULTS / "manifest.json"
    manifest_path.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )

    print(f"wrote {csv_path.relative_to(ROOT)} ({len(persisted_rows)} data rows)")
    print(f"wrote {figure_path.relative_to(ROOT)}")
    print(f"wrote {manifest_path.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
