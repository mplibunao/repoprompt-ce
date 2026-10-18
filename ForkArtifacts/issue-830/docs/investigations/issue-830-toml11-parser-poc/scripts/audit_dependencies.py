#!/usr/bin/env python3
import hashlib, json, subprocess
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]

def license_record(path):
    """Record the license file with a hash and its SPDX-style title line.

    The title line is what identifies the license; the filename alone does not.
    """
    text = path.read_text(errors="replace")
    title = next((line.strip() for line in text.splitlines() if line.strip()), "")
    return {"name": path.name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "titleLine": title[:120]}

checkouts=ROOT/".build/checkouts"
items=[]
for name in ("TOMLDecoder","swift-toml","TOMLKit"):
    p=checkouts/name
    def git(*args): return subprocess.check_output(["git","-C",p,*args],text=True).strip()
    product_roots={"TOMLDecoder":[p/"Sources/TOMLDecoder"],"swift-toml":[p/"Sources/TOML",p/"Sources/CTomlPlusPlus"],"TOMLKit":[p/"Sources/TOMLKit",p/"Sources/CTOML"]}[name]
    native=[f for root in product_roots for pattern in ("**/*.cpp","**/*.c","**/*.hpp","**/*.h") for f in root.glob(pattern)]
    unsafe=subprocess.run(["grep","-R","-n","unsafeFlags",p/"Package.swift"],text=True,capture_output=True).stdout.strip()
    items.append({"candidate":name,"revision":git("rev-parse","HEAD"),"tag":git("describe","--tags","--exact-match"),"licenses":[license_record(x) for x in sorted(p.glob("LICENSE*"))],"nativeSourceFileCount":len(native),"nativeSourceFiles":sorted(str(f.relative_to(p)) for f in native),"unsafeFlagsPresent":bool(unsafe)})
# Probe sizes in both configurations evidence that each exact tag builds and links.
def probe_sizes(configuration):
    return {q.name:q.stat().st_size for q in (ROOT/".build"/configuration).glob("probe-*") if q.is_file() and q.suffix==""}
bins=probe_sizes("release")
debug_bins=probe_sizes("debug")
# Build outcomes are not asserted here. run_package_audit.py measures clean and incremental
# builds for the lead candidate; this file records candidate identity and footprint only.
out={"schema":2,"scope":"cross-candidate identity and footprint; build results live in package-audit.json","swiftVersion":subprocess.check_output(["swift","--version"],text=True).splitlines()[0],"macOSDeploymentTarget":"14.0","resolved":json.loads((ROOT/"Package.resolved").read_text()),"candidates":items,"releaseExecutableBytes":bins,"debugExecutableBytes":debug_bins}
(ROOT/"results/dependency-audit.json").write_text(json.dumps(out,indent=2,sort_keys=True)+"\n")
