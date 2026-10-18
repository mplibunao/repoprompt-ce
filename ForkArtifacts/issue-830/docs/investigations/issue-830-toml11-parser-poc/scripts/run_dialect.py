#!/usr/bin/env python3
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "Fixtures" / "dialect"
MANIFEST = json.loads((FIXTURES / "manifest.json").read_text())
BUNDLED = Path.home() / "Library/Application Support/RepoPrompt CE/DebugApps/RepoPrompt.app/Contents/Resources/BundledRuntimes/Codex/aarch64-apple-darwin/bin/codex"
CURRENT = Path.home() / ".npm-global/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex"
PROBES = {
    "tomldecoder-0.4.5": ROOT / ".build" / "release" / "probe-tomldecoder",
    "swift-toml-2.0.0": ROOT / ".build" / "release" / "probe-swift-toml",
    "tomlkit-0.6.0": ROOT / ".build" / "release" / "probe-tomlkit",
}
PROBE_IDENTITIES = {
    "tomldecoder-0.4.5": ("TOMLDecoder", "0.4.5"),
    "swift-toml-2.0.0": ("swift-toml", "2.0.0"),
    "tomlkit-0.6.0": ("TOMLKit", "0.6.0"),
}

# The oracle is the whole basis of the accept/reject verdict, so a run must not proceed against
# a binary that is not the exact reviewed one. Version, content hash, and signing identity are
# all pinned; any drift aborts before a single fixture executes.
EXPECTED_ORACLES = {
    "codex-0.149.0": {
        "version": "codex-cli 0.149.0",
        "sha256": "f4a74117b8142cda581c95ff753abf4508b5636d89682c1ed77e4a9249af8963",
        "teamIdentifier": "2DC432GLL2",
        "authority": "Developer ID Application: OpenAI OpCo, LLC (2DC432GLL2)",
    },
    "codex-0.152.0": {
        "version": "codex-cli 0.152.0",
        "sha256": "166e0593c333c1c6412cc9cea72b6e1dfc4fc79b4813da02c511a3339c9b9593",
        "teamIdentifier": "2DC432GLL2",
        "authority": "Developer ID Application: OpenAI OpCo, LLC (2DC432GLL2)",
    },
}


def identity_mismatches(name, record):
    expected = EXPECTED_ORACLES[name]
    signing = record.get("signing") or {}
    observed = {
        "version": record.get("version"),
        "sha256": record.get("sha256"),
        "teamIdentifier": next(iter(signing.get("TeamIdentifier", [])), None),
        "authority": next(iter(signing.get("Authority", [])), None),
    }
    return {
        field: {"expected": value, "observed": observed[field]}
        for field, value in expected.items()
        if observed[field] != value
    }

def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def provenance(path):
    version = subprocess.check_output([path, "--version"], text=True).strip()
    signed = subprocess.run(["codesign", "-dv", "--verbose=4", path], text=True, capture_output=True)
    signing = {}
    for line in signed.stderr.splitlines():
        if line.startswith(("Identifier=", "TeamIdentifier=", "Authority=")):
            key, value = line.split("=", 1)
            signing.setdefault(key, []).append(value)
    return {"path": str(path), "version": version, "sha256": sha256(path), "signing": signing}

def selected_from_codex(payload):
    selected = []
    for entry in payload:
        transport = entry.get("transport") or {}
        selected.append({
            "name": entry.get("name"),
            "command": transport.get("command"),
            "url": transport.get("url"),
            "enabled": entry.get("enabled"),
            "arguments": transport.get("args"),
        })
    return selected

def fixture_identity(fixture):
    return {"file": fixture.name, "bytes": fixture.stat().st_size, "sha256": sha256(fixture)}


def codex(name, binary, fixture, expected_accept):
    with tempfile.TemporaryDirectory(prefix="issue-830-codex-home-") as home:
        home_path = Path(home)
        shutil.copyfile(fixture, home_path / "config.toml")
        env = dict(os.environ)
        env["CODEX_HOME"] = home
        completed = subprocess.run([binary, "mcp", "list", "--json"], env=env, text=True, capture_output=True, timeout=20)
        parse_error = "TOML parse error" in completed.stderr
        payload = json.loads(completed.stdout) if completed.returncode == 0 else []
        result = {
            "schema": 1,
            "engine": "codex-cli",
            "version": EXPECTED_ORACLES[name]["version"],
            "fixtureIdentity": fixture_identity(fixture),
            "expectedOutcome": "accepted" if expected_accept else "parse_error",
            "accepted": completed.returncode == 0,
            "exitCode": completed.returncode,
            "outcome": "accepted" if completed.returncode == 0 else ("parse_error" if parse_error else "schema_error"),
            "selectedMCPServers": selected_from_codex(payload),
            "stderrStored": False,
        }
    # Checked after the context manager exits, so this records whether the isolated home was
    # actually torn down rather than restating that it existed while still in use.
    result["temporaryHomeRemoved"] = not home_path.exists()
    result["evidenceValidated"] = (
        result["outcome"] == result["expectedOutcome"]
        and result["temporaryHomeRemoved"]
        and result["schema"] == 1
        and result["engine"] == "codex-cli"
        and result["version"] == EXPECTED_ORACLES[name]["version"]
        and result["fixtureIdentity"] == fixture_identity(fixture)
    )
    return result

