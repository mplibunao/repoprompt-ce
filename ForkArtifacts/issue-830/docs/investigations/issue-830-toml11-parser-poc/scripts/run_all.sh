#!/bin/sh
# Reproduce the proof-of-concept lanes.
#
#   ./scripts/run_all.sh --full-evidence   builds an AddressSanitizer probe and runs the
#                                          sanitizer sweep, which the published resource
#                                          findings depend on.
#   ./scripts/run_all.sh                   runs every other lane. It refuses to overwrite a
#                                          retained sanitizer result, so evidence is never
#                                          silently dropped.
set -eu
cd "$(dirname "$0")/.."

python3 scripts/run_state.py running
completed=0
finish_run() {
    if [ "$completed" -ne 1 ]; then
        python3 scripts/run_state.py interrupted >/dev/null
    fi
}
trap finish_run EXIT HUP INT TERM

# TOMLDecoder's manifest uses these switches to add optional dependency surfaces. Reproduction
# must start from one closed dependency environment, including the initial resolve and builds.
unset TOMLDECODER_BENCHMARKS TOMLDECODER_DOCS SPI_GENERATE_DOCS TOMLDECODER_FORMATTING

FULL_EVIDENCE=0
for argument in "$@"; do
    case "$argument" in
        --full-evidence) FULL_EVIDENCE=1 ;;
        *) echo "unknown option: $argument" >&2; exit 64 ;;
    esac
done

# Reset after clearing the manifest switches. Otherwise a prior environment-conditioned resolve
# can leave optional checkouts in .build even though the current process is clean.
swift package reset
swift package resolve
python3 scripts/generate_fixtures.py
python3 scripts/generate_adversarial.py
python3 scripts/generate_order_fixtures.py
swift build
swift build -c release
python3 scripts/run_dialect.py
python3 scripts/run_order.py

if [ "$FULL_EVIDENCE" -eq 1 ]; then
    ASAN_SCRATCH="${ISSUE830_ASAN_SCRATCH:-/tmp/issue830-asan}"
    swift build \
        --sanitize=address \
        --product probe-tomldecoder \
        --scratch-path "$ASAN_SCRATCH"
    ISSUE830_ASAN_BINARY="$ASAN_SCRATCH/debug/probe-tomldecoder" \
        python3 scripts/run_characterization.py
else
    python3 scripts/run_characterization.py
fi

python3 scripts/run_package_audit.py
python3 scripts/audit_dependencies.py
python3 scripts/build_summary.py
python3 scripts/render_report_tables.py
python3 scripts/run_state.py complete
python3 scripts/verify_negative_cases.py
python3 scripts/verify_artifacts.py
completed=1
trap - EXIT HUP INT TERM
