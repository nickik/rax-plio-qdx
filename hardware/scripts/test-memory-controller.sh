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
    if [[ -f "$file" ]]; then
        nl -ba "$file"
    else
        echo "missing: $file"
    fi
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
        printf 'cwd=%s\n' "$PWD"
        printf 'root=%s\n' "$ROOT"
        printf 'build=%s\n' "$BUILD"
        printf 'search=%s\n' "$SEARCH"
        echo
        echo "--- git ---"
        git -C "$ROOT/.." rev-parse HEAD 2>&1 || true
        git -C "$ROOT/.." status --short 2>&1 || true
        git -C "$ROOT/.." diff -- hardware/memory-controller hardware/scripts/test-memory-controller.sh .github/workflows/hardware-bluespec.yml 2>&1 || true
        echo
        echo "--- host / tools ---"
        uname -a 2>&1 || true
        printf 'bsc='; command -v "$BSC" 2>&1 || true
        "$BSC" -version 2>&1 || true
        printf 'cargo='; command -v cargo 2>&1 || true
        cargo --version 2>&1 || true
        printf 'rustc='; command -v rustc 2>&1 || true
        rustc --version 2>&1 || true
        printf 'yosys='; command -v yosys 2>&1 || true
        yosys -V 2>&1 || true
        echo
        echo "--- relevant environment ---"
        env | grep -E '^(BSC|BLUESPEC|PATH=|MEMORY_CONTROLLER_DEBUG_DIR=|RUNNER_|GITHUB_|TMPDIR=)' | sort || true
        echo
        echo "--- Bluespec sources ---"
        print_file "$ROOT/memory-controller/bluespec/MemoryController.bsv"
        print_file "$ROOT/memory-controller/bluespec/TbMemoryController.bsv"
        print_file "$ROOT/memory-controller/bluespec/TbPLIOHostMemory.bsv"
        echo
        echo "--- source directory ---"
        find "$ROOT/memory-controller/bluespec" -maxdepth 1 -type f -printf '%f\t%s bytes\n' | sort || true
        echo
        echo "--- generated artifacts ---"
        find "$BUILD" -maxdepth 6 -type f -printf '%p\t%s bytes\n' | sort || true
        echo
        echo "--- compiler / simulator / synthesis logs ---"
        while IFS= read -r log; do
            echo "===== $log ====="
            cat "$log" || true
        done < <(find "$BUILD" -type f \( -name '*.log' -o -name '*.trace' \) | sort)
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
    printf 'BSC COMMAND:'
    printf ' %q' "$BSC" "$@"
    printf '\n'
    set +e
    "$BSC" "$@" 2>&1 | tee "$log"
    local bsc_status=${PIPESTATUS[0]}
    set -e
    if (( bsc_status != 0 )); then
        return "$bsc_status"
    fi
}

command -v "$BSC" >/dev/null
command -v cargo >/dev/null
command -v yosys >/dev/null

echo "== Diagnostic context =="
git -C "$ROOT/.." rev-parse HEAD
"$BSC" -version || true
cargo --version
yosys -V
printf 'Bluespec search path: %s\n' "$SEARCH"
printf 'Diagnostic build directory: %s\n' "$BUILD"

echo "== Memory controller Rust reference =="
cargo test --manifest-path "$ROOT/Cargo.toml" -p memory-controller-model --all-targets 2>&1 | tee "$BUILD/rust-tests.log"
cargo run --quiet --manifest-path "$ROOT/Cargo.toml" -p memory-controller-model --bin conformance 2>&1 | tee "$BUILD/rust.log"
grep '^MEMCTRLTRACE|' "$BUILD/rust.log" > "$BUILD/rust-controller.trace"
grep '^MEMHOSTTRACE|' "$BUILD/rust.log" > "$BUILD/rust-host.trace"
test "$(wc -l < "$BUILD/rust-controller.trace")" -eq 12
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
test "$(wc -l < "$BUILD/bsv-controller.trace")" -eq 12
grep -q '^PASS memory controller Bluespec deterministic semantics$' "$BUILD/controller-bsv.log"

echo "== Exact Rust / Bluesim memory-controller trace =="
diff -u "$BUILD/rust-controller.trace" "$BUILD/bsv-controller.trace" 2>&1 | tee "$BUILD/controller-diff.log"

echo "== PLIOHostCore -> MemoryController -> fake RAM Bluesim integration =="
run_bsc bsc-host-compile "${BSC_STACK[@]}" -u -sim -p "$SEARCH" \
    -bdir "$BUILD/host-sim" -simdir "$BUILD/host-sim" -info-dir "$BUILD/host-sim" \
    -g mkTbPLIOHostMemory "$ROOT/memory-controller/bluespec/TbPLIOHostMemory.bsv"
run_bsc bsc-host-link "${BSC_STACK[@]}" -sim -p "$SEARCH" \
    -bdir "$BUILD/host-sim" -simdir "$BUILD/host-sim" \
    -e mkTbPLIOHostMemory -o "$BUILD/tb-plio-host-memory"
"$BUILD/tb-plio-host-memory" 2>&1 | tee "$BUILD/host-bsv.log"
grep '^MEMHOSTTRACE|' "$BUILD/host-bsv.log" > "$BUILD/bsv-host.trace"
test "$(wc -l < "$BUILD/bsv-host.trace")" -eq 3
grep -q '^PASS memory controller Bluespec + PLIO host integration$' "$BUILD/host-bsv.log"

echo "== Exact Rust / Bluesim PLIO-host memory integration =="
diff -u "$BUILD/rust-host.trace" "$BUILD/bsv-host.trace" 2>&1 | tee "$BUILD/host-diff.log"

echo "== Generate and synthesize memory-free controller RTL =="
run_bsc bsc-rtl-compile "${BSC_STACK[@]}" -u -verilog -p "$SEARCH" \
    -bdir "$BUILD/rtl" -vdir "$BUILD/rtl" -info-dir "$BUILD/rtl" \
    -g mkMemoryController "$ROOT/memory-controller/bluespec/MemoryController.bsv"
VERILOG="$BUILD/rtl/mkMemoryController.v"
test -s "$VERILOG"
grep -q '^module mkMemoryController' "$VERILOG"
yosys -p "read_verilog -sv $VERILOG; hierarchy -check -top mkMemoryController; proc; opt; memory; opt; check; stat" 2>&1 \
    | tee "$BUILD/yosys.log"
grep -Eq 'Number of memories:[[:space:]]+0' "$BUILD/yosys.log"
grep -Eq 'Number of memory bits:[[:space:]]+0' "$BUILD/yosys.log"
! grep -Eiq '\$mem(rd|wr|init)|RAMB|SB_RAM' "$VERILOG"

echo "PASS memory controller Rust/Bluespec/PLIO integration and synthesis gate"
