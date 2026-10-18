#!/usr/bin/env python3
import hashlib
import json
import re
import subprocess
import tempfile
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "Fixtures" / "order"
MANIFEST = json.loads((FIXTURES / "manifest.json").read_text())
INPUT_BYTE_LIMIT = json.loads((ROOT / "evidence-policy.json").read_text())["inputByteLimit"]

def decode_basic(value):
    out = []
    i = 0
    escapes = {'"': '"', '\\': '\\', 'b': '\b', 't': '\t', 'n': '\n', 'f': '\f', 'r': '\r', 'e': '\x1b'}
    while i < len(value):
        if value[i] != "\\":
            out.append(value[i]); i += 1; continue
        i += 1
        code = value[i]
        if code in escapes:
            out.append(escapes[code]); i += 1
        elif code == "x":
            out.append(chr(int(value[i + 1:i + 3], 16))); i += 3
        elif code == "u":
            out.append(chr(int(value[i + 1:i + 5], 16))); i += 5
        elif code == "U":
            out.append(chr(int(value[i + 1:i + 9], 16))); i += 9
        else:
            raise ValueError("unreconciled key escape")
    return "".join(out)

def decode_key_path(raw):
    parts = []
    token = []
    quote = None
    escaped = False
    for char in raw.strip():
        if quote == '"':
            token.append(char)
            if escaped: escaped = False
            elif char == "\\": escaped = True
            elif char == '"': quote = None
        elif quote == "'":
            token.append(char)
            if char == "'": quote = None
        elif char in "\"'":
            quote = char; token.append(char)
        elif char == ".":
            parts.append("".join(token).strip()); token = []
        else:
            token.append(char)
    parts.append("".join(token).strip())
    decoded = []
    for part in parts:
        if part.startswith('"') and part.endswith('"'):
            decoded.append(decode_basic(part[1:-1]))
        elif part.startswith("'") and part.endswith("'"):
            decoded.append(part[1:-1])
        else:
            decoded.append(part)
    return decoded

def source_index(data):
    text = data.decode("utf-8-sig")
    lines = text.splitlines(keepends=True)
    state = "normal"
    headers = []
    current = []
    assignments = []
    for number, line in enumerate(lines):
        state_at_start = state
        i = 0
        single = None
        escaped = False
        while i < len(line):
            if state == "multiline_basic":
                if line.startswith('"""', i): state = "normal"; i += 3
                else: i += 1
            elif state == "multiline_literal":
                if line.startswith("'''", i): state = "normal"; i += 3
                else: i += 1
            elif single == '"':
                if escaped: escaped = False
                elif line[i] == "\\": escaped = True
                elif line[i] == '"': single = None
                i += 1
            elif single == "'":
                if line[i] == "'": single = None
                i += 1
            elif line.startswith('"""', i): state = "multiline_basic"; i += 3
            elif line.startswith("'''", i): state = "multiline_literal"; i += 3
            elif line[i] == '"': single = '"'; i += 1
            elif line[i] == "'": single = "'"; i += 1
            elif line[i] == "#": break
            else: i += 1
        if state_at_start != "normal":
            continue
        stripped = line.lstrip("\ufeff \t")
        header = re.match(r"^\[([^\[].*?)\]\s*(?:#.*)?(?:\r?\n)?$", stripped)
        if header:
            current = decode_key_path(header.group(1))
            headers.append({"line": number + 1, "path": current})
            continue
        assignment = re.match(r"^([^=]+?)\s*=", stripped)
        if assignment:
            assignments.append({"line": number + 1, "path": current + decode_key_path(assignment.group(1))})
    if state != "normal":
        raise ValueError("unterminated multiline string in validated source")
    return {"headers": headers, "assignments": assignments, "lines": lines}


OWNED_HEADER = re.compile(r"^\s*\[features\.code_mode\]\s*(?:\r?\n)?$")
OWNED_ASSIGNMENT = re.compile(r"^\s*enabled\s*=\s*(?:true|false)\s*(?:#.*)?(?:\r?\n)?$")


def comment_lines(data):
    """Comment lines, so preservation can be asserted rather than assumed."""
    return [line.strip() for line in data.decode("utf-8-sig").splitlines() if line.lstrip().startswith("#")]


