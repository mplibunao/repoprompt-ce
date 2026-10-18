#!/usr/bin/env python3
"""Re-check the proof-of-concept artifacts and write results/verification.json.

Checks are mechanical so the published numbers, the retained raw results, the reproduction
path, and the Git boundary can be confirmed without trusting prose. Every quantitative claim
printed in the measured sections of report.md must be derivable from a raw artifact; an
unrecognized number there fails the run rather than passing silently.
"""
import ast
import hashlib
import json
import os
import re
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(os.environ.get("ISSUE830_POC_ROOT", Path(__file__).resolve().parents[1]))
REPO = Path(os.environ.get("ISSUE830_REPO_ROOT", ROOT.parents[2]))
RESULTS = ROOT / "results"
PLAN = REPO / "docs/plans/codex-user-mcp-bridge-2026-08-30.md"
# Paths this investigation is allowed to touch. The boundary is expressed as authorized paths
# rather than a pinned commit or an untracked-only working tree, so the checks stay valid after
# this evidence is committed normally.
AUTHORIZED_PREFIXES = (
    "docs/investigations/issue-830-toml11-parser-poc/",
    "docs/investigations/issue-830-codex-user-mcp-bridge-poc-2026-09-03.md",
    "docs/plans/codex-user-mcp-bridge-2026-08-30.md",
    "prompt-exports/",
)
# Product surfaces the proof of concept must never modify.
PRODUCT_PATHS = ("Package.swift", "Package.resolved", "Sources", "Tests", "Packages", "Scripts", "Makefile", ".github")
ARCHIVED_PLAN_SHA = "8a39462d2d030c8aa2f92d08ba631e601c15d3bccb24dcd0868ee5a04f1fc135"
RETIRED_CLAIMS = ("19/28", "28 corpus cases", "30-run", "30 repeated", "zero matching tests")
# Thresholds and limits that come from the accepted decision brief rather than from measurement.
POLICY_CONSTANTS = {
    "1,048,576", "1048576", "128", "50,000", "10,000", "262,144", "256",
    "25", "500", "10", "2", "5", "64", "0.149.0", "0.152.0", "0.4.5", "2.0.0", "0.6.0",
    "1", "3", "4", "6", "8", "12", "14", "37", "48", "100", "1.1", "1.0", "6.3.3", "26.6", "14.0", "26.6.2",
}
checks = []


def record(name, passed, detail):
    checks.append({"check": name, "result": "pass" if passed else "fail", "detail": str(detail)})


def sha256_bytes(payload):
    return hashlib.sha256(payload).hexdigest()


def sha256(path):
    return sha256_bytes(path.read_bytes())


def git(*args):
    return subprocess.check_output(["git", "-C", str(REPO), *args], text=True).strip()


dialect = json.loads((RESULTS / "dialect.json").read_text())
order = json.loads((RESULTS / "order-mutation.json").read_text())
char = json.loads((RESULTS / "characterization.json").read_text())
package = json.loads((RESULTS / "package-audit.json").read_text())
summary = json.loads((RESULTS / "summary.json").read_text())
report = (ROOT / "report.md").read_text()
readme = (ROOT / "README.md").read_text()
policy = json.loads((ROOT / "evidence-policy.json").read_text())
run_state = json.loads((RESULTS / "run-state.json").read_text())

record("evidence run completed", run_state == {"schema": 1, "status": "complete"}, run_state)

# ---------------------------------------------------------------- fixture inventories
dialect_manifest = json.loads((ROOT / "Fixtures/dialect/manifest.json").read_text())
order_manifest = json.loads((ROOT / "Fixtures/order/manifest.json").read_text())
adversarial_manifest = json.loads((ROOT / "Fixtures/adversarial/manifest.json").read_text())

for folder, expected in (("dialect", 48), ("order", 14), ("adversarial", 37)):
    actual = len(list((ROOT / "Fixtures" / folder).glob("*.toml")))
    record(f"fixture count {folder}", actual == expected, f"{actual} of {expected} expected")

