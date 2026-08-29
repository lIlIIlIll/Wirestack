#!/usr/bin/env python3
"""Regression checks for source-level Cangjie branch normalization."""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path


root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="yjson-cjcov-test.") as temporary:
    work = Path(temporary)
    source = work / "src"
    gcov = work / "gcov"
    source.mkdir()
    gcov.mkdir()
    (source / "lib_sample.cj").write_text(
        "package sample\n"
        "func sample(values: Array<Int64>, left: Bool, right: Bool): Unit {\n"
        "    for (value in values) { let _ = value }\n"
        "    if (left && right) { return }\n"
        "}\n",
        encoding="utf-8",
    )
    raw_branches = "".join(
        f"branch {index} {'taken 1' if index < 8 else 'never executed'}\n"
        for index in range(12)
    )
    boolean_branches = "".join(
        f"branch {index} {'taken 1' if index < 4 else 'never executed'}\n"
        for index in range(8)
    )
    (gcov / "sample.gcov").write_text(
        "        -:    0:Source:lib_sample.cj\n"
        "        1:    1:package sample\n"
        "        1:    2:func sample(values: Array<Int64>, left: Bool, right: Bool): Unit {\n"
        "        1:    3:    for (value in values) { let _ = value }\n"
        + raw_branches
        + "        1:    4:    if (left && right) { return }\n"
        + boolean_branches
        + "        1:    5:}\n",
        encoding="utf-8",
    )
    baseline = work / "baseline.toml"
    baseline.write_text(
        "project_line_percent = 0\nproject_branch_percent = 0\n",
        encoding="utf-8",
    )
    output = work / "lcov.info"
    subprocess.run(
        [
            "python3",
            str(root / "scripts/cjcov_to_lcov.py"),
            "--root",
            str(work),
            "--gcov-root",
            str(gcov),
            "--output",
            str(output),
            "--baseline",
            str(baseline),
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    records = [
        line
        for line in output.read_text(encoding="utf-8").splitlines()
        if line.startswith("BRDA:")
    ]
    assert len(records) == 6, records
    assert sum(not line.endswith(",-") for line in records) == 6, records

print("cjcov source branch normalization tests passed")
