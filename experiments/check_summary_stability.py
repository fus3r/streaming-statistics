#!/usr/bin/env python3
"""Check Summary results against the exact values of the binary64 corpus."""

from __future__ import annotations

import csv
import math
import subprocess
import sys
from decimal import Decimal, localcontext
from pathlib import Path


TOLERANCES = {
    "sum": Decimal("1e-5"),
    "mean": Decimal("1e-7"),
    "population_variance": Decimal("1e-8"),
}


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: check_summary_stability.py EXECUTABLE DATA")

    executable = Path(sys.argv[1]).resolve()
    data = Path(sys.argv[2]).resolve()
    completed = subprocess.run(
        [executable, data], check=True, capture_output=True, text=True
    )
    rows = {row["method"]: row for row in csv.DictReader(completed.stdout.splitlines())}
    if set(rows) != {"naive", "welford", "chan"}:
        raise AssertionError(f"unexpected methods: {sorted(rows)}")

    values = [float(line) for line in data.read_text(encoding="utf-8").splitlines()]
    with localcontext() as context:
        context.prec = 80
        exact_values = [Decimal.from_float(value) for value in values]
        count = Decimal(len(exact_values))
        total = sum(exact_values, Decimal(0))
        mean = total / count
        variance = sum((value - mean) ** 2 for value in exact_values) / count
        oracle = {
            "sum": total,
            "mean": mean,
            "population_variance": variance,
        }

        for method in ("welford", "chan"):
            row = rows[method]
            if int(row["count"]) != len(values):
                raise AssertionError(f"{method}: incorrect count {row['count']}")
            for statistic, tolerance in TOLERANCES.items():
                observed = float(row[statistic])
                if not math.isfinite(observed):
                    raise AssertionError(f"{method}/{statistic}: non-finite result")
                error = abs(Decimal.from_float(observed) - oracle[statistic])
                if error > tolerance:
                    raise AssertionError(
                        f"{method}/{statistic}: absolute error {error} > {tolerance}"
                    )


if __name__ == "__main__":
    main()
