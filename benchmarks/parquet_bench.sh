#!/usr/bin/env bash
# Benchmark parquet → CSV conversion: pure-Odin vs Arrow C++ FFI vs PyArrow.
# Usage: bash benchmarks/parquet_bench.sh <input.parquet>
set -euo pipefail

PARQUET="${1:-$HOME/Work/Projects/Odin/test_data.parquet}"
TRIALS=3
OUT=/dev/null   # discard CSV output; we time the conversion only

echo "=== Parquet → CSV benchmark ==="
echo "file:   $PARQUET"
echo "trials: $TRIALS"
echo

run_median() {
    local cmd=("$@")
    local times=()
    for _ in $(seq "$TRIALS"); do
        local t0 t1 ms
        t0=$(date +%s%N)
        "${cmd[@]}" > "$OUT" 2>/dev/null
        t1=$(date +%s%N)
        ms=$(( (t1 - t0) / 1000000 ))
        times+=("$ms")
    done
    # simple sort + pick middle
    IFS=$'\n' sorted=($(sort -n <<<"${times[*]}")); unset IFS
    echo "${sorted[$((TRIALS / 2))]}"
}

# ── Odin (pure) ───────────────────────────────────────────────────────────────
printf "Odin (pure)   ... "
odin_ms=$(run_median bin/parquet_to_csv_odin "$PARQUET" -)
printf "%d ms\n" "$odin_ms"

# ── Arrow C++ FFI ─────────────────────────────────────────────────────────────
printf "Arrow C++ FFI ... "
ffi_ms=$(run_median bin/parquet_to_csv_ffi "$PARQUET" -)
printf "%d ms\n" "$ffi_ms"

# ── PyArrow ───────────────────────────────────────────────────────────────────
printf "PyArrow       ... "
pyarrow_ms=$(run_median python3 -c "
import pyarrow.parquet as pq, pyarrow.csv as csv, sys, io
t = pq.read_table('$PARQUET')
buf = io.BytesIO()
csv.write_csv(t, buf)
sys.stdout.buffer.write(buf.getvalue())
")
printf "%d ms\n" "$pyarrow_ms"

echo
echo "| Implementation | ms (median) | vs Odin |"
echo "|----------------|-------------|---------|"

ratio_ffi=$(echo "scale=2; $ffi_ms / $odin_ms" | bc)
[[ "$ratio_ffi" == .* ]] && ratio_ffi="0${ratio_ffi}"

ratio_py=$(echo "scale=2; $pyarrow_ms / $odin_ms" | bc)
[[ "$ratio_py"  == .* ]] && ratio_py="0${ratio_py}"

printf "| %-14s | %11d | %7.2fx |\n" "Odin (pure)"   "$odin_ms"    "1.00"
printf "| %-14s | %11d | %7sx |\n"  "Arrow C++ FFI" "$ffi_ms"     "$ratio_ffi"
printf "| %-14s | %11d | %7sx |\n"  "PyArrow"       "$pyarrow_ms" "$ratio_py"
