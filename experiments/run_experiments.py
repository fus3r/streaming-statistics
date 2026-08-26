#!/usr/bin/env python3
"""Regenerate and verify every tracked numerical-experiment artifact."""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "results" / "manifest.json"
STAGES = (
    ROOT / "experiments" / "run_moment_stability.py",
    ROOT / "experiments" / "run_quantile_accuracy.py",
)
TRACKED_ARTIFACTS = (
    "figures/moment_stability.svg",
    "figures/quantile_accuracy.svg",
    "results/moment_stability.csv",
    "results/quantile_accuracy.csv",
)


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


def source_digest(paths: list[Path]) -> str:
    digest = hashlib.sha256()
    for path in paths:
        relative = path.relative_to(ROOT).as_posix().encode()
        digest.update(len(relative).to_bytes(4, "big"))
        digest.update(relative)
        payload = path.read_bytes()
        digest.update(len(payload).to_bytes(8, "big"))
        digest.update(payload)
    return digest.hexdigest()


def require_mapping(manifest: dict[str, object], key: str) -> dict[str, object]:
    value = manifest.get(key)
    if not isinstance(value, dict):
        raise AssertionError(f"manifest field {key!r} must be an object")
    return value


def validate_artifacts(manifest: dict[str, object]) -> None:
    artifacts = require_mapping(manifest, "artifacts")
    if set(artifacts) != set(TRACKED_ARTIFACTS):
        raise AssertionError(
            "manifest must hash exactly the two CSV and two SVG artifacts"
        )
    for relative in TRACKED_ARTIFACTS:
        expected = artifacts.get(relative)
        path = ROOT / relative
        if not isinstance(expected, str) or not path.is_file():
            raise AssertionError(f"missing tracked artifact contract: {relative}")
        observed = sha256(path)
        if observed != expected:
            raise AssertionError(f"artifact differs from its manifest hash: {relative}")


def validate_datasets(manifest: dict[str, object]) -> None:
    datasets = require_mapping(manifest, "datasets")
    if not datasets:
        raise AssertionError("manifest must record generated dataset provenance")
    for name, entry in datasets.items():
        if not isinstance(entry, dict):
            raise AssertionError(f"dataset {name!r} must be an object")
        relative = entry.get("path")
        expected_hash = entry.get("sha256")
        expected_rows = entry.get("rows")
        if not isinstance(relative, str) or not isinstance(expected_hash, str):
            raise AssertionError(f"dataset {name!r} is missing its path or hash")
        if not isinstance(expected_rows, int):
            raise AssertionError(f"dataset {name!r} is missing its row count")
        path = ROOT / relative
        if not path.is_file() or sha256(path) != expected_hash:
            raise AssertionError(f"dataset differs from its manifest hash: {name}")
        with path.open(encoding="utf-8") as source:
            observed_rows = sum(1 for _ in source)
        if observed_rows != expected_rows:
            raise AssertionError(
                f"dataset {name!r} has {observed_rows} rows, expected {expected_rows}"
            )


def main() -> None:
    for stage in STAGES:
        subprocess.run([sys.executable, stage], cwd=ROOT, check=True)

    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    if not isinstance(manifest, dict):
        raise AssertionError("manifest root must be an object")

    paths = source_paths()
    missing_sources = [path for path in paths if not path.is_file()]
    if missing_sources:
        missing = ", ".join(
            path.relative_to(ROOT).as_posix() for path in missing_sources
        )
        raise AssertionError(f"missing experiment source files: {missing}")

    manifest["schema_version"] = 3
    manifest["commands"] = {
        "all": "python3 experiments/run_experiments.py",
        "moment_stability": "python3 experiments/run_moment_stability.py",
        "quantile_accuracy": "python3 experiments/run_quantile_accuracy.py",
    }
    manifest["experiment_source_sha256"] = source_digest(paths)
    manifest["source_provenance"] = {
        "identity_field": "experiment_source_sha256",
        "included_paths": [path.relative_to(ROOT).as_posix() for path in paths],
        "kind": "repository_source_snapshot",
        "repository": "https://github.com/fus3r/streaming-statistics",
    }

    validate_datasets(manifest)
    validate_artifacts(manifest)
    MANIFEST.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )

    print("verified 2 CSV files, 2 SVG figures, and results/manifest.json")


if __name__ == "__main__":
    main()
