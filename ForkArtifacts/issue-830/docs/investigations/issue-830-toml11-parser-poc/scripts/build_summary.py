#!/usr/bin/env python3
"""Derive results/summary.json from the raw lane artifacts.

The decision is not written by hand. Measurements are computed from the raw outputs, an
explicit gate policy is evaluated against them, and the verdict falls out of that evaluation:
any failing blocking gate produces NO-GO.

Two comparisons need stated definitions because the Codex oracle is not a peer of a TOML parser:

* `codex mcp list --json` emits servers sorted by name, so it confirms which servers and values
  a document yields but never declaration order. Order is asserted in the order lane instead.
* Codex reports only name, command, url, enabled, and args, and fills schema defaults the source
  never states. Oracle comparison is therefore restricted to fields the source actually
  specifies, and `env` / `http_headers` are checked against declared fixture expectations
  because the oracle never reports them at all.
"""
import json
import os
from pathlib import Path

ROOT = Path(os.environ.get("ISSUE830_POC_ROOT", Path(__file__).resolve().parents[1]))
RESULTS = ROOT / "results"
POLICY = json.loads((ROOT / "evidence-policy.json").read_text())
CANDIDATE = "tomldecoder-0.4.5"
BUNDLED = "codex-0.149.0"
REGRESSION = "codex-0.152.0"
CONTROLS = ("swift-toml-2.0.0", "tomlkit-0.6.0")

# TOML key under a server table -> field name in the probe projection.
KEY_TO_FIELD = {
    "command": "command",
    "url": "url",
    "enabled": "enabled",
    "args": "arguments",
    "env": "env",
    "http_headers": "httpHeaders",
}
# Fields `codex mcp list --json` actually reports.
ORACLE_FIELDS = {"command", "url", "enabled", "arguments"}
SUPPORTED_FIELDS = ("command", "url", "enabled", "arguments", "env", "httpHeaders")
FULL_PROJECTION_FIELDS = ("name", "command", "url", "enabled", "arguments", "env", "httpHeaders")


def load(name):
    return json.loads((RESULTS / name).read_text())


def require_equal(label, retained, recomputed):
    if retained != recomputed:
        raise SystemExit(f"{label} disagrees with recomputed source records")


