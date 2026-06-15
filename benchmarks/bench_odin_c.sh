#!/usr/bin/env bash
# Single-threaded head-to-head: OdinArrow vs Apache Arrow C++.
#
# Builds and runs the paired benchmarks in benchmarks/odin_c (Odin) and
# benchmarks/cpp/bench_odin_c.cpp (C++), both emitting `key=nanoseconds` lines
# (median of TRIALS). Parses them into a side-by-side markdown table.
#
# Both sides are single-threaded (the serial compute_* kernels) so this isolates
# per-core implementation efficiency. For the threaded story see compare.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/bin"

# Apache Arrow C++ paths — resolved from the bundled PyArrow installation
# (mirrors the Makefile).
ARROW_IDIR="$(python3 -c "import pyarrow; print(pyarrow.get_include())")"
ARROW_LDIR="$(python3 -c "import pyarrow; print(pyarrow.get_library_dirs()[0])")"
ARROW_VER="2400"

echo "Building OdinArrow benchmark binary..."
odin build "$ROOT/benchmarks/odin_c" -out:"$ROOT/bin/bench_odin_c_odin" -o:speed

echo "Building Arrow C++ benchmark binary..."
g++ -std=c++20 -O3 -I"$ARROW_IDIR" \
    "$ROOT/benchmarks/cpp/bench_odin_c.cpp" \
    -L"$ARROW_LDIR" \
    -l:libarrow.so.$ARROW_VER \
    -l:libarrow_compute.so.$ARROW_VER \
    -Wl,-rpath,"$ARROW_LDIR" \
    -o "$ROOT/bin/bench_odin_c_cpp"

echo "Running OdinArrow benchmarks (single-threaded)..."
ODIN_OUT=$("$ROOT/bin/bench_odin_c_odin")

echo "Running Arrow C++ benchmarks (single-threaded)..."
CPP_OUT=$("$ROOT/bin/bench_odin_c_cpp")

# Parse key=value lines into associative arrays
declare -A odin_ns cpp_ns

while IFS='=' read -r key val; do
    [[ -z "$key" ]] && continue
    odin_ns["$key"]="$val"
done <<< "$ODIN_OUT"

while IFS='=' read -r key val; do
    [[ -z "$key" ]] && continue
    cpp_ns["$key"]="$val"
done <<< "$CPP_OUT"

# Keys in report() order; both sides emit the identical set.
KEYS=(
    build_i32_10m
    build_str_1m
    sum_f64_10m
    sum_f64_nulls_10m
    minmax_i32_10m
    mean_f64_10m
    filter_i32_10m_50
    filter_i32_10m_1
    take_i32_10m
    sort_i32_1m
    cast_i32_f64_10m
    add_i32_10m
    compare_f64_10m
    scan_str_1m
    sumwhere_f64_10m
    valuecounts_str_10m
    ipc_roundtrip_i32_10m
)

LABELS=(
    "Build 10M i32 (1% nulls)"
    "Build 1M strings (2% nulls)"
    "Sum 10M f64"
    "Sum 10M f64 (1% nulls)"
    "Min+Max 10M i32"
    "Mean 10M f64"
    "Filter 10M i32 (50%)"
    "Filter 10M i32 (1%)"
    "Take 10M i32 (1M idx)"
    "Sort indices 1M i32"
    "Cast 10M i32 -> f64"
    "Add 10M i32"
    "Compare 10M f64 > k"
    "Scan 1M strings"
    "Sum-where 10M f64 (50%)"
    "Value counts 10M str (100 distinct)"
    "IPC roundtrip 10M i32 (w+r)"
)

ns_to_ms() { awk -v n="$1" 'BEGIN { printf "%.2f", n / 1000000 }'; }

ratio() {
    local ref="$1" cmp="$2"
    if [[ "$cmp" -eq 0 || "$ref" -eq 0 ]]; then echo "N/A"; return; fi
    awk -v r="$ref" -v c="$cmp" 'BEGIN { printf "%.2fx", r / c }'
}

echo ""
echo "## OdinArrow vs Apache Arrow C++ (single-threaded) Benchmark Results"
echo ""
printf "| %-37s | %12s | %13s | %9s |\n" \
    "Benchmark" "Odin (ms)" "ArrowC++ (ms)" "C++/Odin"
printf "|%-39s|%14s|%15s|%11s|\n" \
    "$(printf '%0.s-' {1..39})" \
    "$(printf '%0.s-' {1..14})" \
    "$(printf '%0.s-' {1..15})" \
    "$(printf '%0.s-' {1..11})"

for i in "${!KEYS[@]}"; do
    key="${KEYS[$i]}"
    label="${LABELS[$i]}"
    od="${odin_ns[$key]:-0}"
    cpp="${cpp_ns[$key]:-0}"

    od_ms=$(ns_to_ms "$od")
    cpp_ms=$(ns_to_ms "$cpp")
    r_cpp=$(ratio "$cpp" "$od")

    printf "| %-37s | %12s | %13s | %9s |\n" \
        "$label" "$od_ms" "$cpp_ms" "$r_cpp"
done

echo ""
echo "_C++/Odin: Arrow C++ time divided by OdinArrow time._"
echo "_Values > 1x mean OdinArrow is faster; < 1x mean it is slower._"
echo "_Both sides single-threaded (serial kernels) for per-core comparison._"
