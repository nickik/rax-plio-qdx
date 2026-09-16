#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/qic-phase8"
SEARCH="+:$ROOT/qli/bluespec:$ROOT/naked-card/bluespec:$ROOT/qli16/bluespec:$ROOT/pti/bluespec:$ROOT/trace/bluespec:$ROOT/qic/bluespec"

rm -rf "$BUILD"
mkdir -p "$BUILD"
command -v bsc >/dev/null
command -v cargo >/dev/null
command -v python3 >/dev/null

bsc -u -sim -p "$SEARCH" -bdir "$BUILD" -simdir "$BUILD" -info-dir "$BUILD" -g mkTbQICPhase8 "$ROOT/qic/bluespec/TbQICPhase8.bsv"
bsc -sim -p "$SEARCH" -bdir "$BUILD" -simdir "$BUILD" -e mkTbQICPhase8 -o "$BUILD/tb-qic-phase8"
"$BUILD/tb-qic-phase8" | tee "$BUILD/phase8-bsv.log"
if grep -q '^FAIL ' "$BUILD/phase8-bsv.log"; then
    echo "QIC Phase8 Bluesim fixture reported a failure" >&2
    exit 1
fi
grep '^TRACE|' "$BUILD/phase8-bsv.log" > "$BUILD/phase8-bsv.trace"
grep '^QICDBG|' "$BUILD/phase8-bsv.log" > "$BUILD/phase8-bsv.debug"

cargo run --quiet --manifest-path "$ROOT/Cargo.toml" -p plio-qic-model --bin phase8_conformance \
    | tee "$BUILD/phase8-rust.log" >/dev/null
grep '^TRACE|' "$BUILD/phase8-rust.log" > "$BUILD/phase8-rust.trace"
grep '^QICDBG|' "$BUILD/phase8-rust.log" > "$BUILD/phase8-rust.debug"

if ! diff -u "$BUILD/phase8-rust.trace" "$BUILD/phase8-bsv.trace" > "$BUILD/phase8.diff"; then
    first_line="$(paste "$BUILD/phase8-rust.trace" "$BUILD/phase8-bsv.trace" | awk -F '\t' '$1 != $2 { print NR; exit }')"
    if [[ -n "$first_line" ]]; then
        cycle=$((first_line - 1))
        printf -v cycle_hex '%08x' "$cycle"
        case "$cycle" in
            [0-9]|1[0-9]|2[0-9]) scenario="worker MMIO widths" ;;
            3[0-9]|4[0-9]|5[0-3]) scenario="notification baseline" ;;
            5[4-9]|6[0-2]) scenario="manager priority / grant-epoch reuse" ;;
            6[3-9]|[7-9][0-9]|1[0-3][0-9]|140) scenario="host-to-device DMA bursts" ;;
            14[1-9]|1[5-9][0-9]|20[0-9]|21[0-8]) scenario="device-to-host DMA bursts" ;;
            219|22[0-9]|23[0-9]|24[0-9]|25[0-9]|26[0-9]|27[0-9]|28[0-9]|29[0-9]|3[0-9][0-9]|4[0-8][0-9]|49[0-5]) scenario="DMA error / timeout paths" ;;
            49[6-9]|[5-9][0-9][0-9]|100[0-9]|101[0-5]) scenario="worker timeout / recovery" ;;
            *) scenario="notification grant / retry boundary" ;;
        esac
        echo "FAIL QIC Phase8 first interface divergence at trace line $first_line, cycle 0x$cycle_hex ($scenario)" >&2
        echo "Exact differing interface fields:" >&2
        python3 - "$BUILD/phase8-rust.trace" "$BUILD/phase8-bsv.trace" "$first_line" <<'PY' >&2
import sys

rust_path, bsv_path, line_no_s = sys.argv[1:]
line_no = int(line_no_s)
with open(rust_path, encoding="utf-8") as f:
    rust = next(line for i, line in enumerate(f, 1) if i == line_no).strip()
with open(bsv_path, encoding="utf-8") as f:
    bsv = next(line for i, line in enumerate(f, 1) if i == line_no).strip()

names = {
    "pi": ["reset","selected","grant","ad_valid","ad","par_valid","par","space_valid","space","address_strobe","read","byte_enable","burst","data_strobe","ack","err"],
    "qi": ["mmio_ready","mmio_response_valid","mmio_kind","mmio_data","dma_request_valid","dma_direction","dma_address","dma_words","dma_read_ready","dma_write_valid","dma_write_data","dma_completion_ready","notification_valid","notification_channel"],
    "po": ["request","ad_valid","ad","par_valid","par","space_valid","space","address_strobe","read","byte_enable","burst","data_strobe","ack","err"],
    "qo": ["reset","mmio_request_valid","mmio_request_address","mmio_request_write","mmio_request_be","mmio_request_write_data","mmio_response_ready","mmio_cancel","dma_request_ready","dma_read_valid","dma_read_data","dma_write_ready","dma_completion_valid","dma_status","dma_words_completed","notification_ready"],
}

def groups(line):
    out = {}
    for part in line.split("|"):
        if "=" in part:
            key, value = part.split("=", 1)
            out[key] = value
    return out

rg, bg = groups(rust), groups(bsv)
found = False
for group, fields in names.items():
    rv = rg[group].split(".")
    bv = bg[group].split(".")
    for index, (r, b) in enumerate(zip(rv, bv)):
        if r != b:
            label = fields[index] if index < len(fields) else f"field_{index}"
            print(f"  {group}.{label}: rust={r} bsv={b}")
            found = True
if not found:
    print("  no decoded field difference; inspect raw TRACE context")
PY
        start=$((first_line > 3 ? first_line - 3 : 1))
        end=$((first_line + 3))
        echo "Rust state context (cycles $((start-1))..$((end-1))):" >&2
        sed -n "${start},${end}p" "$BUILD/phase8-rust.debug" >&2 || true
        echo "Bluespec state context (cycles $((start-1))..$((end-1))):" >&2
        sed -n "${start},${end}p" "$BUILD/phase8-bsv.debug" >&2 || true
        echo "Rust interface context:" >&2
        sed -n "${start},${end}p" "$BUILD/phase8-rust.trace" >&2 || true
        echo "Bluespec interface context:" >&2
        sed -n "${start},${end}p" "$BUILD/phase8-bsv.trace" >&2 || true
    fi
    echo "First Phase8 trace diff hunk:" >&2
    sed -n '1,120p' "$BUILD/phase8.diff" >&2
    exit 1
fi

test "$(wc -l < "$BUILD/phase8-rust.trace")" -eq 1028
echo "PASS QIC Phase8 unified Rust/Bluesim differential trace (1028 cycles)"