def dialect_section(data, manifest):
    rows = data["rows"]
    declared_by_id = {case["id"]: case for case in manifest["cases"] if "expectedServers" in case}
    oracle_agree = expectation_agree = parity = 0
    parity_misses = []
    name_cases = name_agree = 0
    oracle_field_cases = oracle_field_agree = 0
    declared_cases = declared_agree = 0
    full_cases = full_agree = 0
    oracle_field_failures, declared_failures, full_failures = [], [], []
    multi_server = sorted_server = 0
    control_parity = {control: 0 for control in CONTROLS}

    for row in rows:
        bundled, regression = row["engines"][BUNDLED], row["engines"][REGRESSION]
        candidate = row["engines"][CANDIDATE]
        oracle_agree += bundled["accepted"] == regression["accepted"]
        expectation_agree += bundled["accepted"] == row["expectedAccept"]
        if bundled["accepted"] == candidate["accepted"]:
            parity += 1
        else:
            parity_misses.append({"id": row["id"], "codex": bundled["accepted"], "candidate": candidate["accepted"]})
        for control in CONTROLS:
            control_parity[control] += bundled["accepted"] == row["engines"][control]["accepted"]

        oracle_servers = bundled.get("selectedMCPServers") or []
        if len(oracle_servers) > 1:
            multi_server += 1
            names = [server["name"] for server in oracle_servers]
            sorted_server += names == sorted(names)

        case = declared_by_id.get(row["id"])
        if case is None or not bundled["accepted"]:
            continue
        candidate_servers = candidate.get("selectedMCPServers") or []
        declared_servers = case["expectedServers"]
        by_name = {server["name"]: server for server in oracle_servers}
        candidate_by_name = {server["name"]: server for server in candidate_servers}

        # Declared keys and values. The manifest is the authority for which keys exist and what
        # they hold; the candidate's own key list is a value under test, never the yardstick.
        declared_cases += 1
        problems = []
        if [server["name"] for server in candidate_servers] != [server["name"] for server in declared_servers]:
            problems.append({"reason": "server names or order differ",
                             "expected": [server["name"] for server in declared_servers],
                             "observed": [server["name"] for server in candidate_servers]})
        else:
            for declaration in declared_servers:
                observed = candidate_by_name[declaration["name"]]
                expected_keys = sorted(declaration["declaredKeys"])
                if sorted(observed.get("specifiedKeys") or []) != expected_keys:
                    problems.append({"server": declaration["name"], "reason": "reported keys differ",
                                     "expected": expected_keys, "observed": sorted(observed.get("specifiedKeys") or [])})
                for key in declaration["declaredKeys"]:
                    field = KEY_TO_FIELD.get(key)
                    if field is None:
                        continue
                    if observed.get(field) is None:
                        problems.append({"server": declaration["name"], "field": field, "reason": "omitted by candidate"})
                    elif observed.get(field) != declaration.get(field):
                        problems.append({"server": declaration["name"], "field": field,
                                         "expected": declaration.get(field), "observed": observed.get(field)})
                for field in SUPPORTED_FIELDS:
                    if observed.get(field) is not None and field not in {KEY_TO_FIELD.get(key) for key in declaration["declaredKeys"]}:
                        problems.append({"server": declaration["name"], "field": field, "reason": "reported but not declared"})
        if problems:
            declared_failures.append({"id": row["id"], "problems": problems})
        else:
            declared_agree += 1

        # The exhaustive subset additionally pins env and http_headers, which the oracle never
        # reports, so this is the only check that can see them.
        if case.get("fullProjectionDeclared"):
            full_cases += 1
            projected = [{field: server.get(field) for field in FULL_PROJECTION_FIELDS} for server in candidate_servers]
            expected = [{field: server.get(field) for field in FULL_PROJECTION_FIELDS} for server in declared_servers]
            if projected == expected:
                full_agree += 1
            else:
                full_failures.append({"id": row["id"], "expected": expected, "observed": projected})

        if not (candidate["accepted"] and oracle_servers):
            continue
        name_cases += 1
        oracle_field_cases += 1
        if set(by_name) != set(candidate_by_name):
            oracle_field_failures.append({"id": row["id"], "reason": "server name set differs"})
            continue
        name_agree += 1
        oracle_problems = []
        for declaration in declared_servers:
            observed = candidate_by_name.get(declaration["name"], {})
            for key in declaration["declaredKeys"]:
                field = KEY_TO_FIELD.get(key)
                if field is None or field not in ORACLE_FIELDS:
                    continue
                if observed.get(field) is None:
                    oracle_problems.append({"server": declaration["name"], "field": field, "reason": "omitted by candidate"})
                elif observed.get(field) != by_name[declaration["name"]].get(field):
                    oracle_problems.append({"server": declaration["name"], "field": field,
                                            "expected": by_name[declaration["name"]].get(field),
                                            "observed": observed.get(field)})
        if oracle_problems:
            oracle_field_failures.append({"id": row["id"], "problems": oracle_problems})
        else:
            oracle_field_agree += 1

    return {
        "documents": len(rows),
        "codexOracleAgreement": f"{oracle_agree}/{len(rows)}",
        "corpusExpectationAgreement": f"{expectation_agree}/{len(rows)}",
        "candidateAcceptRejectParity": f"{parity}/{len(rows)}",
        "candidateParityMismatches": parity_misses,
        "acceptedMCPNameSetAgreement": f"{name_agree}/{name_cases}",
        "oracleProjectedFieldAgreement": f"{oracle_field_agree}/{oracle_field_cases}",
        "oracleProjectedFields": sorted(ORACLE_FIELDS),
        "oracleProjectedFieldFailures": oracle_field_failures,
        "declaredKeyValueAgreement": f"{declared_agree}/{declared_cases}",
        "declaredKeyValueFailures": declared_failures,
        "declaredEnvHeaderAgreement": f"{full_agree}/{full_cases}",
        "declaredEnvHeaderFailures": full_failures,
        "declarationAuthority": "fixture manifest; candidate-reported keys are compared against it, never used as the yardstick",
        "oracleEmitsSortedServerNames": f"{sorted_server}/{multi_server}",
        "oracleUsableAsOrderAuthority": False,
        "oracleReportsEnvOrHeaders": False,
        "negativeControlParity": {control: f"{count}/{len(rows)}" for control, count in control_parity.items()},
        "negativeControlMaterialization": {
            control: sorted({row["engines"][control].get("materialization") for row in rows if row["engines"][control].get("accepted")})
            for control in CONTROLS
        },
        "candidateMaterialization": sorted({row["engines"][CANDIDATE].get("materialization") for row in rows if row["engines"][CANDIDATE].get("accepted")}),
    }