for folder, manifest, key in (("dialect", dialect_manifest, "cases"), ("order", order_manifest, "cases")):
    referenced = {entry["file"] for entry in manifest[key]}
    files = {path.name for path in (ROOT / "Fixtures" / folder).glob("*.toml")}
    record(f"manifest covers {folder} fixtures", referenced == files, f"unmatched {sorted(referenced ^ files)}")

declared = {item["file"]: item for item in adversarial_manifest["fixtures"]}
present = {path.name for path in (ROOT / "Fixtures/adversarial").glob("*.toml")}
record("adversarial manifest lists exactly the present corpus", set(declared) == present,
       f"missing {sorted(set(declared) - present)}, unexpected {sorted(present - set(declared))}")
digest_mismatches = [
    name for name, item in declared.items()
    if (ROOT / "Fixtures/adversarial" / name).exists()
    and sha256((ROOT / "Fixtures/adversarial" / name)) != item["sha256"]
]
record("adversarial fixtures match manifest digests", not digest_mismatches, f"mismatched {digest_mismatches}")
record("characterization verified the adversarial manifest", char.get("adversarialManifestVerified") is True,
       f"adversarialManifestVerified={char.get('adversarialManifestVerified')}")
input_limit = policy["inputByteLimit"]
boundary_sizes = {
    "bytes-limit-minus-1.toml": input_limit - 1,
    "bytes-limit.toml": input_limit,
    "bytes-limit-plus-1.toml": input_limit + 1,
}
record(
    "generated fixtures use the documented input-size boundary",
    all((ROOT / "Fixtures/adversarial" / name).stat().st_size == size for name, size in boundary_sizes.items()),
    boundary_sizes,
)
record("characterization uses the documented input-size boundary", char.get("inputByteLimit") == input_limit,
       f"recorded {char.get('inputByteLimit')}, policy {input_limit}")
probe_support = (ROOT / "Sources/ProbeSupport/ProbeSupport.swift").read_text()
swift_limit = re.search(r"let inputBytes = ([\d_]+)", probe_support)
record(
    "Swift probe uses the documented input-size boundary",
    swift_limit is not None and int(swift_limit.group(1).replace("_", "")) == input_limit,
    swift_limit.group(1) if swift_limit else "missing",
)

# ---------------------------------------------------------------- raw result shapes
record("dialect schema 2", dialect["schema"] == 2, f"schema {dialect['schema']}")
record("dialect has 48 rows", len(dialect["rows"]) == 48, f"{len(dialect['rows'])} rows")
record("dialect rows carry 5 engines", {len(row["engines"]) for row in dialect["rows"]} == {5}, "5 engines per row")
record("dialect recorded oracle identity verification", dialect.get("oracleIdentityVerified") is True,
       f"oracleIdentityVerified={dialect.get('oracleIdentityVerified')}")
record("both oracle controls established validity",
       all(value["validityEstablished"] for value in dialect["controls"].values()),
       {name: value["validityEstablished"] for name, value in dialect["controls"].items()})
homes = [
    engine.get("temporaryHomeRemoved")
    for row in dialect["rows"] for name, engine in row["engines"].items() if name.startswith("codex-")
]
record("every temporary Codex home was removed", homes and all(homes), f"{sum(bool(x) for x in homes)}/{len(homes)} removed")
probe_schemas = {
    engine.get("schema") for row in dialect["rows"] for name, engine in row["engines"].items() if not name.startswith("codex-")
}
record("probe records are schema 3", probe_schemas == {3}, f"schemas {sorted(probe_schemas)}")
materializations = {
    engine.get("materialization")
    for row in dialect["rows"] for name, engine in row["engines"].items()
    if not name.startswith("codex-") and engine.get("accepted")
}
record("no negative control claims a full traversal",
       "full_recursive_traversal" not in {
           engine.get("materialization")
           for row in dialect["rows"] for name, engine in row["engines"].items()
           if name in ("swift-toml-2.0.0", "tomlkit-0.6.0") and engine.get("accepted")
       },
       f"observed {sorted(m for m in materializations if m)}")