def newline_style(data):
    """Classify line endings so a mutation cannot quietly rewrite them."""
    crlf = data.count(b"\r\n")
    bare = data.count(b"\n") - crlf
    if crlf and bare:
        return "mixed"
    return "crlf" if crlf else "lf"


def exact_byte_confinement(source, output, source_span, output_span):
    """Prove that one declared byte range contains the complete mutation.

    Prefix and suffix equality preserves every byte outside the range, including a UTF-8 BOM,
    comments, line endings, spacing, and unrelated values. The two spans may differ in length for
    insertion, while replacement still identifies the exact source and output byte ranges.
    """
    source_start, source_end = source_span
    output_start, output_end = output_span
    return (
        0 <= source_start <= source_end <= len(source)
        and 0 <= output_start <= output_end <= len(output)
        and source_start == output_start
        and source[:source_start] == output[:output_start]
        and source[source_end:] == output[output_end:]
    )


def probe(binary, path, expected_outcome):
    completed = subprocess.run([binary, path], text=True, capture_output=True, timeout=5)
    if completed.returncode != 0:
        return {"accepted": False, "outcome": "process_failure", "exitCode": completed.returncode, "evidenceValidated": False}
    record = json.loads(completed.stdout)
    identity = {
        "file": path.name,
        "bytes": path.stat().st_size,
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
    }
    record["fixtureIdentity"] = identity
    record["expectedOutcome"] = expected_outcome
    record["evidenceValidated"] = (
        record.get("schema") == 3
        and record.get("engine") == "TOMLDecoder"
        and record.get("version") == "0.4.5"
        and record.get("outcome") == expected_outcome
        and record.get("metrics", {}).get("inputBytes") == identity["bytes"]
    )
    return record

def mutate(data):
    index = source_index(data)
    lines = index["lines"]
    bom_bytes = 3 if data.startswith(b"\xef\xbb\xbf") else 0
    encoded_lines = [line.encode("utf-8") for line in lines]
    line_offsets = [bom_bytes]
    for line in encoded_lines:
        line_offsets.append(line_offsets[-1] + len(line))
    header_lines = [item["line"] for item in index["headers"] if item["path"] == ["features", "code_mode"]]
    if len(header_lines) > 1:
        return {"changed": False, "failure": "layout_index_mismatch", "output": None, "index": index}
    newline = "\r\n" if b"\r\n" in data else "\n"
    if header_lines:
        start = header_lines[0]
        later_headers = [item["line"] for item in index["headers"] if item["line"] > start]
        end = min(later_headers) - 1 if later_headers else len(lines)
        matches = [item for item in index["assignments"] if item["path"] == ["features", "code_mode", "enabled"] and start < item["line"] <= end]
        if len(matches) > 1:
            return {"changed": False, "failure": "layout_index_mismatch", "output": None, "index": index}
        if matches:
            at = matches[0]["line"] - 1
            boolean = re.match(r"^\s*enabled\s*=\s*(true|false)\s*(?:#.*)?(?:\r?\n)?$", lines[at])
            if not boolean:
                return {"changed": False, "failure": "owned_value_conflict", "output": None, "index": index}
            start_byte = line_offsets[at] + len(lines[at][:boolean.start(1)].encode("utf-8"))
            end_byte = line_offsets[at] + len(lines[at][:boolean.end(1)].encode("utf-8"))
            replacement = b"true"
            if data[start_byte:end_byte] == replacement:
                return {
                    "changed": False, "failure": None, "output": data, "index": index,
                    "sourceSpan": [start_byte, end_byte], "outputSpan": [start_byte, end_byte],
                }
            output = data[:start_byte] + replacement + data[end_byte:]
            return {
                "changed": True, "failure": None, "output": output, "index": index,
                "sourceSpan": [start_byte, end_byte],
                "outputSpan": [start_byte, start_byte + len(replacement)],
            }
        insertion = f"enabled = true{newline}".encode("utf-8")
        insertion_at = line_offsets[start]
        output = data[:insertion_at] + insertion + data[insertion_at:]
        return {
            "changed": True, "failure": None, "output": output, "index": index,
            "sourceSpan": [insertion_at, insertion_at],
            "outputSpan": [insertion_at, insertion_at + len(insertion)],
        }
    suffix = b"" if data.endswith((b"\n", b"\r")) or not data else newline.encode()
    insertion = suffix + f"[features.code_mode]{newline}enabled = true{newline}".encode()
    output = data + insertion
    return {
        "changed": True, "failure": None, "output": output, "index": index,
        "sourceSpan": [len(data), len(data)],
        "outputSpan": [len(data), len(output)],
    }

