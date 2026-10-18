#!/usr/bin/env python3
import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CHECKOUT = ROOT / ".build" / "checkouts" / "TOMLDecoder"


# TOMLDecoder's manifest adds benchmark, DocC, and formatting dependencies when these are set.
# An official build must not inherit them, so every resolve, build, and test here runs with all
# four explicitly removed rather than merely assumed absent.
POLICY = json.loads((ROOT / "evidence-policy.json").read_text())
OPTIONAL_DEPENDENCY_SWITCHES = tuple(POLICY["optionalDependencyEnvironmentSwitches"])
INHERITED_SWITCHES = sorted(key for key in OPTIONAL_DEPENDENCY_SWITCHES if key in os.environ)
SANITIZED_ENVIRONMENT = {key: value for key, value in os.environ.items() if key not in OPTIONAL_DEPENDENCY_SWITCHES}


def run(command: list[str], timeout: float = 600.0) -> dict:
    started = time.perf_counter_ns()
    try:
        completed = subprocess.run(command, text=True, capture_output=True, timeout=timeout, env=SANITIZED_ENVIRONMENT)
    except subprocess.TimeoutExpired as error:
        return {
            "command": command,
            "outcome": "timeout",
            "durationSeconds": (time.perf_counter_ns() - started) / 1_000_000_000,
            "stdoutTail": (error.stdout or "")[-2000:],
            "stderrTail": (error.stderr or "")[-2000:],
        }
    return {
        "command": command,
        "outcome": "pass" if completed.returncode == 0 else "fail",
        "exitCode": completed.returncode,
        "durationSeconds": (time.perf_counter_ns() - started) / 1_000_000_000,
        "stdoutTail": completed.stdout[-2000:],
        "stderrTail": completed.stderr[-2000:],
    }


def directory_bytes(path: Path, skip_vcs: bool = False) -> int:
    return sum(
        item.stat().st_size
        for item in path.rglob("*")
        if item.is_file() and not (skip_vcs and ".git" in item.relative_to(path).parts)
    )


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def git(*arguments: str) -> str:
    return subprocess.check_output(["git", "-C", CHECKOUT, *arguments], text=True).strip()


with tempfile.TemporaryDirectory(prefix="issue-830-build-audit-") as scratch:
    scratch_path = Path(scratch)
    build_runs = []
    for configuration in ("debug", "release"):
        command = [
            "swift",
            "build",
            "--package-path",
            str(ROOT),
            "--scratch-path",
            str(scratch_path / configuration),
            "--product",
            "probe-tomldecoder",
        ]
        if configuration == "release":
            command.extend(["-c", "release"])
        build_runs.append({"configuration": configuration, "kind": "clean", **run(command)})
        build_runs.append({"configuration": configuration, "kind": "incremental", **run(command)})

with tempfile.TemporaryDirectory(prefix="issue-830-upstream-tests-") as scratch:
    upstream_test = run(
        [
            "swift",
            "test",
            "--package-path",
            str(CHECKOUT),
            "--scratch-path",
            scratch,
        ],
        timeout=900.0,
    )

# The upstream suite reports through swift-testing; older XCTest phrasing is still accepted
# so the count survives a toolchain or upstream harness change.
combined = upstream_test.get("stdoutTail", "") + upstream_test.get("stderrTail", "")
executed_counts = [int(value) for value in re.findall(r"Executed (\d+) tests?", combined)]
executed_counts += [int(value) for value in re.findall(r"Test run with (\d+) tests?", combined)]
suite_counts = [int(value) for value in re.findall(r"in (\d+) suites?", combined)]
upstream_test["reportedExecutedTestCount"] = max(executed_counts) if executed_counts else None
upstream_test["reportedSuiteCount"] = max(suite_counts) if suite_counts else None

show_dependencies = run(
    ["swift", "package", "show-dependencies", "--package-path", str(ROOT), "--format", "json"]
)
dependency_graph = None
if show_dependencies.get("outcome") == "pass":
    try:
        dependency_graph = json.loads(show_dependencies["stdoutTail"])
    except json.JSONDecodeError:
        full = subprocess.check_output(
            ["swift", "package", "show-dependencies", "--package-path", ROOT, "--format", "json"],
            text=True,
            env=SANITIZED_ENVIRONMENT,
        )
        dependency_graph = json.loads(full)

manifest_text = (CHECKOUT / "Package.swift").read_text()


def manifest_environment_keys(text: str) -> list[str]:
    """Collect environment keys that gate optional dependencies.

    The manifest reads the environment through a local alias rather than at each use site,
    so resolving that alias is required to see the benchmark, DocC, and formatting switches.
    """
    keys = set(re.findall(r'ProcessInfo\.processInfo\.environment\["([^"]+)"\]', text))
    alias = re.search(r"let\s+(\w+)\s*=\s*ProcessInfo\.processInfo\.environment\b", text)
    if alias:
        keys |= set(re.findall(rf'\b{re.escape(alias.group(1))}\["([^"]+)"\]', text))
    return sorted(keys)