record("order schema 3", order["schema"] == 3, f"schema {order['schema']}")
projections = sum(item["repeats"] for item in order["results"])
record("order projections total 2800", projections == 2800, f"{projections} projections")
record("order repeats are 100 per configuration", {item["repeats"] for item in order["results"]} == {100}, "100 repeats")
record("order projections deterministic", all(len(item["observedProjectionHashes"]) == 1 for item in order["results"]),
       "one distinct projection hash per configuration")
existing_section = [item for item in order["results"] if item.get("exercisesExistingOwnedSection")]
record("existing owned-section mutation is covered", len(existing_section) == 4,
       f"{len(existing_section)} configurations covering replacement and insertion")
record("existing owned-section mutations changed the document and are idempotent",
       all(item["mutationPass"] and item["representative"]["mutation"]["changed"]
           and item["representative"]["mutation"]["secondApplicationByteIdentical"] for item in existing_section),
       "all changed and byte-identical on reapplication")
record("byte-confinement negative checks reject every off-range edit",
       order["summary"].get("confinementNegativeChecksPass") is True
       and all(order["confinementNegativeChecks"].values()),
       order["confinementNegativeChecks"])

record("characterization schema 3", char["schema"] == 3, f"schema {char['schema']}")
record("diagnostic repeats are 100", {item["repeats"] for item in char["diagnostics"]} == {100}, "100 repeats")
record("adversarial covers 37 fixtures in 2 configurations", len(char["adversarial"]) == 74, f"{len(char['adversarial'])} cases")

# ---------------------------------------------------------------- sanitizer evidence
findings = summary["lanes"]["characterization"]["sanitizerFindings"]
record("sanitizer evidence mode is full when findings are published",
       not findings or char.get("evidenceMode") == "full", f"evidenceMode={char.get('evidenceMode')}, findings={len(findings)}")
record("sanitizer coverage matches the adversarial corpus",
       not findings or summary["lanes"]["characterization"]["sanitizerCoverageComplete"],
       summary["lanes"]["characterization"]["sanitizerCoverage"])
record("report mentions the sanitizer only with matching coverage",
       "AddressSanitizer" not in report or summary["lanes"]["characterization"]["sanitizerCoverageComplete"],
       f"coverage {summary['lanes']['characterization']['sanitizerCoverage']}")
record("reproduction documents the full-evidence mode",
       "--full-evidence" in (ROOT / "scripts/run_all.sh").read_text() and "--full-evidence" in readme,
       "run_all.sh and README both document it")

# ---------------------------------------------------------------- package lane
record("package-audit schema 2", package["schema"] == 2, f"schema {package['schema']}")
record("upstream test count recorded", package["upstreamTests"]["reportedExecutedTestCount"] is not None,
       f"{package['upstreamTests']['reportedExecutedTestCount']} tests in {package['upstreamTests'].get('reportedSuiteCount')} suites")
record("TOMLDecoder optional dependencies absent from resolved graph",
       package["resolvedGraph"]["tomlDecoderOptionalDependenciesAbsent"], package["resolvedGraph"]["identities"])
record("package audit cleared the documented optional-dependency switches",
       sorted(package["environmentSanitization"]["clearedSwitches"])
       == sorted(policy["optionalDependencyEnvironmentSwitches"])
       and not package["environmentSanitization"]["presentDuringRun"],
       package["environmentSanitization"])
record("environment-conditioned manifest keys detected",
       len(package["candidate"]["manifestConditionalEnvironmentKeys"]) == 4,
       package["candidate"]["manifestConditionalEnvironmentKeys"])

# ---------------------------------------------------------------- decision derivation
# The stored summary is not trusted. A fresh derivation is generated from the same raw artifacts
# into a temporary location and compared field by field, and the invariants that decide the
# verdict are recomputed here directly from the raw JSON.
with tempfile.TemporaryDirectory(prefix="issue-830-verify-") as scratch:
    fresh_path = Path(scratch) / "summary.json"
    environment = dict(os.environ, ISSUE830_SUMMARY_OUT=str(fresh_path))
    regenerated = subprocess.run(
        ["python3", str(ROOT / "scripts/build_summary.py")],
        cwd=ROOT, env=environment, capture_output=True, text=True,
    )
    record("summary regenerates from raw artifacts", regenerated.returncode == 0, regenerated.stderr.strip()[-200:] or "ok")
    fresh = json.loads(fresh_path.read_text()) if fresh_path.exists() else None


