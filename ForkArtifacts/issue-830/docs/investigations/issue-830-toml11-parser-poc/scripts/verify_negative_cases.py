#!/usr/bin/env python3
"""Focused tamper checks for retained evidence and run completion."""
import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parents[2]


def copy_package(destination: Path) -> None:
    shutil.copytree(ROOT, destination, ignore=shutil.ignore_patterns(".build"))


def expect_rejection(name: str, mutate, command: str, expected_message: str) -> None:
    with tempfile.TemporaryDirectory(prefix="issue-830-negative-") as directory:
        copy = Path(directory) / "poc"
        copy_package(copy)
        mutate(copy)
        environment = dict(
            os.environ,
            ISSUE830_POC_ROOT=str(copy),
            ISSUE830_REPO_ROOT=str(REPO),
            ISSUE830_SUMMARY_OUT=str(copy / "results" / "fresh-summary.json"),
        )
        completed = subprocess.run(
            ["python3", str(copy / "scripts" / command)],
            cwd=copy,
            env=environment,
            capture_output=True,
            text=True,
        )
        if completed.returncode == 0:
            raise SystemExit(f"negative check {name} was accepted")
        combined = completed.stdout + completed.stderr
        if expected_message not in combined:
            raise SystemExit(f"negative check {name} failed for the wrong reason")
        print(json.dumps({"negativeCheck": name, "result": "rejected"}, sort_keys=True))


def change_order_summary(copy: Path) -> None:
    path = copy / "results" / "order-mutation.json"
    value = json.loads(path.read_text())
    value["summary"]["mutationPass"] += 1
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def change_characterization_summary(copy: Path) -> None:
    path = copy / "results" / "characterization.json"
    value = json.loads(path.read_text())
    value["summary"]["adversarialCrashes"] = 0
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def mark_interrupted(copy: Path) -> None:
    path = copy / "results" / "run-state.json"
    path.write_text(json.dumps({"schema": 1, "status": "interrupted"}, indent=2, sort_keys=True) + "\n")


expect_rejection("order stored summary", change_order_summary, "build_summary.py", "order stored summary")
expect_rejection(
    "characterization stored summary",
    change_characterization_summary,
    "build_summary.py",
    "characterization stored summary",
)
expect_rejection("interrupted evidence run", mark_interrupted, "verify_artifacts.py", "evidence run completed")
