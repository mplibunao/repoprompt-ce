#!/usr/bin/env python3
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "Fixtures" / "dialect"
OUT.mkdir(parents=True, exist_ok=True)
for old in OUT.glob("*.toml"):
    old.unlink()

cases = []
def add(identifier, category, expected, content, mcp_names=None, servers=None, full_projection=False):
    """Register one fixture.

    `servers` declares, in declaration order, which keys each server carries and what each
    supported field should hold. The manifest is the authority: comparisons check the candidate
    against these declarations rather than against keys the candidate reports about itself.

    `full_projection` marks the fixtures whose declarations are exhaustive enough to compare the
    entire projection, including `env` and `http_headers`. Those fields never appear in
    `codex mcp list --json`, so a declaration is the only way to check them at all.
    """
    data = content if isinstance(content, bytes) else content.encode("utf-8")
    filename = f"{identifier}.toml"
    (OUT / filename).write_bytes(data)
    case = {"id": identifier, "file": filename, "category": category, "expectedAccept": expected, "expectedMCPNames": mcp_names or []}
    if servers is not None:
        case["expectedServers"] = servers
        case["fullProjectionDeclared"] = full_projection
    cases.append(case)

# Strings and escapes: 12
add("s01-existing-escapes", "strings", True, 'model = "a\\tb\\nc\\r\\bd\\fe"\n')
add("s02-escape-e", "strings", True, 'model = "before\\eafter"\n')
add("s03-escape-x41", "strings", True, 'model = "A=\\x41"\n')
add("s04-escape-x1b", "strings", True, 'model = "ESC=\\x1B"\n')
add("s05-mixed-escapes", "strings", True, 'model = "\\t\\e\\x41\\u0042\\U00000043"\n')
add("s06-escape-in-quoted-key", "strings", True, '[mcp_servers."na\\x6de"]\ncommand = "echo"\n', ["name"],
    servers=[{"name": "name", "command": "echo", "declaredKeys": ["command"]}],
    full_projection=True)
add("s07-unknown-escape", "strings", False, 'model = "\\q"\n')
add("s08-short-x", "strings", False, 'model = "\\x1"\n')
add("s09-nonhex-x", "strings", False, 'model = "\\xG0"\n')
add("s10-short-u", "strings", False, 'model = "\\u123"\n')
add("s11-short-U", "strings", False, 'model = "\\U0001234"\n')
add("s12-invalid-scalar", "strings", False, 'model = "\\uD800"\n')

# Whole-document malformed input: 6
add("m01-unterminated-basic", "malformed", False, 'model = "unterminated\n')
add("m02-unterminated-multiline", "malformed", False, 'model = """unterminated\n')
add("m03-malformed-header", "malformed", False, '[mcp_servers.alpha\ncommand = "echo"\n')
add("m04-trailing-characters", "malformed", False, 'model = "ok" trailing\n')
add("m05-bare-cr", "malformed", False, b'model = "ok"\rmodel_reasoning_effort = "low"\n')
add("m06-control-character", "malformed", False, b'model = "bad\x01value"\n')

# Duplicate and redefinition: 8
add("d01-duplicate-key", "duplicates", False, 'model = "a"\nmodel = "b"\n')
add("d02-duplicate-table", "duplicates", False, '[mcp_servers.alpha]\ncommand="a"\n[mcp_servers.alpha]\nurl="http://localhost"\n')
add("d03-dotted-extension-conflict", "duplicates", False, 'a.b = 1\na.b.c = 2\n')
add("d04-inline-table-sealed", "duplicates", False, 'a = { b = 1 }\na.c = 2\n')
add("d05-scalar-table-conflict", "duplicates", False, 'a = 1\n[a]\nb = 2\n')
add("d06-array-table-conflict", "duplicates", False, 'a = []\n[a]\nb = 2\n')
add("d07-dotted-table-conflict", "duplicates", False, 'a.b = 1\n[a.b]\nc = 2\n')
add("d08-table-array-table-conflict", "duplicates", False, '[a]\nb=1\n[[a]]\nb=2\n')

# Dotted, inline, and table construction: 8
add("c01-regular-headers", "construction", True, '[mcp_servers.zeta]\ncommand="z"\n[mcp_servers.alpha]\ncommand="a"\n', ["zeta", "alpha"],
    servers=[{"name": "zeta", "command": "z", "declaredKeys": ["command"]},
             {"name": "alpha", "command": "a", "declaredKeys": ["command"]}])
add("c02-dotted-assignments", "construction", True, 'mcp_servers.zeta.command="z"\nmcp_servers.alpha.command="a"\n', ["zeta", "alpha"],
    servers=[{"name": "zeta", "command": "z", "declaredKeys": ["command"]},
             {"name": "alpha", "command": "a", "declaredKeys": ["command"]}])
add("c03-quoted-dot", "construction", True, '[mcp_servers."dot.name"]\ncommand="echo"\n', ["dot.name"],
    servers=[{"name": "dot.name", "command": "echo", "declaredKeys": ["command"]}])
