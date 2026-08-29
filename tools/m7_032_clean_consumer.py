#!/usr/bin/env python3
"""Run the established Linux clean consumer against the M7-032 public API."""

from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path

import m7_027_linux_examples as examples


ROOT = Path(__file__).resolve().parents[1]
TASK_ID = "M7-032"
REPORT = ROOT / "docs/evidence/M7-032/linux_x86_64/clean-consumer.json"


def validate() -> dict[str, object]:
    # Reuse the accepted M7-027 consumer and runtime assertions, but seal the
    # result as M7-032 evidence so the historical task report is untouched.
    original_task = examples.TASK_ID
    original_report = examples.REPORT
    try:
        examples.TASK_ID = TASK_ID
        examples.REPORT = REPORT
        return examples.validate()
    finally:
        examples.TASK_ID = original_task
        examples.REPORT = original_report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    try:
        report = validate()
    except (examples.ExampleGateError, OSError, subprocess.TimeoutExpired) as error:
        code = error.code if isinstance(error, examples.ExampleGateError) else type(error).__name__
        payload = {
            "taskId": TASK_ID,
            "decision": "FAIL",
            "code": code,
            "error": examples.bounded_output(str(error), 4000),
        }
        print(json.dumps(payload, sort_keys=True))
        return 1
    print(json.dumps(report, sort_keys=True) if args.json
          else f"{TASK_ID} PASS: Linux clean consumer accepted")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