def order_section(data):
    results, controls = data["results"], data["controls"]
    recomputed_rows = []
    for item in results:
        representative = item["representative"]
        mutation = representative["mutation"]
        observed_orders = item["observedSourceOrders"]
        projection_hashes = item["observedProjectionHashes"]
        repeats = item["repeats"]
        stable = len(projection_hashes) == 1 and sum(entry["count"] for entry in projection_hashes) == repeats
        order_pass = (
            len(observed_orders) == 1
            and observed_orders[0]["count"] == repeats
            and observed_orders[0]["order"] == item["expectedOrder"]
        )
        mutation_pass = (
            stable
            and representative.get("candidateOutput", {}).get("accepted") is True
            and representative["source"].get("evidenceValidated") is True
            and representative.get("candidateOutput", {}).get("evidenceValidated") is True
            and all(mutation.get(field) is True for field in (
                "secondApplicationByteIdentical", "diffConfinedToOwnedSpan",
                "outsideOwnedBytesIdentical", "bomPreserved", "unrelatedProjectionUnchanged",
                "commentsPreserved", "newlineStylePreserved",
            ))
        )
        require_equal(f"order row {item['id']} stable", item["stable"], stable)
        require_equal(f"order row {item['id']} orderPass", item["orderPass"], order_pass)
        require_equal(f"order row {item['id']} mutationPass", item["mutationPass"], mutation_pass)
        recomputed_rows.append({"stable": stable, "orderPass": order_pass, "mutationPass": mutation_pass})

    recomputed_summary = {
        "fixtureConfigurations": len(results),
        "stable": sum(item["stable"] for item in recomputed_rows),
        "orderPass": sum(item["orderPass"] for item in recomputed_rows),
        "mutationPass": sum(item["mutationPass"] for item in recomputed_rows),
        "noWriteControlsPass": all(
            not value["mutation"]["wrote"] and not value["mutation"]["changed"]
            for value in controls.values()
        ),
        "confinementNegativeChecksPass": all(data["confinementNegativeChecks"].values()),
    }
    require_equal("order stored summary", data["summary"], recomputed_summary)
    failures = [
        {"id": item["id"], "configuration": item["configuration"], "order": derived["orderPass"], "mutation": derived["mutationPass"]}
        for item, derived in zip(results, recomputed_rows)
        if not (derived["orderPass"] and derived["mutationPass"])
    ]
    mutating = [derived for item, derived in zip(results, recomputed_rows) if item.get("exercisesExistingOwnedSection")]
    return {
        "fixtureConfigurations": len(results),
        "totalProjections": sum(item["repeats"] for item in results),
        "repeatsPerConfiguration": sorted({item["repeats"] for item in results}),
        "orderPass": f"{recomputed_summary['orderPass']}/{len(results)}",
        "mutationPass": f"{recomputed_summary['mutationPass']}/{len(results)}",
        "deterministic": f"{recomputed_summary['stable']}/{len(results)}",
        "existingOwnedSectionConfigurations": len(mutating),
        "existingOwnedSectionPass": sum(item["mutationPass"] for item in mutating),
        "failures": failures,
        "noWriteControls": {name: control["mutation"]["failure"] for name, control in controls.items()},
        "noWriteControlsWroteNothing": all(
            not control["mutation"]["wrote"] and not control["mutation"]["changed"] for control in controls.values()
        ),
    }


