#!/usr/bin/env python3
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "Fixtures" / "order"
OUT.mkdir(parents=True, exist_ok=True)
for old in OUT.glob("*.toml"):
    old.unlink()

cases = []
def add(identifier, content, order, exercises_existing_owned_section=False):
    data = content if isinstance(content, bytes) else content.encode("utf-8")
    filename = f"{identifier}.toml"
    (OUT / filename).write_bytes(data)
    cases.append({
        "id": identifier,
        "file": filename,
        "expectedOrder": order,
        "exercisesExistingOwnedSection": exercises_existing_owned_section,
    })

add("o01-nonlexicographic-regular", '[mcp_servers.zeta]\ncommand="z"\n[mcp_servers.alpha]\ncommand="a"\n', ["zeta", "alpha"])
add("o02-quoted-dot-space", '[mcp_servers."dot.name"]\ncommand="d"\n[mcp_servers."space name"]\ncommand="s"\n', ["dot.name", "space name"])
add("o03-toml11-escapes", '[mcp_servers."z\\x65ta"]\ncommand="\\x65cho"\n[mcp_servers."a\\elpha"]\ncommand="echo"\n', ["zeta", "a\u001blpha"])
add("o04-dotted-assignments", 'mcp_servers.zeta.command="z"\nmcp_servers.alpha.command="a"\n', ["zeta", "alpha"])
add("o05-inline-root", 'mcp_servers = { zeta = { command = "z" }, alpha = { command = "a" } }\n', ["zeta", "alpha"])
add("o06-nested-subsections", '[mcp_servers.zeta]\ncommand="z"\n[mcp_servers.zeta.env]\nSYNTHETIC="x"\n[mcp_servers.alpha]\nurl="http://127.0.0.1:9/mcp"\nhttp_headers={Synthetic="value"}\n', ["zeta", "alpha"])
add("o07-implicit-parent", '[mcp_servers.zeta.env]\nSYNTHETIC="x"\n[mcp_servers.zeta]\ncommand="z"\n[mcp_servers.alpha]\ncommand="a"\n', ["zeta", "alpha"])
add("o08-interleaved", '# before\n[mcp_servers.zeta]\ncommand="z"\n# between\n[synthetic]\nvalue="keep"\n[mcp_servers.alpha]\ncommand="a"\n# after\n', ["zeta", "alpha"])
add("o09-multiline-basic-decoy", 'decoy="""\n[features.code_mode]\nenabled=false\n[mcp_servers.fake]\ncommand="fake"\n"""\n[mcp_servers.real]\ncommand="echo"\n', ["real"])
add("o10-multiline-literal-decoy", "decoy='''\n[features.code_mode]\nenabled=false\n[mcp_servers.fake]\ncommand='fake'\n'''\n[mcp_servers.real]\ncommand='echo'\n", ["real"])
add("o11-bom-crlf", b'\xef\xbb\xbf[mcp_servers.zeta]\r\ncommand="z"\r\n[mcp_servers.alpha]\r\ncommand="a"\r\n', ["zeta", "alpha"])
add("o12-missing-mcp", 'model="synthetic"\n# no MCP table\n', [])

# o13 and o14 exercise the two mutation paths that act on an existing owned section, which the
# append-only fixtures above never reach: replacing an existing Boolean, and inserting the owned
# key into a section that lacks it. Both carry comments and CRLF so preservation is observable.
add(
    "o13-existing-section-boolean-replacement",
    b'# leading comment\r\n[mcp_servers.zeta]\r\ncommand="z"\r\n[features.code_mode]\r\n'
    b'# owned section comment\r\nenabled = false\r\n[mcp_servers.alpha]\r\ncommand="a"\r\n',
    ["zeta", "alpha"],
    exercises_existing_owned_section=True,
)
add(
    "o14-existing-section-key-insertion",
    b'# leading comment\r\n[mcp_servers.zeta]\r\ncommand="z"\r\n[features.code_mode]\r\n'
    b'# owned section without the key\r\n[mcp_servers.alpha]\r\ncommand="a"\r\n',
    ["zeta", "alpha"],
    exercises_existing_owned_section=True,
)

assert len(cases) == 14
(OUT / "manifest.json").write_text(json.dumps({"schema": 2, "fixtureCount": len(cases), "cases": cases}, indent=2, ensure_ascii=False, sort_keys=True) + "\n")
