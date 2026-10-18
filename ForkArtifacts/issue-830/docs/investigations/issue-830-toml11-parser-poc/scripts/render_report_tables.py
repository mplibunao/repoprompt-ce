#!/usr/bin/env python3
"""Render the volatile measured tables in report.md from results/summary.json.

Latency, memory, and build durations differ on every run. Hand-typing them guarantees the report
goes stale the moment a lane is re-run, so the blocks between the generated markers are rebuilt
from the raw-derived summary instead. Prose and interpretation stay hand-written.
"""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REPORT = ROOT / "report.md"
summary = json.loads((ROOT / "results" / "summary.json").read_text())
characterization = summary["lanes"]["characterization"]
package = summary["lanes"]["package"]


def performance_block() -> str:
    lines = [
        "| Fixture | Bytes | p50 | p95 | Max | Gate | Result |",
        "|---|---:|---:|---:|---:|---:|---|",
    ]
    for item in characterization["performance"]:
        lines.append(
            f"| `{item['fixture']}` | {item['bytes']:,} | {item['p50Milliseconds']:.2f} ms | "
            f"{item['p95Milliseconds']:.2f} ms | {item['maxMilliseconds']:.2f} ms | "
            f"p95 ≤ {item['gateMilliseconds']:.0f} ms | {'PASS' if item['pass'] else 'FAIL'} |"
        )
    return "\n".join(lines)


def budget_block() -> str:
    misses = characterization["debugBudgetMisses"]
    fixtures = ", ".join(f"`{item['fixture'].removesuffix('.toml')}`" for item in misses)
    seconds = ", ".join(f"{item['actualMilliseconds'] / 1000:.2f} s" for item in misses)
    gate = misses[0]["gateSeconds"] if misses else 0
    low, high = characterization["releaseWideTableMillisecondsRange"]
    return (
        f"**Debug latency budget, {len(misses)} cases.** {fixtures} exceeded the {gate:.0f}-second "
        f"debug budget. Re-measured once at a generous budget, all {len(misses)} completed "
        f"correctly at {seconds} and produced the expected classification, so this is a slow debug "
        f"configuration rather than a hang. The same fixtures complete in "
        f"{low / 1000:.2f} s to {high / 1000:.2f} s in release, well inside the 2-second release budget."
    )


def package_block() -> str:
    builds = {(item["configuration"], item["kind"]): item for item in package["builds"]}
    upstream = package["upstreamTests"]
    footprint = package["footprint"]
    rows = [
        ("Clean debug build", f"{builds[('debug', 'clean')]['outcome']}, {builds[('debug', 'clean')]['seconds']:.2f} s"),
        ("Incremental debug build", f"{builds[('debug', 'incremental')]['outcome']}, {builds[('debug', 'incremental')]['seconds']:.2f} s"),
        ("Clean release build", f"{builds[('release', 'clean')]['outcome']}, {builds[('release', 'clean')]['seconds']:.2f} s"),
        ("Incremental release build", f"{builds[('release', 'incremental')]['outcome']}, {builds[('release', 'incremental')]['seconds']:.2f} s"),
        ("Upstream package tests", f"{upstream['outcome']}, {upstream['tests']} tests in {upstream['suites']} suites"),
        ("Native source files in the production target", str(package["productionTargetNativeFileCount"])),
        ("Unsafe flags in the manifest", "none" if not package["unsafeFlagsPresent"] else "present"),
        ("Optional dependencies present in the resolved graph", "none" if package["optionalDependenciesAbsentFromResolvedGraph"] else "present"),
        ("Checkout size excluding version control", f"{package['checkoutBytesExcludingVCS']:,} B"),
        ("Release probe executable", f"{footprint['releaseExecutableBytes']:,} B"),
        ("Stripped release probe executable", f"{footprint['strippedReleaseExecutableBytes']:,} B"),
        ("Release object files", f"{footprint['releaseObjectBytes']:,} B across {footprint['releaseObjectFileCount']} files"),
    ]
    lines = ["| Property | Value |", "|---|---|"]
    lines.extend(f"| {name} | {value} |" for name, value in rows)
    return "\n".join(lines)


def memory_block() -> str:
    return (
        f"Peak resident memory for a 1 MiB document exceeded an independent small-fixture baseline "
        f"by {characterization['oneMiBPeakRSSDeltaBytes']:,} bytes against the 64 MiB gate. This is a "
        f"rough differential estimate between two separate processes rather than an in-process "
        f"allocation measurement, and it bounds the true figure in neither direction."
    )


def sizes_block() -> str:
    sizes = package["crossCandidateReleaseExecutableBytes"]
    return (
        f"Cross-candidate release probe sizes were {sizes['probe-tomldecoder']:,} B for TOMLDecoder, "
        f"{sizes['probe-swift-toml']:,} B for swift-toml, and {sizes['probe-tomlkit']:,} B for TOMLKit. "
        f"These are isolated probe executables, not RepoPrompt application deltas."
    )


def sanitizer_block() -> str:
    counts = characterization["sanitizerStatusCounts"]
    return (
        f"The sweep recorded {counts['clean']} clean and {counts['sanitizer_finding']} sanitizer "
        f"finding across {characterization['sanitizerCoverage']} fixtures, with {counts['timeout']} "
        f"timeouts and {counts['unclassified_failure']} unclassified failures."
    )


BLOCKS = {
    "performance": performance_block,
    "debug-budget": budget_block,
    "package": package_block,
    "memory": memory_block,
    "sizes": sizes_block,
    "sanitizer": sanitizer_block,
}

text = REPORT.read_text()
for name, build in BLOCKS.items():
    pattern = re.compile(
        rf"(<!-- generated:{re.escape(name)} -->\n).*?(\n<!-- /generated:{re.escape(name)} -->)",
        re.DOTALL,
    )
    if not pattern.search(text):
        raise SystemExit(f"report.md is missing the generated:{name} block")
    text = pattern.sub(lambda match: match.group(1) + build() + match.group(2), text)
REPORT.write_text(text)
print(json.dumps({"renderedBlocks": sorted(BLOCKS)}, sort_keys=True))
