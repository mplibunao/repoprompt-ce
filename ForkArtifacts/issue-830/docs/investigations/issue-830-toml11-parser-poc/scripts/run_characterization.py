#!/usr/bin/env python3
import hashlib
import json
import os
import re
import statistics
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ADVERSARIAL = ROOT / "Fixtures" / "adversarial"
DIALECT = ROOT / "Fixtures" / "dialect"
INPUT_BYTE_LIMIT = json.loads((ROOT / "evidence-policy.json").read_text())["inputByteLimit"]
REPEATS = 100
# Gate budgets from the accepted decision brief: release 2 s, debug 5 s.
TIMEOUTS = {"debug": 5.0, "release": 2.0}
# Applied only to re-measure a case that already missed its gate budget, so a budget miss can
# be distinguished from a genuine hang. It never converts a gate failure into a pass.
FOLLOW_UP_TIMEOUT = 120.0

SANITIZER_ERROR = re.compile(r"ERROR: (\w+): ([a-z\-]+)")
SANITIZER_FRAME = re.compile(r"^\s*#\d+ 0x[0-9a-f]+ in (.+?)(?: \S+:\d+)?$", re.MULTILINE)

# TOMLDecoder 0.4.5 reports positions only inside TOMLError.description. Captured here to
# quantify the diagnostic gap; it is never a pass criterion, because the accepted design
# forbids parsing parser text to recover categories or locations.
EMBEDDED_LINE = re.compile(r"^\(Line (\d+)\)")