def characterization_section(data):
    diagnostics = data["diagnostics"]
    adversarial = data["adversarial"]
    performance = data["performance"]
    asan = data["asan"]
    rss = data["rssMeasurements"]
    for item in adversarial:
        run = item["run"]
        recomputed_pass = (
            run.get("processOutcome") == "exit"
            and run.get("exitCode") == 0
            and (run.get("record") or {}).get("outcome") == item["expectedOutcome"]
        )
        require_equal(f"adversarial row {item['fixture']} pass", item["pass"], recomputed_pass)
    for item in performance:
        recomputed_pass = item["decodedAndClassified"] and item["p95Milliseconds"] <= item["gateMilliseconds"]
        require_equal(f"performance row {item['fixture']} pass", item["pass"], recomputed_pass)
    expected_asan_statuses = {"clean", "sanitizer_finding", "timeout", "unclassified_failure"}
    if any(item["status"] not in expected_asan_statuses for item in asan):
        raise SystemExit("sanitizer records contain an unknown status")
    rss_delta = None
    if rss["baselinePeakRSSBytes"] is not None and rss["oneMiBPeakRSSBytes"] is not None:
        rss_delta = max(0, rss["oneMiBPeakRSSBytes"] - rss["baselinePeakRSSBytes"])
    summary = {
        "diagnosticCases": len(diagnostics),
        "diagnosticStable": sum(item["stable"] for item in diagnostics),
        "diagnosticDecodedAndClassified": sum(item["decodedAndClassified"] for item in diagnostics),
        "diagnosticValid": sum(item["decodedAndClassified"] and item["stable"] for item in diagnostics),
        "diagnosticStructuredLine": sum(item["hasStructuredLine"] for item in diagnostics),
        "diagnosticStructuredColumn": sum(item["hasStructuredColumn"] for item in diagnostics),
        "diagnosticMessageEmbeddedLine": sum(item["messageEmbeddedLine"] is not None for item in diagnostics),
        "adversarialCases": len(adversarial),
        "adversarialPass": sum(item["pass"] for item in adversarial),
        "adversarialCrashes": sum(item["run"].get("processOutcome") == "signal" for item in adversarial),
        "adversarialBudgetMisses": sum(item.get("timeoutFollowUp") is not None for item in adversarial),
        "adversarialBudgetMissesCorrectlyClassified": sum(
            bool(item.get("timeoutFollowUp") and item["timeoutFollowUp"]["classificationCorrect"])
            for item in adversarial
        ),
        "performanceCases": len(performance),
        "performancePass": sum(item["pass"] for item in performance),
        "asanRequested": data["evidenceMode"] == "full",
        "asanCases": len(asan),
        "asanExpectedCases": len({item["fixture"] for item in adversarial}),
        "asanCoverageComplete": len(asan) == len({item["fixture"] for item in adversarial})
        and all(item["status"] in ("clean", "sanitizer_finding") for item in asan),
        "asanStatusCounts": {
            status: sum(item["status"] == status for item in asan)
            for status in ("clean", "sanitizer_finding", "timeout", "unclassified_failure")
        },
        "asanPass": sum(item["pass"] for item in asan),
        "asanFindings": sum(item.get("sanitizerFinding") is not None for item in asan),
        "releaseOneMiBPeakRSSBytes": rss["oneMiBPeakRSSBytes"],
        "releaseBaselinePeakRSSBytes": rss["baselinePeakRSSBytes"],
        "releaseOneMiBEstimatedRSSDeltaBytes": rss_delta,
        "releaseOneMiBRSSDeltaPass": rss_delta is not None and rss_delta <= 67_108_864,
    }
    require_equal("characterization stored summary", data["summary"], summary)
    crashes = [
        {"fixture": item["fixture"], "configuration": item["configuration"], "bytes": item["bytes"]}
        for item in data["adversarial"]
        if item["run"].get("processOutcome") == "signal"
    ]
    budget = [
        {
            "fixture": item["fixture"],
            "configuration": item["configuration"],
            "gateSeconds": item["gateTimeoutSeconds"],
            "actualMilliseconds": item["timeoutFollowUp"]["wallMilliseconds"],
            "classificationCorrect": item["timeoutFollowUp"]["classificationCorrect"],
        }
        for item in data["adversarial"]
        if item.get("timeoutFollowUp")
    ]
    findings = [{"fixture": item["fixture"], **item["sanitizerFinding"]} for item in data["asan"] if item.get("sanitizerFinding")]
    release_nodes = [
        item["run"]["wallMilliseconds"]
        for item in data["adversarial"]
        if item["configuration"] == "release" and item["fixture"].startswith("nodes-") and item["run"].get("wallMilliseconds")
    ]
    return {
        "evidenceMode": data.get("evidenceMode"),
        "diagnosticCases": summary["diagnosticCases"],
        "diagnosticDeterministic": f"{summary['diagnosticStable']}/{summary['diagnosticCases']}",
        "diagnosticDecodedAndClassified": f"{summary['diagnosticDecodedAndClassified']}/{summary['diagnosticCases']}",
        "diagnosticValid": f"{summary['diagnosticValid']}/{summary['diagnosticCases']}",
        "structuredLine": f"{summary['diagnosticStructuredLine']}/{summary['diagnosticCases']}",
        "structuredColumn": f"{summary['diagnosticStructuredColumn']}/{summary['diagnosticCases']}",
        "lineOnlyInFreeFormText": f"{summary['diagnosticMessageEmbeddedLine']}/{summary['diagnosticCases']}",
        "adversarialPass": f"{summary['adversarialPass']}/{summary['adversarialCases']}",
        "crashes": crashes,
        "debugBudgetMisses": budget,
        "sanitizerRequested": summary.get("asanRequested", False),
        "sanitizerCoverage": f"{summary.get('asanCases', 0)}/{summary.get('asanExpectedCases', 0)}",
        "sanitizerCoverageComplete": summary.get("asanCoverageComplete", False),
        "sanitizerStatusCounts": summary.get("asanStatusCounts", {}),
        "sanitizerFindings": findings,
        "performanceAllDecoded": all(item.get("decodedAndClassified") for item in data["performance"]),
        "performance": [
            {
                "fixture": item["fixture"],
                "decodedAndClassified": item.get("decodedAndClassified"),
                "bytes": item["bytes"],
                "p50Milliseconds": round(item["p50Milliseconds"], 3),
                "p95Milliseconds": round(item["p95Milliseconds"], 3),
                "maxMilliseconds": round(item["maxMilliseconds"], 3),
                "gateMilliseconds": item["gateMilliseconds"],
                "pass": item["pass"],
            }
            for item in data["performance"]
        ],
        "releaseWideTableMillisecondsRange": [round(min(release_nodes), 1), round(max(release_nodes), 1)] if release_nodes else None,
        "oneMiBPeakRSSDeltaBytes": summary["releaseOneMiBEstimatedRSSDeltaBytes"],
        "oneMiBRSSGatePass": summary["releaseOneMiBRSSDeltaPass"],
    }


