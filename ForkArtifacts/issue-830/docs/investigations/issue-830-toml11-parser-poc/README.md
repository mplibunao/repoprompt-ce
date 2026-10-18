# Upstream issue 830 TOML parser proof of concept

An isolated Swift package that compares three exactly pinned TOML parsers against the Codex
runtime's own accept/reject behavior:

- `dduan/TOMLDecoder` 0.4.5
- `mattt/swift-toml` 2.0.0
- `LebJe/TOMLKit` 0.6.0

The outcome is **NO-GO**; see [`report.md`](report.md) for the decision, the measured matrix,
and the unresolved gaps.

This package is not imported by RepoPrompt CE and never reads the real Codex home. The oracle
runner copies one synthetic fixture into a fresh temporary `CODEX_HOME` per invocation and runs
`codex mcp list --json`, which loads configuration without starting configured MCP servers.
Both oracle versions are confirmed against a valid and a malformed control before their results
are used.

## Reproduce

From this directory:

```sh
./scripts/run_all.sh --full-evidence
```

`--full-evidence` builds an AddressSanitizer probe and runs the sanitizer sweep. The published
resource findings depend on it, so this is the mode that reproduces the report.

Plain `./scripts/run_all.sh` runs every other lane and refuses to overwrite a retained sanitizer
result, so partial reproduction cannot silently discard evidence. Set
`ISSUE830_ALLOW_PARTIAL_EVIDENCE=1` only to drop it deliberately.

Every reproduction clears the four optional-dependency switches for `TOMLDecoder`. It then resets the
isolated package before resolution. The runner atomically sets `results/run-state.json` to `running`,
`complete`, or `interrupted`. Verification accepts retained output only after a complete run.
Verification also needs the original RepoPrompt CE checkout and a local plan that isn't published,
so a run from this archived copy fails at the verification step.

## Lanes

| Script | Produces | Covers |
|---|---|---|
| `run_dialect.py` | `results/dialect.json` | 48-document differential against both Codex binaries and all three candidates |
| `run_order.py` | `results/order-mutation.json` | 14 fixtures × debug/release × 100 repeats; ordered projection and the mutation transaction, including existing owned sections |
| `run_characterization.py` | `results/characterization.json` | diagnostic determinism, adversarial limits, AddressSanitizer, release latency and memory |
| `run_package_audit.py` | `results/package-audit.json` | builds, upstream tests, dependency graph, manifest surface, footprint |
| `audit_dependencies.py` | `results/dependency-audit.json` | cross-candidate identity, licenses, native file inventory, probe sizes |
| `build_summary.py` | `results/summary.json` | explicit gate policy evaluated against the raw lane outputs; the decision is derived from it |
| `verify_artifacts.py` | `results/verification.json` | mechanical re-check of counts, schemas, prose numbers, hashes, and the Git boundary |
| `verify_negative_cases.py` | none | focused tamper checks proving inconsistent summaries and interrupted runs are rejected |

`build_summary.py` and `verify_artifacts.py` recompute lane aggregates from the retained per-case
records and reject disagreements with either the lane's stored summary or `results/summary.json`.
The decision follows from the gate policy rather than from prose, and verification rejects any
number in the report's measured sections when derivation from a raw artifact is impossible.

`evidence-policy.json` is the documented source for the 1,048,576-byte input boundary and the
optional-dependency environment switches. Verification checks that the generated boundary fixtures,
the retained records, and the Swift probe use that same boundary.

## Evidence rules

All inputs are synthetic. Result JSON stores classifications, timings, stable error categories,
positions, sanitizer symbol names, the semantic projection of synthetic fixtures, and bounded
compiler/test excerpts produced while building this isolated POC and its pinned dependencies.
Synthetic fixture values may include server names, commands, URLs, environment entries, and
header values. Real Codex configuration is never read or retained, and source excerpts from
RepoPrompt CE or any other non-POC source are excluded.

Two comparisons carry explicit definitions, because the Codex oracle is not a byte-for-byte peer
of a TOML parser:

- `codex mcp list --json` sorts servers by name, so it validates names and values but cannot
  validate declaration order. Order is asserted against each fixture's declared order instead.
- Codex applies configuration-schema defaults that the source document does not contain, so
  comparison is driven by the fixture manifest, which declares independently of any parser which
  keys each server carries and what each field should hold. A declared field the parser omits
  counts as a failure rather than a skip, and the parser's own report of which keys it saw is a
  value under test rather than the yardstick.
- Codex never reports `env` or `http_headers`, so those fields are covered only by the six
  exhaustive manifest declarations.

In this archived copy, `results/package-audit.json` and `results/dialect.json` had absolute paths
replaced after verification and `report.md` is the sanitized copy published in the distribution, so
the digests of those three files and of this README in `results/verification.json` predate those edits.
