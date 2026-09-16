#!/usr/bin/env bash
set -Eeuo pipefail
PS4='+ ${BASH_SOURCE##*/}:${LINENO}: '
set -x

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${MEMORY_CONTROLLER_DEBUG_DIR:-$ROOT/build/memory-controller}"
SEARCH="+:$ROOT/qli/bluespec:$ROOT/qic/bluespec:$ROOT/plio-rax-host/bluespec:$ROOT/memory-controller/bluespec"
BSC="${BSC:-bsc}"
BSC_STACK=(+RTS -K8M -RTS)

rm -rf "$BUILD"
mkdir -p "$BUILD/controller-sim" "$BUILD/host-sim" "$BUILD/rtl"
BUILD="$(cd "$BUILD" && pwd)"

print_file() {
    local file="$1"
    echo "===== $file ====="
    if [[ -f "$file" ]]; then nl -ba "$file"; else echo "missing: $file"; fi
}

dump_diagnostics() {
    local status="$1"
    local command="$2"
    trap - ERR
    set +e
    set +x
    {
        echo "=== MEMORY CONTROLLER FAILURE DIAGNOSTICS ==="
        printf 'exit_status=%s\n' "$status"
        printf 'failed_command=%s\n' "$command"
        printf 'cwd=%s\nroot=%s\nbuild=%s\nsearch=%s\n' "$PWD" "$ROOT" "$BUILD" "$SEARCH"
        echo "--- git ---"
        git -C "$ROOT/.." rev-parse HEAD 2>&1 || true
        git -C "$ROOT/.." status --short 2>&1 || true
        git -C "$ROOT/.." diff -- hardware/memory-controller hardware/scripts/test-memory-controller.sh .github/workflows/hardware-bluespec.yml 2>&1 || true
        echo "--- host / tools ---"
        uname -a 2>&1 || true
        "$BSC" -version 2>&1 || true
        cargo --version 2>&1 || true
        rustc --version 2>&1 || true
        yosys -V 2>&1 || true
        echo "--- Bluespec sources ---"
        print_file "$ROOT/memory-controller/bluespec/MemoryController.bsv"
        print_file "$ROOT/memory-controller/bluespec/BlockRamBackend.bsv"
        print_file "$ROOT/memory-controller/bluespec/TbMemoryController.bsv"
        print_file "$ROOT/memory-controller/bluespec/TbPLIOHostBlockRam.bsv"
        echo "--- generated artifacts ---"
        find "$BUILD" -maxdepth 6 -type f -printf '%p\t%s bytes\n' | sort || true
        echo "--- logs ---"
        while IFS= read -r log; do echo "===== $log ====="; cat "$log" || true; done < <(find "$BUILD" -type f \( -name '*.log' -o -name '*.trace' \) | sort)
        echo "=== END MEMORY CONTROLLER FAILURE DIAGNOSTICS ==="
    } 2>&1 | tee "$BUILD/diagnostics.log" >&2
}

on_error() {
    local status=$?
    local command="$BASH_COMMAND"
    dump_diagnostics "$status" "$command"
    exit "$status"
}
trap on_error ERR

run_bsc() {
    local label="$1"
    shift
    local log="$BUILD/${label}.log"
    printf 'BSC COMMAND:'; printf ' %q' "$BSC" "$@"; printf '\n'
    set +e
    "$BSC" "$@" 2>&1 | tee "$log"
    local bsc_status=${PIPESTATUS[0]}
    set -e
    if (( bsc_status != 0 )); then return "$bsc_status"; fi
}

command -v "$BSC" >/dev/null
command -v cargo >/dev/null
command -v yosys >/dev/null

echo "== Diagnostic context =="
git -C "$ROOT/.." rev-parse HEAD
"$BSC" -version || true
cargo --version
yosys -V
printf 'Bluespec search path: %s\nDiagnostic build directory: %s\n' "$SEARCH" "$BUILD"

echo "== Memory controller Rust reference =="
cargo test --manifest-path "$ROOT/Cargo.toml" -p memory-controller-model --all-targets 2>&1 | tee "$BUILD/rust-tests.log"
cargo run --quiet --manifest-path "$ROOT/Cargo.toml" -p memory-controller-model --bin conformance 2>&1 | tee "$BUILD/rust.log"
grep '^MEMCTRLTRACE|' "$BUILD/rust.log" > "$BUILD/rust-controller.trace"
grep '^MEMHOSTTRACE|' "$BUILD/rust.log" > "$BUILD/rust-host.trace"
test "$(wc -l < "$BUILD/rust-controller.trace")" -eq 4
test "$(wc -l < "$BUILD/rust-host.trace")" -eq 3
grep -q '^PASS memory controller Rust reference + PLIO host integration$' "$BUILD/rust.log"

