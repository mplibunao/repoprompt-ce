#!/usr/bin/env python3
"""Generate the adversarial corpus.

The directory is cleared first and every fixture is emitted through one recorder, so a run
cannot inherit a stale file from an earlier corpus. The manifest records the complete intended
inventory with sizes and digests, and the run fails if the directory does not match it exactly.
"""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "Fixtures" / "adversarial"
OUT.mkdir(parents=True, exist_ok=True)
POLICY = json.loads((ROOT / "evidence-policy.json").read_text())
BYTE_LIMIT = POLICY["inputByteLimit"]

for stale in OUT.glob("*.toml"):
    stale.unlink()

inventory = []


def emit(name: str, data) -> None:
    payload = data if isinstance(data, bytes) else data.encode("utf-8")
    (OUT / name).write_bytes(payload)
    inventory.append(
        {"file": name, "bytes": len(payload), "sha256": hashlib.sha256(payload).hexdigest()}
    )


def exact_valid(size: int) -> bytes:
    prefix = b'value = "ok"\n#'
    suffix = b"\n"
    if size < len(prefix) + len(suffix):
        raise ValueError("exact-size fixture is too small")
    return prefix + (b"x" * (size - len(prefix) - len(suffix))) + suffix


def near_limit_invalid(invalid: bytes) -> bytes:
    return b"#" + (b"x" * (BYTE_LIMIT - len(invalid) - 2)) + b"\n" + invalid


def nested_key(depth: int) -> str:
    return ".".join(f"k{i}" for i in range(depth)) + ' = "v"\n'


def wide_table(nodes: int) -> str:
    return "".join(f"k{i}=0\n" for i in range(nodes))


def servers(count: int) -> str:
    return "".join(f'[mcp_servers.s{i:03}]\ncommand="synthetic-{i}"\n' for i in range(count))


for size, label in ((BYTE_LIMIT - 1, "limit-minus-1"), (BYTE_LIMIT, "limit"), (BYTE_LIMIT + 1, "limit-plus-1")):
    emit(f"bytes-{label}.toml", exact_valid(size))
emit("representative-64k.toml", exact_valid(65_536))

for depth in (64, 65, 127, 128, 129, 512):
    emit(f"depth-{depth}.toml", nested_key(depth))

max_depth_suffix = ' = "v"\n'
max_depth = (BYTE_LIMIT - len(max_depth_suffix)) // 2
emit("depth-max-under-byte-cap.toml", ("k." * (max_depth - 1)) + "k" + max_depth_suffix)

for count in (4_096, 4_097, 9_999, 10_000, 10_001):
    emit(f"array-{count}.toml", "a=[" + ",".join("1" for _ in range(count)) + "]\n")

for count in (49_999, 50_000, 50_001):
    emit(f"nodes-{count}.toml", wide_table(count))

for size in (262_143, 262_144, 262_145):
    emit(f"string-{size}.toml", 'value="' + ("x" * size) + '"\n')

for count in (5, 50, 255, 256, 257, 500):
    emit(f"servers-{count}.toml", servers(count))

emit("near-1mib-invalid-escape.toml", near_limit_invalid(b'value="\\q"\n'))
emit("near-1mib-unclosed-string.toml", near_limit_invalid(b'value="unterminated'))
emit("near-1mib-duplicate.toml", near_limit_invalid(b"value=1\nvalue=2\n"))
emit("near-1mib-valid.toml", b'value="ok"\n#' + (b"x" * (BYTE_LIMIT - len(b'value="ok"\n#') - 1)) + b"\n")
emit("near-1mib-invalid-eof.toml", (b"#x\n" * ((BYTE_LIMIT - 20) // 3)) + b'value="unterminated')
emit("over-1mib.toml", b"#" + (b"x" * BYTE_LIMIT))

utf8_base = bytearray(b'value="ok"\n')
for position, index in (("beginning", 0), ("middle", len(utf8_base) // 2), ("end", len(utf8_base))):
    payload = bytearray(utf8_base)
    payload[index:index] = b"\xff"
    emit(f"invalid-utf8-{position}.toml", bytes(payload))

intended = {item["file"] for item in inventory}
present = {path.name for path in OUT.glob("*.toml")}
if intended != present:
    raise SystemExit(
        f"adversarial corpus mismatch; missing {sorted(intended - present)}, unexpected {sorted(present - intended)}"
    )
if len(intended) != len(inventory):
    raise SystemExit("duplicate fixture name emitted")

(OUT / "manifest.json").write_text(
    json.dumps(
        {"schema": 1, "fixtureCount": len(inventory), "fixtures": sorted(inventory, key=lambda item: item["file"])},
        indent=2,
        sort_keys=True,
    )
    + "\n"
)
print(json.dumps({"fixtureCount": len(inventory)}, sort_keys=True))