def first_difference(left, right, path="$"):
    if type(left) is not type(right):
        return f"{path}: type {type(left).__name__} vs {type(right).__name__}"
    if isinstance(left, dict):
        for key in sorted(set(left) | set(right)):
            if key not in left or key not in right:
                return f"{path}.{key}: present on only one side"
            found = first_difference(left[key], right[key], f"{path}.{key}")
            if found:
                return found
        return None
    if isinstance(left, list):
        if len(left) != len(right):
            return f"{path}: length {len(left)} vs {len(right)}"
        for index, (a, b) in enumerate(zip(left, right)):
            found = first_difference(a, b, f"{path}[{index}]")
            if found:
                return found
        return None
    return None if left == right else f"{path}: {left!r} vs {right!r}"


record("stored summary matches a fresh derivation", fresh is not None and first_difference(fresh, summary) is None,
       first_difference(fresh, summary) if fresh is not None else "no fresh summary produced")

# Invariants recomputed straight from raw JSON, independent of any stored gate result.
raw_mismatch_ids = sorted(
    row["id"] for row in dialect["rows"]
    if row["engines"]["codex-0.149.0"]["accepted"] != row["engines"]["tomldecoder-0.4.5"]["accepted"]
)
raw = {
    "dialect-parity": f"{48 - len(raw_mismatch_ids)}/48",
    "oracle-agreement": f"{sum(row['engines']['codex-0.149.0']['accepted'] == row['engines']['codex-0.152.0']['accepted'] for row in dialect['rows'])}/48",
    "order-projection": f"{sum(item['orderPass'] for item in order['results'])}/{len(order['results'])}",
    "mutation-transaction": f"{sum(item['mutationPass'] for item in order['results'])}/{len(order['results'])}",
    "order-determinism": f"{sum(item['stable'] for item in order['results'])}/{len(order['results'])}",
    "adversarial-classification": f"{sum(item['pass'] for item in char['adversarial'])}/{len(char['adversarial'])}",
    "structured-line": f"{sum(item['hasStructuredLine'] for item in char['diagnostics'])}/{len(char['diagnostics'])}",
    "diagnostic-determinism": f"{sum(item['valid'] for item in char['diagnostics'])}/{len(char['diagnostics'])}",
    "sanitizer-coverage": f"{len(char['asan'])}/{len(set(item['fixture'] for item in char['adversarial']))}",
}
published = {gate["id"]: str(gate["observed"]) for gate in summary["gates"]}
for identifier, expected in raw.items():
    record(f"gate {identifier} recomputed from raw", published.get(identifier) == expected,
           f"published {published.get(identifier)}, recomputed {expected}")

raw_crashes = sum(item["run"].get("processOutcome") == "signal" for item in char["adversarial"])
record("gate no-crash recomputed from raw", published.get("no-crash") == f"{raw_crashes} crashes", f"{raw_crashes} crashes in raw")
raw_findings = sum(item.get("sanitizerFinding") is not None for item in char["asan"])
record("gate no-sanitizer-finding recomputed from raw", published.get("no-sanitizer-finding") == f"{raw_findings} findings", f"{raw_findings} findings in raw")
record("sanitizer statuses are all clean or recognized findings",
       all(item["status"] in ("clean", "sanitizer_finding") for item in char["asan"]),
       {status: sum(item["status"] == status for item in char["asan"]) for status in {item["status"] for item in char["asan"]}})

recomputed_failures = sorted(gate["id"] for gate in summary["gates"] if gate["result"] == "fail" and gate["blocking"])
record("decision follows the stated rule",
       summary["decision"] == ("NO-GO" if recomputed_failures else "GO"),
       f"{summary['decision']} with {len(recomputed_failures)} blocking failures")
record("published blocking failures match the gate results",
       recomputed_failures == sorted(summary["blockingGateFailures"]), recomputed_failures)