def package_section(package, dependency):
    candidate = package["candidate"]
    upstream = package["upstreamTests"]
    optional_identities = {"benchmark", "swiftformat", "swift-docc-plugin"}
    resolved_absent = not bool(optional_identities.intersection(package["resolvedGraph"]["identities"]))
    require_equal(
        "package optional-dependency result",
        package["resolvedGraph"]["tomlDecoderOptionalDependenciesAbsent"],
        resolved_absent,
    )
    if package["environmentSanitization"]["presentDuringRun"]:
        raise SystemExit("optional-dependency switches were present during the package audit")
    require_equal(
        "package optional-dependency switch policy",
        sorted(package["environmentSanitization"]["clearedSwitches"]),
        sorted(POLICY["optionalDependencyEnvironmentSwitches"]),
    )
    return {
        "tag": candidate["tag"],
        "revision": candidate["revision"],
        "toolchain": package["toolchain"],
        "buildsPassed": all(item["outcome"] == "pass" for item in package["builds"]),
        "builds": [
            {"configuration": item["configuration"], "kind": item["kind"], "outcome": item["outcome"], "seconds": round(item["durationSeconds"], 2)}
            for item in package["builds"]
        ],
        "upstreamTests": {"outcome": upstream["outcome"], "tests": upstream["reportedExecutedTestCount"], "suites": upstream.get("reportedSuiteCount")},
        "productionTargetNativeFileCount": candidate["productionTargetNativeFileCount"],
        "unsafeFlagsPresent": candidate["unsafeFlagsPresent"],
        "manifestConditionalEnvironmentKeys": candidate["manifestConditionalEnvironmentKeys"],
        "optionalDependenciesAbsentFromResolvedGraph": resolved_absent,
        "footprint": package["footprint"],
        "checkoutBytesExcludingVCS": candidate["checkoutBytesExcludingVCS"],
        "crossCandidateReleaseExecutableBytes": dependency["releaseExecutableBytes"],
        "crossCandidateDebugExecutableBytes": dependency["debugExecutableBytes"],
    }