def invoke(binary: Path, fixture: Path, timeout: float) -> dict:
    started = time.perf_counter_ns()
    try:
        completed = subprocess.run(
            [binary, fixture],
            text=True,
            capture_output=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return {
            "processOutcome": "timeout",
            "wallMilliseconds": (time.perf_counter_ns() - started) / 1_000_000,
        }
    wall_ms = (time.perf_counter_ns() - started) / 1_000_000
    record = None
    if completed.returncode == 0 and completed.stdout:
        try:
            record = json.loads(completed.stdout)
        except json.JSONDecodeError:
            pass
    return {
        "processOutcome": "exit" if completed.returncode >= 0 else "signal",
        "exitCode": completed.returncode,
        "wallMilliseconds": wall_ms,
        "record": record,
        "stderrPresent": bool(completed.stderr),
    }


def diagnostic_projection(result: dict) -> dict:
    record = result.get("record") or {}
    diagnostic = record.get("diagnostic") or {}
    return {
        "processOutcome": result.get("processOutcome"),
        "exitCode": result.get("exitCode"),
        "outcome": record.get("outcome"),
        "category": diagnostic.get("category"),
        "message": diagnostic.get("message"),
        "line": diagnostic.get("line"),
        "column": diagnostic.get("column"),
    }


def embedded_line(message: str | None) -> int | None:
    match = EMBEDDED_LINE.match(message or "")
    return int(match.group(1)) if match else None


def percentile_95(samples: list[float]) -> float:
    return sorted(samples)[28]


def peak_rss(binary: Path, fixture: Path, timeout: float) -> dict:
    try:
        completed = subprocess.run(
            ["/usr/bin/time", "-l", binary, fixture],
            text=True,
            capture_output=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return {"processOutcome": "timeout", "peakRSSBytes": None}
    match = re.search(r"(\d+)\s+maximum resident set size", completed.stderr)
    return {
        "processOutcome": "exit" if completed.returncode >= 0 else "signal",
        "exitCode": completed.returncode,
        "peakRSSBytes": int(match.group(1)) if match else None,
    }


def expected_outcome(name: str) -> str:
    if name in {"bytes-limit-plus-1.toml", "over-1mib.toml"}:
        return "input_too_large"
    if name.startswith("invalid-utf8-"):
        return "invalid_utf8"
    # near-1mib-duplicate.toml redefines a key, which both Codex runtimes and TOMLDecoder
    # reject, so it belongs with the malformed near-cap documents rather than the valid ones.
    if (
        name.startswith("near-1mib-invalid")
        or name == "near-1mib-unclosed-string.toml"
        or name == "near-1mib-duplicate.toml"
    ):
        return "syntax_error"
    if name in {
        "depth-129.toml",
        "depth-512.toml",
        "depth-max-under-byte-cap.toml",
        "array-10001.toml",
        "nodes-50001.toml",
        "string-262145.toml",
        "servers-257.toml",
        "servers-500.toml",
    }:
        return "resource_limit"
    return "accepted"


def expected_size(name: str) -> int | None:
    return {
        "bytes-limit-minus-1.toml": INPUT_BYTE_LIMIT - 1,
        "bytes-limit.toml": INPUT_BYTE_LIMIT,
        "bytes-limit-plus-1.toml": INPUT_BYTE_LIMIT + 1,
    }.get(name)


def record_pass(result: dict, expected: str) -> bool:
    record = result.get("record")
    return (
        result.get("processOutcome") == "exit"
        and result.get("exitCode") == 0
        and record is not None
        and record.get("outcome") == expected
    )


# The adversarial corpus is generated; verify it matches its manifest exactly before measuring,
# so a stale or hand-edited fixture cannot silently enter the resource evidence.
adversarial_manifest = json.loads((ADVERSARIAL / "manifest.json").read_text())
declared = {item["file"]: item for item in adversarial_manifest["fixtures"]}
present = {path.name for path in ADVERSARIAL.glob("*.toml")}
if set(declared) != present:
    raise SystemExit(
        f"adversarial corpus does not match its manifest; missing {sorted(set(declared) - present)}, "
        f"unexpected {sorted(present - set(declared))}"
    )
for name, item in declared.items():
    payload = (ADVERSARIAL / name).read_bytes()
    if len(payload) != item["bytes"] or hashlib.sha256(payload).hexdigest() != item["sha256"]:
        raise SystemExit(f"adversarial fixture {name} does not match its manifest digest")
    if expected_size(name) is not None and len(payload) != expected_size(name):
        raise SystemExit(f"adversarial fixture {name} does not match the documented input-size boundary")

asan_binary_value = os.environ.get("ISSUE830_ASAN_BINARY")
existing_results = ROOT / "results" / "characterization.json"
if not asan_binary_value and existing_results.exists():
    retained = json.loads(existing_results.read_text()).get("asan") or []
    if retained and os.environ.get("ISSUE830_ALLOW_PARTIAL_EVIDENCE") != "1":
        raise SystemExit(
            "refusing to overwrite retained sanitizer evidence without it. Re-run with "
            "ISSUE830_ASAN_BINARY set (scripts/run_all.sh --full-evidence), or set "
            "ISSUE830_ALLOW_PARTIAL_EVIDENCE=1 to deliberately drop it."
        )

dialect_result = json.loads((ROOT / "results" / "dialect.json").read_text())
syntax_case_ids = [
    row["id"]
    for row in dialect_result["rows"]
    if row["engines"]["tomldecoder-0.4.5"].get("outcome") == "syntax_error"
]
diagnostic_results = []
for configuration in ("debug", "release"):
    binary = ROOT / ".build" / configuration / "probe-tomldecoder"
    for case_id in syntax_case_ids:
        fixture = DIALECT / f"{case_id}.toml"
        if not fixture.exists():
            row = next(item for item in dialect_result["rows"] if item["id"] == case_id)
            fixture = DIALECT / row["file"]
        runs = [invoke(binary, fixture, TIMEOUTS[configuration]) for _ in range(REPEATS)]
        projections = [diagnostic_projection(run) for run in runs]
        # Stability alone is not evidence: a diagnostic that never decoded would be "stable" too.
        decoded = all(
            run.get("processOutcome") == "exit"
            and run.get("exitCode") == 0
            and (run.get("record") or {}).get("outcome") == "syntax_error"
            for run in runs
        )
        distinct = {}
        for projection in projections:
            key = json.dumps(projection, ensure_ascii=False, sort_keys=True)
            distinct[key] = distinct.get(key, 0) + 1
        diagnostic_results.append(
            {
                "id": case_id,
                "configuration": configuration,
                "repeats": REPEATS,
                "stable": len(distinct) == 1,
                "decodedAndClassified": decoded,
                "valid": decoded and len(distinct) == 1,
                "hasStructuredLine": projections[0]["line"] is not None,
                "hasStructuredColumn": projections[0]["column"] is not None,
                "messageEmbeddedLine": embedded_line(projections[0]["message"]),
                "distinctDiagnostics": [
                    {"projection": json.loads(key), "count": count}
                    for key, count in sorted(distinct.items())
                ],
            }
        )

def sanitizer_classification(stderr: str) -> dict | None:
    """Summarize an AddressSanitizer report.

    Only the sanitizer's own error class and symbol names are retained. Fixture bytes and
    parsed values are never stored, so this stays within the synthetic-evidence rule.
    """
    error = SANITIZER_ERROR.search(stderr)
    if not error:
        return None
    frames = SANITIZER_FRAME.findall(stderr)
    application = [frame for frame in frames if "libclang_rt" not in frame]
    counts: dict[str, int] = {}
    for frame in application:
        counts[frame] = counts.get(frame, 0) + 1
    dominant = max(counts.items(), key=lambda item: item[1]) if counts else None
    return {
        "sanitizer": error.group(1),
        "errorClass": error.group(2),
        "reportedFrames": len(frames),
        "dominantFrame": dominant[0] if dominant else None,
        "dominantFrameRepeats": dominant[1] if dominant else None,
    }


adversarial_names = sorted(path.name for path in ADVERSARIAL.glob("*.toml"))
adversarial_results = []
for configuration in ("debug", "release"):
    binary = ROOT / ".build" / configuration / "probe-tomldecoder"
    for name in adversarial_names:
        fixture = ADVERSARIAL / name
        expected = expected_outcome(name)
        run = invoke(binary, fixture, TIMEOUTS[configuration])
        rss = peak_rss(binary, fixture, TIMEOUTS[configuration])
        follow_up = None
        if run.get("processOutcome") == "timeout":
            retry = invoke(binary, fixture, FOLLOW_UP_TIMEOUT)
            follow_up = {
                "budgetSeconds": FOLLOW_UP_TIMEOUT,
                "processOutcome": retry.get("processOutcome"),
                "wallMilliseconds": retry.get("wallMilliseconds"),
                "outcome": (retry.get("record") or {}).get("outcome"),
                "classificationCorrect": (retry.get("record") or {}).get("outcome") == expected,
            }
        adversarial_results.append(
            {
                "fixture": name,
                "configuration": configuration,
                "bytes": fixture.stat().st_size,
                "expectedOutcome": expected,
                "pass": record_pass(run, expected),
                "run": run,
                "gateTimeoutSeconds": TIMEOUTS[configuration],
                "timeoutFollowUp": follow_up,
                "peakRSSBytes": rss.get("peakRSSBytes"),
                "rssProcessOutcome": rss.get("processOutcome"),
            }
        )

release_binary = ROOT / ".build" / "release" / "probe-tomldecoder"
performance_cases = [
    ("representative-64k.toml", 25.0),
    ("near-1mib-valid.toml", 500.0),
    ("near-1mib-invalid-eof.toml", 500.0),
    ("bytes-limit-plus-1.toml", 10.0),
]
performance_results = []
for name, gate_ms in performance_cases:
    fixture = ADVERSARIAL / name
    warmups = [invoke(release_binary, fixture, 2.0) for _ in range(5)]
    measured = [invoke(release_binary, fixture, 2.0) for _ in range(30)]
    samples = [item["wallMilliseconds"] for item in measured]
    outcomes = [(item.get("record") or {}).get("outcome") for item in measured]
    expected = expected_outcome(name)
    decoded = all(
        item.get("processOutcome") == "exit" and item.get("exitCode") == 0 and outcome == expected
        for item, outcome in zip(measured, outcomes)
    )
    performance_results.append(
        {
            "fixture": name,
            "bytes": fixture.stat().st_size,
            "warmups": 5,
            "iterations": 30,
            "p50Milliseconds": statistics.median(samples),
            "p95Milliseconds": percentile_95(samples),
            "maxMilliseconds": max(samples),
            "gateMilliseconds": gate_ms,
            "decodedAndClassified": decoded,
            "expectedOutcome": expected,
            # A latency number only counts when every sampled run actually produced the
            # expected decoded result; otherwise it would be timing a failure.
            "pass": decoded and percentile_95(samples) <= gate_ms,
            "outcome": outcomes[0],
        }
    )

release_baseline = peak_rss(release_binary, ADVERSARIAL / "servers-5.toml", 2.0).get("peakRSSBytes")
release_one_mib = peak_rss(release_binary, ADVERSARIAL / "near-1mib-valid.toml", 2.0).get("peakRSSBytes")
rss_delta = None
if release_baseline is not None and release_one_mib is not None:
    rss_delta = max(0, release_one_mib - release_baseline)

asan_results = []

if asan_binary_value:
    asan_binary = Path(asan_binary_value)
    for name in adversarial_names:
        fixture = ADVERSARIAL / name
        started = time.perf_counter_ns()
        try:
            completed = subprocess.run(
                [asan_binary, fixture], text=True, capture_output=True, timeout=FOLLOW_UP_TIMEOUT
            )
        except subprocess.TimeoutExpired:
            asan_results.append(
                {
                    "fixture": name,
                    "budgetSeconds": FOLLOW_UP_TIMEOUT,
                    "status": "timeout",
                    "processOutcome": "timeout",
                    "wallMilliseconds": (time.perf_counter_ns() - started) / 1_000_000,
                    "sanitizerFinding": None,
                    "pass": False,
                }
            )
            continue
        wall_ms = (time.perf_counter_ns() - started) / 1_000_000
        record_json = None
        if completed.returncode == 0 and completed.stdout:
            try:
                record_json = json.loads(completed.stdout)
            except json.JSONDecodeError:
                record_json = None
        classification = sanitizer_classification(completed.stderr)
        if completed.returncode == 0 and record_json is not None:
            status = "clean"
        elif classification is not None:
            status = "sanitizer_finding"
        else:
            # A nonzero exit the sanitizer did not explain is not evidence of anything.
            status = "unclassified_failure"
        asan_results.append(
            {
                "fixture": name,
                "budgetSeconds": FOLLOW_UP_TIMEOUT,
                "status": status,
                "processOutcome": "exit" if completed.returncode >= 0 else "signal",
                "exitCode": completed.returncode,
                "wallMilliseconds": wall_ms,
                "recordOutcome": (record_json or {}).get("outcome"),
                "stderrPresent": bool(completed.stderr),
                "sanitizerFinding": classification,
                "pass": status == "clean",
            }
        )

summary = {
    "diagnosticCases": len(diagnostic_results),
    "diagnosticStable": sum(item["stable"] for item in diagnostic_results),
    "diagnosticDecodedAndClassified": sum(item["decodedAndClassified"] for item in diagnostic_results),
    "diagnosticValid": sum(item["valid"] for item in diagnostic_results),
    "diagnosticStructuredLine": sum(item["hasStructuredLine"] for item in diagnostic_results),
    "diagnosticStructuredColumn": sum(item["hasStructuredColumn"] for item in diagnostic_results),
    "diagnosticMessageEmbeddedLine": sum(item["messageEmbeddedLine"] is not None for item in diagnostic_results),
    "adversarialCases": len(adversarial_results),
    "adversarialPass": sum(item["pass"] for item in adversarial_results),
    "adversarialCrashes": sum(item["run"].get("processOutcome") == "signal" for item in adversarial_results),
    "adversarialBudgetMisses": sum(item["timeoutFollowUp"] is not None for item in adversarial_results),
    "adversarialBudgetMissesCorrectlyClassified": sum(
        bool(item["timeoutFollowUp"] and item["timeoutFollowUp"]["classificationCorrect"])
        for item in adversarial_results
    ),
    "performanceCases": len(performance_results),
    "performancePass": sum(item["pass"] for item in performance_results),
    "asanRequested": bool(asan_binary_value),
    "asanCases": len(asan_results),
    "asanExpectedCases": len(adversarial_names),
    # Coverage means every fixture produced a clean run or a recognized sanitizer finding.
    # Timeouts and unexplained nonzero exits are not coverage.
    "asanCoverageComplete": len(asan_results) == len(adversarial_names)
    and all(item["status"] in ("clean", "sanitizer_finding") for item in asan_results),
    "asanStatusCounts": {
        status: sum(item["status"] == status for item in asan_results)
        for status in ("clean", "sanitizer_finding", "timeout", "unclassified_failure")
    },
    "asanPass": sum(item["pass"] for item in asan_results),
    "asanFindings": sum(item["sanitizerFinding"] is not None for item in asan_results),
    "releaseOneMiBPeakRSSBytes": release_one_mib,
    "releaseBaselinePeakRSSBytes": release_baseline,
    "releaseOneMiBEstimatedRSSDeltaBytes": rss_delta,
    "releaseOneMiBRSSDeltaPass": rss_delta is not None and rss_delta <= 67_108_864,
}
output = {
    "schema": 3,
    "candidate": "TOMLDecoder-0.4.5",
    "evidenceMode": "full" if asan_binary_value else "partial-no-sanitizer",
    "adversarialManifestVerified": True,
    "inputByteLimit": INPUT_BYTE_LIMIT,
    "protocol": {
        "diagnostics": "100 child-process repeats per syntax fixture in debug and release; compare category, message, line, and column",
        "adversarial": "one isolated child plus one /usr/bin/time -l child per generated fixture and build configuration",
        "performance": "five warmups followed by 30 release child-process wall-time samples",
        "rss": "absolute per-child high-water values; the reported delta is a rough differential estimate between two independent processes, not an in-process allocation measurement, and it bounds neither direction",
        "asan": "one AddressSanitizer child process per adversarial fixture when ISSUE830_ASAN_BINARY is supplied; findings are classified from the sanitizer report, and the budget is generous because the gate is the presence of a finding rather than instrumented latency",
        "timeoutFollowUp": "a case that misses its gate budget is re-measured once at a generous budget to separate a slow-but-correct run from a hang; the follow-up never changes the gate verdict",
    },
    "summary": summary,
    "diagnostics": diagnostic_results,
    "adversarial": adversarial_results,
    "performance": performance_results,
    "asan": asan_results,
    "rssMeasurements": {
        "baselinePeakRSSBytes": release_baseline,
        "oneMiBPeakRSSBytes": release_one_mib,
    },
}
(ROOT / "results" / "characterization.json").write_text(
    json.dumps(output, indent=2, ensure_ascii=False, sort_keys=True) + "\n"
)
print(json.dumps(summary, sort_keys=True))