echo "== Memory controller Bluesim reference =="
run_bsc bsc-controller-compile "${BSC_STACK[@]}" -u -sim -p "$SEARCH" \
    -bdir "$BUILD/controller-sim" -simdir "$BUILD/controller-sim" -info-dir "$BUILD/controller-sim" \
    -g mkTbMemoryController "$ROOT/memory-controller/bluespec/TbMemoryController.bsv"
run_bsc bsc-controller-link "${BSC_STACK[@]}" -sim -p "$SEARCH" \
    -bdir "$BUILD/controller-sim" -simdir "$BUILD/controller-sim" \
    -e mkTbMemoryController -o "$BUILD/tb-memory-controller"
"$BUILD/tb-memory-controller" 2>&1 | tee "$BUILD/controller-bsv.log"
grep '^MEMCTRLTRACE|' "$BUILD/controller-bsv.log" > "$BUILD/bsv-controller.trace"
test "$(wc -l < "$BUILD/bsv-controller.trace")" -eq 4
grep -q '^PASS memory controller byte-enable semantics$' "$BUILD/controller-bsv.log"

echo "== Exact Rust / Bluesim byte-enable memory-controller trace =="
diff -u "$BUILD/rust-controller.trace" "$BUILD/bsv-controller.trace" 2>&1 | tee "$BUILD/controller-diff.log"

echo "== PLIOHostCore -> MemoryController -> default 1 MiB integrated BRAM Bluesim integration =="
run_bsc bsc-host-compile "${BSC_STACK[@]}" -u -sim -p "$SEARCH" \
    -bdir "$BUILD/host-sim" -simdir "$BUILD/host-sim" -info-dir "$BUILD/host-sim" \
    -g mkTbPLIOHostBlockRam "$ROOT/memory-controller/bluespec/TbPLIOHostBlockRam.bsv"
run_bsc bsc-host-link "${BSC_STACK[@]}" -sim -p "$SEARCH" \
    -bdir "$BUILD/host-sim" -simdir "$BUILD/host-sim" \
    -e mkTbPLIOHostBlockRam -o "$BUILD/tb-plio-host-memory"
"$BUILD/tb-plio-host-memory" 2>&1 | tee "$BUILD/host-bsv.log"
grep '^MEMHOSTTRACE|' "$BUILD/host-bsv.log" > "$BUILD/bsv-host-bram.trace"
test "$(wc -l < "$BUILD/bsv-host-bram.trace")" -eq 3
grep -q '^PASS memory controller + PLIO host + FPGA block RAM integration$' "$BUILD/host-bsv.log"

# Backend identity and the legacy BSV trace-version tag are the only textual
# differences. PLIO requests themselves must explicitly report BE=f.
sed -e 's/MEMHOSTTRACE|v1/MEMHOSTTRACE|v2/' -e 's/backend=bram/backend=fake/' \
    "$BUILD/bsv-host-bram.trace" > "$BUILD/bsv-host.trace"
grep -q '|be=f$' "$BUILD/bsv-host.trace"

echo "== Exact Rust / Bluesim default-memory integration =="
diff -u "$BUILD/rust-host.trace" "$BUILD/bsv-host.trace" 2>&1 | tee "$BUILD/host-diff.log"

echo "== Generate and synthesize memory-free controller RTL =="
run_bsc bsc-rtl-compile "${BSC_STACK[@]}" -u -verilog -p "$SEARCH" \
    -bdir "$BUILD/rtl" -vdir "$BUILD/rtl" -info-dir "$BUILD/rtl" \
    -g mkMemoryController "$ROOT/memory-controller/bluespec/MemoryController.bsv"
VERILOG="$BUILD/rtl/mkMemoryController.v"
test -s "$VERILOG"
grep -q '^module mkMemoryController' "$VERILOG"
yosys -p "read_verilog -sv $VERILOG; hierarchy -check -top mkMemoryController; proc; opt; memory; opt; check; stat" 2>&1 | tee "$BUILD/yosys.log"
grep -Eq 'Number of memories:[[:space:]]+0' "$BUILD/yosys.log"
grep -Eq 'Number of memory bits:[[:space:]]+0' "$BUILD/yosys.log"
! grep -Eiq '\$mem(rd|wr|init)|RAMB|SB_RAM' "$VERILOG"

echo "PASS memory controller byte-enable Rust/Bluespec/default-BRAM PLIO integration and synthesis gate"