license_files = sorted(CHECKOUT.glob("LICENSE*"))
source_root = CHECKOUT / "Sources" / "TOMLDecoder"
native_suffixes = {".c", ".cc", ".cpp", ".cxx", ".h", ".hh", ".hpp", ".hxx", ".m", ".mm"}
native_files = sorted(
    str(path.relative_to(CHECKOUT))
    for path in source_root.rglob("*")
    if path.is_file() and path.suffix.lower() in native_suffixes
)

release_binary = ROOT / ".build" / "release" / "probe-tomldecoder"
stripped_bytes = None
with tempfile.TemporaryDirectory(prefix="issue-830-strip-") as directory:
    stripped = Path(directory) / "probe-tomldecoder"
    shutil.copy2(release_binary, stripped)
    strip_result = run(["strip", "-x", str(stripped)])
    if strip_result.get("outcome") == "pass":
        stripped_bytes = stripped.stat().st_size

object_files = list((ROOT / ".build").glob("**/release/TOMLDecoder.build/*.o"))
resolved = json.loads((ROOT / "Package.resolved").read_text())
resolved_identities = [pin["identity"] for pin in resolved["pins"]]
optional_identities = {"benchmark", "swiftformat", "swift-docc-plugin"}

output = {
    "schema": 2,
    "candidate": {
        "name": "TOMLDecoder",
        "tag": git("describe", "--tags", "--exact-match"),
        "revision": git("rev-parse", "HEAD"),
        "checkoutBytes": directory_bytes(CHECKOUT),
        "checkoutBytesExcludingVCS": directory_bytes(CHECKOUT, skip_vcs=True),
        "licenseFiles": [
            {"name": path.name, "sha256": sha256(path)} for path in license_files
        ],
        "productionTargetNativeFiles": native_files,
        "productionTargetNativeFileCount": len(native_files),
        "unsafeFlagsPresent": "unsafeFlags" in manifest_text,
        "pluginDeclarations": len(re.findall(r"\.plugin\s*\(", manifest_text)),
        "macroDeclarations": len(re.findall(r"\.macro\s*\(", manifest_text)),
        "binaryArtifactDeclarations": len(re.findall(r"\.binaryTarget\s*\(", manifest_text)),
        "manifestConditionalEnvironmentKeys": manifest_environment_keys(manifest_text),
    },
    "toolchain": {
        "swift": subprocess.check_output(["swift", "--version"], text=True).splitlines()[0],
        "xcode": subprocess.check_output(["xcodebuild", "-version"], text=True).splitlines(),
        "macOS": subprocess.check_output(["sw_vers", "-productVersion"], text=True).strip(),
        "architecture": subprocess.check_output(["uname", "-m"], text=True).strip(),
    },
    "environmentSanitization": {
        "clearedSwitches": list(OPTIONAL_DEPENDENCY_SWITCHES),
        "inheritedBeforeClearing": INHERITED_SWITCHES,
        "presentDuringRun": sorted(key for key in OPTIONAL_DEPENDENCY_SWITCHES if key in SANITIZED_ENVIRONMENT),
    },
    "resolvedGraph": {
        "identities": resolved_identities,
        "tomlDecoderOptionalDependenciesAbsent": not bool(optional_identities.intersection(resolved_identities)),
        "showDependencies": dependency_graph,
    },
    "builds": build_runs,
    "upstreamTests": upstream_test,
    "footprint": {
        "releaseExecutableBytes": release_binary.stat().st_size,
        "strippedReleaseExecutableBytes": stripped_bytes,
        "releaseObjectBytes": sum(path.stat().st_size for path in object_files),
        "releaseObjectFileCount": len(object_files),
        "rootApplicationDeltaMeasured": False,
        "rootApplicationDeltaReason": "The POC is isolated and production dependency integration is not authorized.",
    },
}
(ROOT / "results" / "package-audit.json").write_text(
    json.dumps(output, indent=2, ensure_ascii=False, sort_keys=True) + "\n"
)
print(
    json.dumps(
        {
            "buildsPassed": sum(item["outcome"] == "pass" for item in build_runs),
            "buildRuns": len(build_runs),
            "upstreamTests": upstream_test["outcome"],
            "reportedExecutedTestCount": upstream_test["reportedExecutedTestCount"],
            "optionalDependenciesAbsent": output["resolvedGraph"]["tomlDecoderOptionalDependenciesAbsent"],
        },
        sort_keys=True,
    )
)