def ratio_complete(value):
    numerator, _, denominator = value.partition("/")
    return int(denominator) > 0 and numerator == denominator


# Explicit gate policy. Each entry states the requirement, reads the measured value, and decides
# on its own. The verdict below is derived only from these results.
GATE_POLICY = [
    ("oracle-agreement", "Both pinned Codex binaries agree on every document", True,
     lambda m: (ratio_complete(m["dialect"]["codexOracleAgreement"]), m["dialect"]["codexOracleAgreement"])),
    ("corpus-expectation", "Codex classifies every fixture as the corpus declares", True,
     lambda m: (ratio_complete(m["dialect"]["corpusExpectationAgreement"]), m["dialect"]["corpusExpectationAgreement"])),
    ("dialect-parity", "Candidate matches bundled Codex 0.149.0 on every document", True,
     lambda m: (ratio_complete(m["dialect"]["candidateAcceptRejectParity"]), m["dialect"]["candidateAcceptRejectParity"])),
    ("mcp-name-set", "Server name sets match the oracle on accepted documents", True,
     lambda m: (ratio_complete(m["dialect"]["acceptedMCPNameSetAgreement"]), m["dialect"]["acceptedMCPNameSetAgreement"])),
    ("oracle-projected-fields", "Every source-specified oracle-reported field matches, with no omissions", True,
     lambda m: (ratio_complete(m["dialect"]["oracleProjectedFieldAgreement"]), m["dialect"]["oracleProjectedFieldAgreement"])),
    ("declared-key-value", "Declared keys and values match for every MCP-bearing document", True,
     lambda m: (ratio_complete(m["dialect"]["declaredKeyValueAgreement"]), m["dialect"]["declaredKeyValueAgreement"])),
    ("declared-env-header", "Exhaustive declarations match, including env and http_headers", True,
     lambda m: (ratio_complete(m["dialect"]["declaredEnvHeaderAgreement"]), m["dialect"]["declaredEnvHeaderAgreement"])),
    ("order-projection", "Declaration order recovered for every fixture and configuration", True,
     lambda m: (ratio_complete(m["order"]["orderPass"]), m["order"]["orderPass"])),
    ("order-determinism", "Order and projection identical across every repeat", True,
     lambda m: (ratio_complete(m["order"]["deterministic"]), m["order"]["deterministic"])),
    ("mutation-transaction", "Mutation validates, preserves, and is byte-identical on reapplication", True,
     lambda m: (ratio_complete(m["order"]["mutationPass"]), m["order"]["mutationPass"])),
    ("no-write-controls", "Invalid, over-cap, and conflicting inputs write nothing", True,
     lambda m: (m["order"]["noWriteControlsWroteNothing"], m["order"]["noWriteControls"])),
    ("no-crash", "No crash on the adversarial corpus", True,
     lambda m: (not m["characterization"]["crashes"], f"{len(m['characterization']['crashes'])} crashes")),
    ("no-sanitizer-finding", "No AddressSanitizer finding on the adversarial corpus", True,
     lambda m: (not m["characterization"]["sanitizerFindings"], f"{len(m['characterization']['sanitizerFindings'])} findings")),
    ("sanitizer-coverage", "Sanitizer sweep covers every adversarial fixture", True,
     lambda m: (m["characterization"]["sanitizerCoverageComplete"], m["characterization"]["sanitizerCoverage"])),
    ("structured-line", "A structured syntax line number is exposed for every syntax error", True,
     lambda m: (ratio_complete(m["characterization"]["structuredLine"]), m["characterization"]["structuredLine"])),
    ("diagnostic-determinism", "Diagnostics decode, classify as expected, and are identical across every repeat", True,
     lambda m: (ratio_complete(m["characterization"]["diagnosticValid"]), m["characterization"]["diagnosticValid"])),
    ("adversarial-classification", "Every adversarial fixture classifies as its expected outcome", True,
     lambda m: (ratio_complete(m["characterization"]["adversarialPass"]), m["characterization"]["adversarialPass"])),
    ("release-latency", "Every release latency gate met by decoded, correctly classified runs", True,
     lambda m: (m["characterization"]["performanceAllDecoded"] and all(item["pass"] for item in m["characterization"]["performance"]),
                f"{sum(item['pass'] for item in m['characterization']['performance'])}/{len(m['characterization']['performance'])}")),
    ("debug-latency-budget", "Every debug invocation completes within 5 seconds", True,
     lambda m: (not m["characterization"]["debugBudgetMisses"], f"{len(m['characterization']['debugBudgetMisses'])} over budget")),
    ("peak-memory", "Peak memory increase for a 1 MiB document stays within 64 MiB", True,
     lambda m: (m["characterization"]["oneMiBRSSGatePass"], m["characterization"]["oneMiBPeakRSSDeltaBytes"])),
    ("builds-and-upstream-tests", "Debug and release build, and upstream tests pass", True,
     lambda m: (m["package"]["buildsPassed"] and m["package"]["upstreamTests"]["outcome"] == "pass",
                f"builds {m['package']['buildsPassed']}, upstream {m['package']['upstreamTests']['outcome']}")),
    ("no-native-production-code", "Production target adds no native source file", True,
     lambda m: (m["package"]["productionTargetNativeFileCount"] == 0, m["package"]["productionTargetNativeFileCount"])),
    ("no-unsafe-flags", "Manifest declares no unsafe flags", True,
     lambda m: (not m["package"]["unsafeFlagsPresent"], m["package"]["unsafeFlagsPresent"])),
    ("clean-dependency-graph", "Optional benchmark, DocC, and formatting dependencies stay out of the resolved graph", True,
     lambda m: (m["package"]["optionalDependenciesAbsentFromResolvedGraph"], m["package"]["optionalDependenciesAbsentFromResolvedGraph"])),
]

