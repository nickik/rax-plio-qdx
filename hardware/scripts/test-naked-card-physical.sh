#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/naked-card-physical"
SEARCH="+:$ROOT/qli/bluespec:$ROOT/qic/bluespec:$ROOT/pti/bluespec:$ROOT/plio-tx/bluespec:$ROOT/qli16/bluespec:$ROOT/naked-card/bluespec:$ROOT/testbench/bluespec"

# This is a CI/conformance test, not an endurance test. Every external command
# must terminate within a strict bound so a broken simulator cannot consume a
# runner indefinitely.
TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"
if [[ -z "$TIMEOUT_BIN" ]]; then
    echo "ERROR: GNU timeout (timeout/gtimeout) is required" >&2
    exit 2
fi

COMPILE_TIMEOUT="${COMPILE_TIMEOUT:-180}"
SIM_TIMEOUT="${SIM_TIMEOUT:-30}"
RUST_TIMEOUT="${RUST_TIMEOUT:-120}"
SCRIPT_TIMEOUT="${SCRIPT_TIMEOUT:-180}"

run_bounded() {
    local seconds="$1"
    local label="$2"
    shift 2
    echo "BOUND|start|${label}|timeout=${seconds}s"
    local rc=0
    "$TIMEOUT_BIN" --foreground --signal=TERM --kill-after=5s "${seconds}s" "$@" || rc=$?
    if [[ $rc -eq 124 || $rc -eq 137 ]]; then
        echo "BOUND|timeout|${label}|timeout=${seconds}s" >&2
        return 124
    fi
    if [[ $rc -ne 0 ]]; then
        echo "BOUND|failure|${label}|rc=${rc}" >&2
        return "$rc"
    fi
    echo "BOUND|pass|${label}"
}

rm -rf "$BUILD"
mkdir -p "$BUILD/bsv-worker" "$BUILD/bsv-probe" "$BUILD/bsv-fault" "$BUILD/bsv-local-fault" "$BUILD/bsv-stress"

command -v cargo >/dev/null
command -v bsc >/dev/null

echo "== Rust QIC regression oracle =="
run_bounded "$RUST_TIMEOUT" rust-qic cargo test --manifest-path "$ROOT/Cargo.toml" -p plio-qic-model

echo "== Exact Rust / Bluesim QLI-16 codec equivalence =="
run_bounded "$SCRIPT_TIMEOUT" qli16-codec bash "$ROOT/scripts/test-qli16-codec.sh"

echo "== Deterministic 4096-cycle Rust QLI-16 stress =="
run_bounded "$RUST_TIMEOUT" qli16-stress-rust \
    bash -o pipefail -c 'cargo run --quiet --manifest-path "$1" -p qli16-model --bin stress_conformance | tee "$2"' _ \
    "$ROOT/Cargo.toml" "$BUILD/stress-rust.log"
grep '^STRESSTRACE|' "$BUILD/stress-rust.log" > "$BUILD/stress-rust.trace"

echo "== Deterministic 4096-cycle Bluesim QLI-16 stress =="
run_bounded "$COMPILE_TIMEOUT" qli16-stress-compile \
    bsc -u -sim -p "$SEARCH" \
    -bdir "$BUILD/bsv-stress" -simdir "$BUILD/bsv-stress" -info-dir "$BUILD/bsv-stress" \
    -g mkTbQLI16Stress "$ROOT/qli16/bluespec/TbQLI16Stress.bsv"
run_bounded "$COMPILE_TIMEOUT" qli16-stress-link \
    bsc -sim -p "$SEARCH" \
    -bdir "$BUILD/bsv-stress" -simdir "$BUILD/bsv-stress" \
    -e mkTbQLI16Stress -o "$BUILD/tb-qli16-stress"
run_bounded "$SIM_TIMEOUT" qli16-stress-sim \
    bash -o pipefail -c '"$1" | tee "$2"' _ "$BUILD/tb-qli16-stress" "$BUILD/stress-bsv.log"
grep '^STRESSTRACE|' "$BUILD/stress-bsv.log" > "$BUILD/stress-bsv.trace"

echo "== Exact Rust / Bluesim 4096-cycle stress equivalence =="
diff -u "$BUILD/stress-rust.trace" "$BUILD/stress-bsv.trace"

echo "== Rust complete NakedCard physical stack =="
run_bounded "$RUST_TIMEOUT" naked-rust \
    bash -o pipefail -c 'cargo test --manifest-path "$1" -p naked-card --test physical_stack -- --nocapture --test-threads=1 | tee "$2"' _ \
    "$ROOT/Cargo.toml" "$BUILD/naked-rust.log"
grep -o 'NAKEDTRACE|v1|[^[:space:]]*' "$BUILD/naked-rust.log" | sort > "$BUILD/naked-rust.trace"

echo "== Rust complete physical fault matrix =="
run_bounded "$RUST_TIMEOUT" fault-rust \
    bash -o pipefail -c 'cargo test --manifest-path "$1" -p naked-card --test physical_faults -- --nocapture --test-threads=1 | tee "$2"' _ \
    "$ROOT/Cargo.toml" "$BUILD/fault-rust.log"
grep -o 'FAULTTRACE|v1|[^[:space:]]*' "$BUILD/fault-rust.log" | sort > "$BUILD/fault-rust.trace"

echo "== Bluesim full worker NakedCard =="
run_bounded "$COMPILE_TIMEOUT" naked-worker-compile \
    bsc -u -sim -p "$SEARCH" \
    -bdir "$BUILD/bsv-worker" -simdir "$BUILD/bsv-worker" -info-dir "$BUILD/bsv-worker" \
    -g mkTbNakedCardPhysical "$ROOT/naked-card/bluespec/TbNakedCardPhysical.bsv"
