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
        "    for (value in values) {\n"
        "        let _ = value\n"
        "    }\n"
        "    for (value in values) {\n"
        "        let _ = value\n"
        "    }\n"
        "    for (value in values) {\n"
        "        break\n"
        "    }\n"
        "    for (value in values) {\n"
        "    }\n"
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
    completed_loop_branches = "".join(
        f"branch {index} taken {count}\n"
        for index, count in enumerate((1, 0, 0, 1, 0, 3, 2, 1, 0, 2))
    )
    broken_loop_branches = "".join(
        f"branch {index} taken {count}\n"
        for index, count in enumerate((1, 0, 0, 1, 0, 1, 1, 0, 0, 1))
    )
    skipped_loop_branches = "".join(
        f"branch {index} taken {count}\n"
        for index, count in enumerate((1, 0, 0, 1, 0, 1, 0, 1, 0, 0))
    )
    (gcov / "sample.gcov").write_text(
        "        -:    0:Source:lib_sample.cj\n"
        "        1:    1:package sample\n"
        "        1:    2:func sample(values: Array<Int64>, left: Bool, right: Bool): Unit {\n"
        "        3:    3:    for (value in values) {\n"
        + completed_loop_branches
        + "        2:    4:        let _ = value\n"
        + "        1:    5:    }\n"
        + "        1:    6:    for (value in values) {\n"
        + skipped_loop_branches
        + "    #####:    7:        let _ = value\n"
        + "        1:    8:    }\n"
        + "        1:    9:    for (value in values) {\n"
        + broken_loop_branches
        + "        1:   10:        break\n"
        + "        1:   11:    }\n"
        + "        1:   12:    for (value in values) {\n"
        + raw_branches
        + "        1:   13:    }\n"
        + "        1:   14:    if (left && right) { return }\n"
        + boolean_branches
        + "        1:   15:}\n",
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
    assert len(records) == 12, records
    assert sum(not line.endswith(",-") for line in records) == 8, records

print("cjcov source branch normalization tests passed")