record("no winner is recorded for a NO-GO", summary["winner"] is None or summary["decision"] == "GO", summary["winner"])
mismatch_ids = sorted(item["id"] for item in summary["lanes"]["dialect"]["candidateParityMismatches"])
record("summary mismatch IDs match raw rows", mismatch_ids == raw_mismatch_ids, mismatch_ids)
record("declaration authority is the manifest, not the candidate",
       "manifest" in summary["lanes"]["dialect"]["declarationAuthority"],
       summary["lanes"]["dialect"]["declarationAuthority"])
declared_cases = sum("expectedServers" in case for case in dialect_manifest["cases"])
full_cases = sum(case.get("fullProjectionDeclared", False) for case in dialect_manifest["cases"])
record("every MCP-bearing fixture carries declarations", declared_cases == 13, f"{declared_cases} declared")
record("env and header declarations preserved", full_cases == 6, f"{full_cases} exhaustive declarations")
record("mutation pass proves preservation",
       all(
           all(item["representative"]["mutation"].get(field) for field in
               ("diffConfinedToOwnedSpan", "unrelatedProjectionUnchanged", "commentsPreserved", "newlineStylePreserved"))
           for item in order["results"] if item["mutationPass"]
       ),
       "confinement, projection, comments, and newline style asserted on every passing mutation")

# ---------------------------------------------------------------- published claim checks
lanes = summary["lanes"]
claims = {
    "dialect parity": lanes["dialect"]["candidateAcceptRejectParity"],
    "oracle agreement": lanes["dialect"]["codexOracleAgreement"],
    "corpus expectation": lanes["dialect"]["corpusExpectationAgreement"],
    "name set agreement": lanes["dialect"]["acceptedMCPNameSetAgreement"],
    "oracle projected fields": lanes["dialect"]["oracleProjectedFieldAgreement"],
    "declared key/value": lanes["dialect"]["declaredKeyValueAgreement"],
    "declared env and headers": lanes["dialect"]["declaredEnvHeaderAgreement"],
    "order pass": lanes["order"]["orderPass"],
    "order determinism": lanes["order"]["deterministic"],
    "mutation pass": lanes["order"]["mutationPass"],
    "adversarial pass": lanes["characterization"]["adversarialPass"],
    "structured line": lanes["characterization"]["structuredLine"],
    "structured column": lanes["characterization"]["structuredColumn"],
    "free-form line": lanes["characterization"]["lineOnlyInFreeFormText"],
    "diagnostic determinism": lanes["characterization"]["diagnosticDeterministic"],
    "diagnostic decoded": lanes["characterization"]["diagnosticDecodedAndClassified"],
    "sanitizer coverage": lanes["characterization"]["sanitizerCoverage"],
}
for control, value in lanes["dialect"]["negativeControlParity"].items():
    claims[f"negative control {control}"] = value
for label, value in claims.items():
    record(f"report states {label}", value in report, f"expects {value}")

numeric_facts = {
    f"{projections:,}",
    str(lanes["order"]["totalProjections"]),
    f"{package['upstreamTests']['reportedExecutedTestCount']}",
    f"{package['upstreamTests']['reportedSuiteCount']}",
    f"{lanes['characterization']['oneMiBPeakRSSDeltaBytes']:,}",
    f"{package['footprint']['releaseExecutableBytes']:,}",
    f"{package['footprint']['strippedReleaseExecutableBytes']:,}",
    f"{package['footprint']['releaseObjectBytes']:,}",
    f"{package['footprint']['releaseObjectFileCount']}",
    f"{package['candidate']['checkoutBytesExcludingVCS']:,}",
    package["candidate"]["revision"],
}
for item in lanes["package"]["crossCandidateReleaseExecutableBytes"].values():
    numeric_facts.add(f"{item:,}")
for item in lanes["characterization"]["performance"]:
    numeric_facts.update({f"{item['bytes']:,}", f"{item['p50Milliseconds']:.2f}", f"{item['p95Milliseconds']:.2f}", f"{item['maxMilliseconds']:.2f}", f"{item['gateMilliseconds']:.0f}"})