run_bounded "$COMPILE_TIMEOUT" naked-worker-link \
    bsc -sim -p "$SEARCH" \
    -bdir "$BUILD/bsv-worker" -simdir "$BUILD/bsv-worker" \
    -e mkTbNakedCardPhysical -o "$BUILD/tb-naked-worker"
run_bounded "$SIM_TIMEOUT" naked-worker-sim \
    bash -o pipefail -c '"$1" | tee "$2"' _ "$BUILD/tb-naked-worker" "$BUILD/naked-worker.log"
grep -q '^NAKEDTRACE|v1|case=worker_read|ad=504c494f|ack=1|err=0$' "$BUILD/naked-worker.log"
grep -q '^NAKEDTRACE|v1|case=worker_write|ack=1|err=0$' "$BUILD/naked-worker.log"
grep -q '^NAKEDTRACE|v1|case=unsupported|ack=0|err=1$' "$BUILD/naked-worker.log"

echo "== Bluesim physical DMA / Notification protocol probe =="
run_bounded "$COMPILE_TIMEOUT" naked-probe-compile \
    bsc -u -sim -p "$SEARCH" \
    -bdir "$BUILD/bsv-probe" -simdir "$BUILD/bsv-probe" -info-dir "$BUILD/bsv-probe" \
    -g mkTbNakedCardProtocolPhysical "$ROOT/naked-card/bluespec/TbNakedCardProtocolPhysical.bsv"
run_bounded "$COMPILE_TIMEOUT" naked-probe-link \
    bsc -sim -p "$SEARCH" \
    -bdir "$BUILD/bsv-probe" -simdir "$BUILD/bsv-probe" \
    -e mkTbNakedCardProtocolPhysical -o "$BUILD/tb-naked-probe"
run_bounded "$SIM_TIMEOUT" naked-probe-sim \
    bash -o pipefail -c '"$1" | tee "$2"' _ "$BUILD/tb-naked-probe" "$BUILD/naked-probe.log"

for words in 1 4 8 16; do
    grep -q "^NAKEDTRACE|v1|case=d2h|words=${words}|status=0$" "$BUILD/naked-probe.log"
    grep -q "^NAKEDTRACE|v1|case=h2d|words=${words}|status=0$" "$BUILD/naked-probe.log"
done
grep -q '^NAKEDTRACE|v1|case=notification|channel=2|ready=1$' "$BUILD/naked-probe.log"

{
    grep '^NAKEDTRACE|' "$BUILD/naked-worker.log"
    grep '^NAKEDTRACE|' "$BUILD/naked-probe.log"
} | sort > "$BUILD/naked-bsv.trace"

echo "== Exact Rust / Bluesim full-stack milestone equivalence =="
diff -u "$BUILD/naked-rust.trace" "$BUILD/naked-bsv.trace"

echo "== Bluesim complete physical fault matrix =="
run_bounded "$COMPILE_TIMEOUT" naked-fault-compile \
    bsc -u -sim -p "$SEARCH" \
    -bdir "$BUILD/bsv-fault" -simdir "$BUILD/bsv-fault" -info-dir "$BUILD/bsv-fault" \
    -g mkTbNakedCardFaultPhysical "$ROOT/naked-card/bluespec/TbNakedCardFaultPhysical.bsv"
run_bounded "$COMPILE_TIMEOUT" naked-fault-link \
    bsc -sim -p "$SEARCH" \
    -bdir "$BUILD/bsv-fault" -simdir "$BUILD/bsv-fault" \
    -e mkTbNakedCardFaultPhysical -o "$BUILD/tb-naked-fault"
run_bounded "$SIM_TIMEOUT" naked-fault-sim \
    bash -o pipefail -c '"$1" | tee "$2"' _ "$BUILD/tb-naked-fault" "$BUILD/fault-bsv-physical.log"

echo "== Bluesim QLI-16 malformed/backpressure/reset hardening =="
run_bounded "$COMPILE_TIMEOUT" qli16-fault-compile \
    bsc -u -sim -p "$SEARCH" \
    -bdir "$BUILD/bsv-local-fault" -simdir "$BUILD/bsv-local-fault" -info-dir "$BUILD/bsv-local-fault" \
    -g mkTbQLI16FaultHardening "$ROOT/qli16/bluespec/TbQLI16FaultHardening.bsv"
run_bounded "$COMPILE_TIMEOUT" qli16-fault-link \
    bsc -sim -p "$SEARCH" \
    -bdir "$BUILD/bsv-local-fault" -simdir "$BUILD/bsv-local-fault" \
    -e mkTbQLI16FaultHardening -o "$BUILD/tb-qli16-fault"
run_bounded "$SIM_TIMEOUT" qli16-fault-sim \
    bash -o pipefail -c '"$1" | tee "$2"' _ "$BUILD/tb-qli16-fault" "$BUILD/fault-bsv-local.log"

{
    grep '^FAULTTRACE|' "$BUILD/fault-bsv-physical.log"
    grep '^FAULTTRACE|' "$BUILD/fault-bsv-local.log"
} | sort > "$BUILD/fault-bsv.trace"

echo "== Exact Rust / Bluesim physical fault equivalence =="
diff -u "$BUILD/fault-rust.trace" "$BUILD/fault-bsv.trace"

echo "PASS complete NakedCard physical validation and fault-hardening ladder"