manifest = json.loads((ROOT / "Fixtures" / "dialect" / "manifest.json").read_text())
measurements = {
    "dialect": dialect_section(load("dialect.json"), manifest),
    "order": order_section(load("order-mutation.json")),
    "characterization": characterization_section(load("characterization.json")),
    "package": package_section(load("package-audit.json"), load("dependency-audit.json")),
}

gates = []
for identifier, requirement, blocking, evaluate in GATE_POLICY:
    passed, observed = evaluate(measurements)
    gates.append({"id": identifier, "requirement": requirement, "blocking": blocking, "observed": observed, "result": "pass" if passed else "fail"})

failed_blocking = [gate for gate in gates if gate["result"] == "fail" and gate["blocking"]]
decision = "NO-GO" if failed_blocking else "GO"

output = {
    "schema": 3,
    "candidate": "TOMLDecoder-0.4.5",
    "decision": decision,
    "decisionRule": "NO-GO when any blocking gate fails; GO only when every blocking gate passes",
    "winner": "TOMLDecoder-0.4.5" if decision == "GO" else None,
    "blockingGateFailures": [gate["id"] for gate in failed_blocking],
    "gates": gates,
    "gateCounts": {
        "total": len(gates),
        "passed": sum(gate["result"] == "pass" for gate in gates),
        "failedBlocking": len(failed_blocking),
    },
    "lanes": measurements,
}
destination = Path(os.environ["ISSUE830_SUMMARY_OUT"]) if os.environ.get("ISSUE830_SUMMARY_OUT") else RESULTS / "summary.json"
destination.write_text(json.dumps(output, indent=2, ensure_ascii=False, sort_keys=True) + "\n")
print(json.dumps({"decision": decision, "failedBlocking": [gate["id"] for gate in failed_blocking]}, sort_keys=True))