def run_once(binary, fixture, expected_source_outcome="accepted"):
    source = probe(binary, fixture, expected_source_outcome)
    if not source.get("accepted"):
        return {"source": source, "mutation": {"changed": False, "failure": "source_validation", "wrote": False}}
    data = fixture.read_bytes()
    mutation = mutate(data)
    if mutation["output"] is None:
        return {"source": source, "mutation": {"changed": False, "failure": mutation["failure"], "wrote": False}, "indexedHeaders": mutation["index"]["headers"]}
    with tempfile.TemporaryDirectory(prefix="issue-830-order-") as directory:
        output_path = Path(directory) / "candidate.toml"
        output_path.write_bytes(mutation["output"])
        candidate = probe(binary, output_path, "accepted")
        second = mutate(mutation["output"])
    source_span = mutation["sourceSpan"]
    output_span = mutation["outputSpan"]
    confined = exact_byte_confinement(data, mutation["output"], source_span, output_span)
    preserved = mutation["output"].startswith(data) if b"[features.code_mode]" not in data else True
    projection_unchanged = (
        candidate.get("orderedMCPServers") == source.get("orderedMCPServers")
        and candidate.get("selectedMCPServers") == source.get("selectedMCPServers")
    )
    return {
        "source": source,
        "candidateOutput": candidate,
        "mutation": {
            "changed": mutation["changed"],
            "failure": mutation["failure"],
            "wrote": candidate.get("accepted", False),
            "sourceOwnedByteRange": source_span,
            "outputOwnedByteRange": output_span,
            "sourcePrefixPreservedWhenAppending": preserved,
            "diffConfinedToOwnedSpan": confined,
            "outsideOwnedBytesIdentical": confined,
            "bomPreserved": data.startswith(b"\xef\xbb\xbf") == mutation["output"].startswith(b"\xef\xbb\xbf"),
            "unrelatedProjectionUnchanged": projection_unchanged,
            "commentsPreserved": comment_lines(data) == comment_lines(mutation["output"]),
            "newlineStylePreserved": newline_style(data) == newline_style(mutation["output"]),
            "secondApplicationByteIdentical": second["output"] == mutation["output"] and not second["changed"],
        },
        "indexedHeaders": mutation["index"]["headers"],
    }

results = []
for configuration in ("debug", "release"):
    binary = ROOT / ".build" / configuration / "probe-tomldecoder"
    for case in MANIFEST["cases"]:
        fixture = FIXTURES / case["file"]
        expected_source_outcome = "syntax_error" if case["id"] == "o11-bom-crlf" else "accepted"
        repeats = [run_once(binary, fixture, expected_source_outcome) for _ in range(100)]
        def stable_projection(item):
            source = item["source"]
            candidate = item.get("candidateOutput", {})
            return {
                "sourceOrder": source.get("orderedMCPServers"),
                "sourceSelected": source.get("selectedMCPServers"),
                "sourceOutcome": source.get("outcome"),
                "candidateOutcome": candidate.get("outcome"),
                "mutation": item["mutation"],
                "indexedHeaders": item.get("indexedHeaders"),
            }
        serialized = [json.dumps(stable_projection(item), ensure_ascii=False, sort_keys=True) for item in repeats]
        canonical = serialized[0]
        order_counts = Counter(tuple(item["source"].get("orderedMCPServers", [])) for item in repeats)
        projection_counts = Counter(hashlib.sha256(item.encode()).hexdigest() for item in serialized)
        results.append({
            **case,
            "configuration": configuration,
            "repeats": 100,
            "stable": all(item == canonical for item in serialized),
            "observedSourceOrders": [
                {"order": list(order), "count": count}
                for order, count in sorted(order_counts.items())
            ],
            "observedProjectionHashes": [
                {"sha256": digest, "count": count}
                for digest, count in sorted(projection_counts.items())
            ],
            "orderPass": len(order_counts) == 1 and list(next(iter(order_counts))) == case["expectedOrder"],
            # A mutation passes only when the output reparses, the edit is confined to owned
            # content, and everything else in the document survives untouched.
            "mutationPass": all(
                item.get("candidateOutput", {}).get("accepted", False)
                and item["source"].get("evidenceValidated", False)
                and item.get("candidateOutput", {}).get("evidenceValidated", False)
                and item["mutation"].get("secondApplicationByteIdentical", False)
                and item["mutation"].get("diffConfinedToOwnedSpan", False)
                and item["mutation"].get("outsideOwnedBytesIdentical", False)
                and item["mutation"].get("bomPreserved", False)
                and item["mutation"].get("unrelatedProjectionUnchanged", False)
                and item["mutation"].get("commentsPreserved", False)
                and item["mutation"].get("newlineStylePreserved", False)
                for item in repeats
            ),
            "representative": repeats[0],
        })