def probe(name, binary, fixture, expected_accept):
    completed = subprocess.run([binary, fixture], text=True, capture_output=True, timeout=20)
    if completed.returncode != 0:
        return {
            "accepted": False, "outcome": "process_failure", "exitCode": completed.returncode,
            "fixtureIdentity": fixture_identity(fixture), "expectedOutcome": "accepted" if expected_accept else "syntax_error",
            "evidenceValidated": False,
        }
    record = json.loads(completed.stdout)
    engine, version = PROBE_IDENTITIES[name]
    expected_outcome = "accepted" if expected_accept else "syntax_error"
    record["fixtureIdentity"] = fixture_identity(fixture)
    record["expectedOutcome"] = expected_outcome
    record["evidenceValidated"] = (
        record.get("schema") == 3
        and record.get("engine") == engine
        and record.get("version") == version
        and record.get("outcome") == expected_outcome
        and record.get("accepted") == expected_accept
        and record.get("metrics", {}).get("inputBytes") == fixture.stat().st_size
    )
    return record

oracle_provenance = {"codex-0.149.0": provenance(BUNDLED), "codex-0.152.0": provenance(CURRENT)}

identity_failures = {
    name: mismatches
    for name, record in oracle_provenance.items()
    if (mismatches := identity_mismatches(name, record))
}
if identity_failures:
    raise SystemExit(
        "oracle identity mismatch; refusing to run the dialect corpus: "
        + json.dumps(identity_failures, sort_keys=True)
    )

controls = {}
for name, binary in (("codex-0.149.0", BUNDLED), ("codex-0.152.0", CURRENT)):
    controls[name] = {
        "valid": codex(name, binary, FIXTURES / "p01-stdio.toml", True),
        "malformed": codex(name, binary, FIXTURES / "s07-unknown-escape.toml", False),
    }
    controls[name]["validityEstablished"] = controls[name]["valid"]["accepted"] and not controls[name]["malformed"]["accepted"] and controls[name]["malformed"]["outcome"] == "parse_error"

control_failures = sorted(name for name, value in controls.items() if not value["validityEstablished"])
if control_failures:
    raise SystemExit(
        "oracle controls did not establish validity; refusing to run the dialect corpus: "
        + ", ".join(control_failures)
    )

rows = []
for case in MANIFEST["cases"]:
    fixture = FIXTURES / case["file"]
    engines = {
        "codex-0.149.0": codex("codex-0.149.0", BUNDLED, fixture, case["expectedAccept"]),
        "codex-0.152.0": codex("codex-0.152.0", CURRENT, fixture, case["expectedAccept"]),
    }
    for name, binary in PROBES.items():
        engines[name] = probe(name, binary, fixture, case["expectedAccept"])
    incomplete = sorted(name for name, record in engines.items() if not record.get("evidenceValidated"))
    if incomplete:
        raise SystemExit(f"unvalidated runtime evidence for {case['id']}: {', '.join(incomplete)}")
    bundled = engines["codex-0.149.0"]
    current = engines["codex-0.152.0"]
    candidate = engines["tomldecoder-0.4.5"]
    expected_names = case["expectedMCPNames"]
    actual_names = [item["name"] for item in bundled["selectedMCPServers"]]
    rows.append({
        **case,
        "engines": engines,
        "codexVectorAgreement": bundled["accepted"] == current["accepted"],
        "candidateParity": candidate["accepted"] == bundled["accepted"],
        "expectedClassificationAgreement": bundled["accepted"] == case["expectedAccept"],
        # The oracle sorts servers by name, so only a set comparison is meaningful here.
        # Declaration order is checked against the candidate, which does preserve it.
        "bundledMCPNameSetAgreement": sorted(actual_names) == sorted(expected_names),
        "candidateMCPNameAgreement": candidate.get("orderedMCPServers", []) == expected_names if bundled["accepted"] else None,
    })

summary = {
    "documents": len(rows),
    "codexVectorMatches": sum(row["codexVectorAgreement"] for row in rows),
    "candidateParityMatches": sum(row["candidateParity"] for row in rows),
    "expectedClassificationMatches": sum(row["expectedClassificationAgreement"] for row in rows),
    "negativeControlMatches": {
        name: sum(row["engines"][name]["accepted"] == row["engines"]["codex-0.149.0"]["accepted"] for row in rows)
        for name in ("swift-toml-2.0.0", "tomlkit-0.6.0")
    },
    "acceptedMCPNameSetMatches": sum(row["bundledMCPNameSetAgreement"] for row in rows if row["expectedMCPNames"]),
    "acceptedMCPNameCases": sum(bool(row["expectedMCPNames"]) for row in rows),
}
output = {
    "schema": 2,
    "command": "CODEX_HOME=<fresh-temporary-home> codex mcp list --json",
    "networkBehavior": "configuration inventory only; configured MCP servers are not started",
    "privacy": "synthetic fixtures only; stderr and source excerpts are not stored",
    "oracleProvenance": oracle_provenance,
    "oracleIdentityVerified": True,
    "controls": controls,
    "summary": summary,
    "rows": rows,
}
(ROOT / "results").mkdir(exist_ok=True)
(ROOT / "results" / "dialect.json").write_text(json.dumps(output, indent=2, ensure_ascii=False, sort_keys=True) + "\n")
print(json.dumps(summary, sort_keys=True))