add("c04-inline-root", "construction", True, 'mcp_servers = { zeta = { command = "z" }, alpha = { command = "a" } }\n', ["zeta", "alpha"],
    servers=[{"name": "zeta", "command": "z", "declaredKeys": ["command"]},
             {"name": "alpha", "command": "a", "declaredKeys": ["command"]}])
add("c05-implicit-parent", "construction", True, '[mcp_servers.alpha.env]\nSYNTHETIC="value"\n[mcp_servers.alpha]\ncommand="echo"\n', ["alpha"],
    servers=[{"name": "alpha", "command": "echo", "env": {"SYNTHETIC": "value"},
              "declaredKeys": ["command", "env"]}])
add("c06-array-of-tables", "construction", True, '[[synthetic_array]]\nname="one"\n[[synthetic_array]]\nname="two"\n')
add("c07-legal-mixed", "construction", True, 'mcp_servers.zeta.command="z"\n[mcp_servers.alpha]\ncommand="a"\n', ["zeta", "alpha"],
    servers=[{"name": "zeta", "command": "z", "declaredKeys": ["command"]},
             {"name": "alpha", "command": "a", "declaredKeys": ["command"]}])
add("c08-nested-subsection", "construction", True, '[mcp_servers.alpha]\ncommand="echo"\n[mcp_servers.alpha.env]\nSYNTHETIC="value"\n', ["alpha"],
    servers=[{"name": "alpha", "command": "echo", "env": {"SYNTHETIC": "value"},
              "declaredKeys": ["command", "env"]}])

# Numeric and date/time: 6
add("n01-signs-underscores", "numeric", True, 'model_context_window = +1_000\nmodel_auto_compact_token_limit = 900\n')
add("n02-radices", "numeric", True, 'synthetic_hex=0xDEAD_BEEF\nsynthetic_oct=0o755\nsynthetic_bin=0b1010\n')
add("n03-leading-zero", "numeric", False, 'model_context_window = 0123\n')
add("n04-integer-overflow", "numeric", False, 'model_context_window = 9223372036854775808\n')
add("n05-invalid-date", "numeric", False, 'synthetic_date = 2025-02-30\n')
add("n06-valid-datetime", "numeric", True, 'synthetic_date = 2025-09-05T12:34:56Z\n')

# Unicode and encoding: 4
add("u01-bom", "unicode", True, b'\xef\xbb\xbfmodel = "synthetic"\n')
add("u02-nonascii", "unicode", True, '[mcp_servers."日本語"]\ncommand="écho"\n', ["日本語"],
    servers=[{"name": "日本語", "command": "écho", "declaredKeys": ["command"]}],
    full_projection=True)
add("u03-invalid-utf8", "unicode", False, b'model = "\xff"\n')
add("u04-disallowed-control", "unicode", False, b'model = "bad\x7fvalue"\n')

# Representative MCP configuration: 4
add("p01-stdio", "mcp", True, '[mcp_servers.stdio]\ncommand="echo"\nargs=["synthetic"]\nenabled=true\n', ["stdio"],
    servers=[{"name": "stdio", "command": "echo", "arguments": ["synthetic"], "enabled": True,
              "declaredKeys": ["args", "command", "enabled"]}],
    full_projection=True)
add("p02-streamable-http", "mcp", True, '[mcp_servers.remote]\nurl="http://127.0.0.1:9/mcp"\nenabled=false\n', ["remote"],
    servers=[{"name": "remote", "url": "http://127.0.0.1:9/mcp", "enabled": False,
              "declaredKeys": ["enabled", "url"]}],
    full_projection=True)
add("p03-env-and-headers", "mcp", True, '[mcp_servers.local]\ncommand="echo"\n[mcp_servers.local.env]\nTOKEN="SYNTHETIC_NOT_SECRET"\n[mcp_servers.remote]\nurl="http://127.0.0.1:9/mcp"\nhttp_headers={Authorization="SYNTHETIC_HEADER"}\nenabled=false\n', ["local", "remote"],
    servers=[{"name": "local", "command": "echo", "env": {"TOKEN": "SYNTHETIC_NOT_SECRET"},
              "declaredKeys": ["command", "env"]},
             {"name": "remote", "url": "http://127.0.0.1:9/mcp", "enabled": False,
              "httpHeaders": {"Authorization": "SYNTHETIC_HEADER"},
              "declaredKeys": ["enabled", "http_headers", "url"]}],
    full_projection=True)
add("p04-quoted-escaped-names", "mcp", True, '[mcp_servers."space name"]\ncommand="echo"\n[mcp_servers."dot\\x2ename"]\ncommand="echo"\n', ["space name", "dot.name"],
    servers=[{"name": "space name", "command": "echo", "declaredKeys": ["command"]},
             {"name": "dot.name", "command": "echo", "declaredKeys": ["command"]}],
    full_projection=True)

assert len(cases) == 48
manifest = {"schema": 3, "documentCount": len(cases), "declaredServerCases": sum("expectedServers" in c for c in cases),
    "fullProjectionCases": sum(c.get("fullProjectionDeclared", False) for c in cases), "cases": cases}
(OUT / "manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False, sort_keys=True) + "\n")
