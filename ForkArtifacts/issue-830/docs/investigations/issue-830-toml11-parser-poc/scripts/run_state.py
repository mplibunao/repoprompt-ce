#!/usr/bin/env python3
"""Atomically distinguish a complete evidence run from an interrupted one."""
import json
import os
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DESTINATION = ROOT / "results" / "run-state.json"
VALID_STATES = {"running", "complete", "interrupted"}


def write_atomic(payload: dict) -> None:
    DESTINATION.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".run-state-", dir=DESTINATION.parent)
    try:
        with os.fdopen(descriptor, "w") as handle:
            json.dump(payload, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, DESTINATION)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


if len(sys.argv) != 2 or sys.argv[1] not in VALID_STATES:
    raise SystemExit("usage: run_state.py running|complete|interrupted")

write_atomic({"schema": 1, "status": sys.argv[1]})
print(json.dumps({"status": sys.argv[1]}, sort_keys=True))