for item in lanes["characterization"]["crashes"]:
    numeric_facts.add(f"{item['bytes']:,}")
for item in lanes["characterization"]["debugBudgetMisses"]:
    numeric_facts.add(f"{item['actualMilliseconds'] / 1000:.2f}")
numeric_facts.update(str(count) for count in lanes["characterization"]["sanitizerStatusCounts"].values())
for item in lanes["characterization"]["sanitizerFindings"]:
    numeric_facts.update({str(item["dominantFrameRepeats"]), str(item["reportedFrames"])})
for item in lanes["package"]["builds"]:
    numeric_facts.add(f"{item['seconds']:.2f}")
if lanes["characterization"]["releaseWideTableMillisecondsRange"]:
    low, high = lanes["characterization"]["releaseWideTableMillisecondsRange"]
    numeric_facts.update({f"{low / 1000:.2f}", f"{high / 1000:.2f}"})
for value in dialect["oracleProvenance"].values():
    numeric_facts.add(value["sha256"])
# The count of syntax-error documents, and every number that is part of a fixture name.
numeric_facts.add(str(len(char["diagnostics"]) // 2))
for manifest, key, field in (
    (dialect_manifest, "cases", "file"),
    (order_manifest, "cases", "file"),
    (adversarial_manifest, "fixtures", "file"),
):
    for entry in manifest[key]:
        numeric_facts.update(re.findall(r"\d+", entry[field]))

measured = report.split("# 1. Measured local results", 1)[-1].split("# 2. Primary-source facts", 1)[0]
allowed = POLICY_CONSTANTS | numeric_facts | set(claims.values())
allowed |= {token for value in allowed for token in re.findall(r"\d[\d,]*(?:\.\d+)?", str(value))}
unverified = sorted({
    token for token in re.findall(r"\b\d[\d,]*(?:\.\d+)?\b", measured)
    if token not in allowed
})
record("every number in the measured sections is derived from raw results", not unverified, f"unverified {unverified}")

# The dialect corpus has 48 documents, so any "/28" ratio inside its lane would be a retired
# claim from the superseded 28-case run. Elsewhere 28 is a legitimate configuration count.
dialect_lane = report.split("## Lane 1", 1)[-1].split("## Lane 2", 1)[0]
stale_ratios = sorted(set(re.findall(r"\b\d+/28\b", dialect_lane)))
record("dialect lane free of superseded 28-case ratios", not stale_ratios, f"found {stale_ratios}")

for name, text in (("report.md", report), ("README.md", readme)):
    found = [claim for claim in RETIRED_CLAIMS if claim in text]
    record(f"{name} free of superseded claims", not found, f"found {found}" if found else "none present")
    record(f"{name} states the decision", summary["decision"] in text, f"expects {summary['decision']}")

# ---------------------------------------------------------------- scripts
for script in sorted((ROOT / "scripts").glob("*.py")):
    try:
        ast.parse(script.read_text())
        record(f"AST parse {script.name}", True, "parsed")
    except SyntaxError as error:
        record(f"AST parse {script.name}", False, str(error))
shell = subprocess.run(["sh", "-n", str(ROOT / "scripts/run_all.sh")], capture_output=True, text=True)
record("sh -n run_all.sh", shell.returncode == 0, shell.stderr.strip() or "ok")
run_all = (ROOT / "scripts/run_all.sh").read_text()
missing = [script.name for script in sorted((ROOT / "scripts").glob("*.py")) if script.name not in run_all]
record("run_all.sh references every script", not missing, f"missing {missing}" if missing else "all referenced")

# ---------------------------------------------------------------- plan
record("plan present", PLAN.exists(), str(PLAN.relative_to(REPO)))
plan_text = PLAN.read_text()
record("plan parser section revised", sha256(PLAN) != ARCHIVED_PLAN_SHA, f"sha256 {sha256(PLAN)}")
plan_requirements = {
    "grammar authority is the bundled Codex binary": "Bundled Codex 0.149.0 is the acceptance oracle",
    "regression oracle named": "Codex 0.152.0 is the regression oracle",
    "conformance claims are insufficient": "not acceptance evidence",
    "TOML 1.1 escapes are mandatory fixtures": "`\\e` and `\\xHH` are mandatory valid fixtures",
    "parse success requires full materialization": "complete recursive materialization",
    "validation precedes extraction and mutation": "before any semantic extraction, conflict analysis, or raw mutation",
    "accepted transaction order preserved": "validate source → project ordered semantics → formatting-preserving raw mutation → validate output → atomic write",
    "mutator demoted from validity authority": "no longer the validity or semantic authority",
    "multiline-aware source index required": "multiline-aware source index",
    "ordered projection required without dictionary iteration": "Dictionary iteration and lexicographic fallback are both disqualifying",
    "typed failure instead of empty list": "never be projected as an empty server list",
    "structured diagnostics required": "structured 1-based line number",
    "error text must not drive control flow": "never parsed for control flow",
    "resource safety gate stated": "below the byte cap",
    "decision is NO-GO": "The bounded POC ran and returned **NO-GO**.",
    "no production dependency authorized": "No Swift TOML dependency is authorized",
    "stop condition opened": "stop condition applies",
    "native versus out-of-process next step": "owning a native parser and running an out-of-process helper",
    "approval gate before touching the root package": "prerequisites to changing `Package.swift`",
    "prohibitions retained": "Prohibited for every candidate",
    "candidate versions recorded": "`mattt/swift-toml` 2.0.0 and `TOMLKit` 0.6.0 are rejected as shipped",
}
for label, needle in plan_requirements.items():
    record(f"plan: {label}", needle in plan_text, "present" if needle in plan_text else f"missing: {needle}")
for limit in ("1_048_576", "128", "50_000", "10_000", "262_144", "256"):
    record(f"plan states limit {limit}", limit in plan_text, "present" if limit in plan_text else "missing")
record("plan does not select a production dependency",
       "add the exact passing TOMLDecoder release" not in plan_text and "No Swift TOML dependency is authorized" in plan_text,
       "no dependency selected")

# ---------------------------------------------------------------- Git boundary
changed = []
for line in git("status", "--porcelain", "--untracked-files=all").splitlines():
    if line.strip():
        changed.append(line[3:].strip().strip('"'))
unauthorized = sorted({path for path in changed if not any(path.startswith(prefix) for prefix in AUTHORIZED_PREFIXES)})
record("working-tree changes stay inside authorized paths", not unauthorized, f"unauthorized {unauthorized}" if unauthorized else f"{len(changed)} authorized paths")

product_worktree = git("diff", "--name-only", "HEAD", "--", *PRODUCT_PATHS)
product_index = git("diff", "--cached", "--name-only", "--", *PRODUCT_PATHS)
record("product sources unmodified in the working tree", product_worktree == "", product_worktree or "clean")
record("product sources unmodified in the index", product_index == "", product_index or "clean")
record("no product path is staged or untracked",
       not [path for path in changed if any(path == item or path.startswith(item + "/") for item in PRODUCT_PATHS)],
       "none")

artifacts = {
    str(path.relative_to(ROOT)): sha256(path)
    for path in sorted(list(RESULTS.glob("*.json")) + [ROOT / "report.md", ROOT / "README.md"])
    if path.name != "verification.json"
}
output = {
    "schema": 3,
    "checks": checks,
    "passed": sum(item["result"] == "pass" for item in checks),
    "total": len(checks),
    "artifactSHA256": artifacts,
}
destination = RESULTS / "verification.json"
payload = json.dumps(output, indent=2, ensure_ascii=False, sort_keys=True) + "\n"
with tempfile.NamedTemporaryFile("w", dir=RESULTS, prefix=".verification-", delete=False) as handle:
    handle.write(payload)
    temporary = Path(handle.name)
os.replace(temporary, destination)
print(json.dumps({"passed": output["passed"], "total": output["total"]}, sort_keys=True))
for item in checks:
    if item["result"] == "fail":
        print("FAIL:", item["check"], "-", item["detail"][:200])
if output["passed"] != output["total"]:
    raise SystemExit(1)