def confinement_negative_checks():
    source = (
        b"\xef\xbb\xbf# keep this comment\r\n"
        b"unrelated = \"alpha\"\r\n"
        b"other_enabled = false\r\n"
        b"[mcp_servers.first]\r\ncommand = \"one\"\r\n"
        b"[mcp_servers.second]\r\ncommand = \"two\"\r\n"
        b"[features.code_mode]\r\nenabled = false # owned\r\n"
    )
    mutation = mutate(source)
    output = mutation["output"]
    source_span, output_span = mutation["sourceSpan"], mutation["outputSpan"]

    def changed(old, new):
        candidate = output.replace(old, new, 1)
        return not exact_byte_confinement(source, candidate, source_span, output_span)

    first = b'[mcp_servers.first]\r\ncommand = "one"\r\n'
    second = b'[mcp_servers.second]\r\ncommand = "two"\r\n'
    reordered = output.replace(first + second, second + first, 1)
    return {
        "unrelatedValueChangeRejected": changed(b'\"alpha\"', b'\"omega\"'),
        "commentChangeRejected": changed(b"keep this comment", b"changed comment!!"),
        "orderingChangeRejected": not exact_byte_confinement(source, reordered, source_span, output_span),
        "bomLossRejected": not exact_byte_confinement(source, output[3:], source_span, [output_span[0] - 3, output_span[1] - 3]),
        "offRangeBooleanChangeRejected": changed(b"other_enabled = false", b"other_enabled = true "),
    }


controls = {}
control_sources = {
    "invalid_unrelated": (b'model="\\q"\n[mcp_servers.real]\ncommand="echo"\n', "syntax_error"),
    "owned_value_conflict": (b'[features.code_mode]\nenabled="user"\n', "accepted"),
    "over_byte_limit": (b'#' + b'x' * INPUT_BYTE_LIMIT, "input_too_large"),
}
for name, (data, expected_outcome) in control_sources.items():
    with tempfile.TemporaryDirectory(prefix="issue-830-control-") as directory:
        path = Path(directory) / "control.toml"; path.write_bytes(data)
        controls[name] = run_once(ROOT / ".build" / "release" / "probe-tomldecoder", path, expected_outcome)

summary = {
    "fixtureConfigurations": len(results),
    "stable": sum(item["stable"] for item in results),
    "orderPass": sum(item["orderPass"] for item in results),
    "mutationPass": sum(item["mutationPass"] for item in results),
    "noWriteControlsPass": all(not value["mutation"]["wrote"] for value in controls.values()),
    "confinementNegativeChecksPass": all(confinement_negative_checks().values()),
}
output = {"schema": 3, "protocol": "validate source -> index layout -> raw exact-byte-range mutation -> validate output -> second-application byte identity", "scope": "isolated proof-of-concept transaction, not product integration", "summary": summary, "results": results, "controls": controls, "confinementNegativeChecks": confinement_negative_checks()}
(ROOT / "results" / "order-mutation.json").write_text(json.dumps(output, indent=2, ensure_ascii=False, sort_keys=True) + "\n")
print(json.dumps(summary, sort_keys=True))
