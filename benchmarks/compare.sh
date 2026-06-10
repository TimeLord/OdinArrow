#!/usr/bin/env bash
# Run Odin, Python, and Apache Arrow C++ benchmarks.
# Outputs a side-by-side markdown table comparing all three.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "Building Odin benchmark binary..."
odin build "$ROOT/benchmarks/odin" -out:"$ROOT/bin/bench_runner" -o:speed

echo "Running Odin benchmarks..."
ODIN_OUT=$("$ROOT/bin/bench_runner")

echo "Running Python benchmarks (array)..."
PY_ARRAY=$(python3 "$ROOT/benchmarks/python/bench_array.py")

echo "Running Python benchmarks (compute)..."
PY_COMPUTE=$(python3 "$ROOT/benchmarks/python/bench_compute.py")

echo "Running Arrow C++ benchmarks..."
CPP_OUT=$("$ROOT/bin/bench_arrow_cpp")

PY_OUT="${PY_ARRAY}
${PY_COMPUTE}"

# Parse key=value lines into associative arrays
declare -A odin_ns py_ns cpp_ns

while IFS='=' read -r key val; do
    [[ -z "$key" ]] && continue
    odin_ns["$key"]="$val"
done <<< "$ODIN_OUT"

while IFS='=' read -r key val; do
    [[ -z "$key" ]] && continue
    py_ns["$key"]="$val"
done <<< "$PY_OUT"

while IFS='=' read -r key val; do
    [[ -z "$key" ]] && continue
    cpp_ns["$key"]="$val"
done <<< "$CPP_OUT"

KEYS=(
    array_build_10m_i32
    sum_10m_f64
    sum_10m_f64_mt
    sum_10m_i32
    sum_10m_i32_mt
    min_max_10m_i32
    min_max_10m_i32_mt
    filter_10m_i32
    filter_10m_i32_mt
    string_build_1m
    string_scan_1m
)

LABELS=(
    "Build 10M i32 (1% nulls)"
    "Sum 10M f64"
    "Sum 10M f64 (threaded)"
    "Sum 10M i32"
    "Sum 10M i32 (threaded)"
    "Min+Max 10M i32"
    "Min+Max 10M i32 (threaded)"
    "Filter 10M i32 (50% pass)"
    "Filter 10M i32 (threaded)"
    "Build 1M strings (2% nulls)"
    "Scan 1M strings"
)

ns_to_ms() { echo "scale=2; $1 / 1000000" | bc; }

ratio() {
    local ref="$1" cmp="$2"
    if [[ "$cmp" -eq 0 || "$ref" -eq 0 ]]; then echo "N/A"; return; fi
    local r
    r=$(echo "scale=2; $ref / $cmp" | bc)
    [[ "$r" == .* ]] && r="0${r}"
    echo "${r}x"
}

echo ""
echo "## OdinArrow vs PyArrow vs Apache Arrow C++ Benchmark Results"
echo ""
printf "| %-30s | %10s | %10s | %10s | %8s | %8s |\n" \
    "Benchmark" "Odin (ms)" "Python (ms)" "ArrowC++ (ms)" "Py/Odin" "C++/Odin"
printf "|%-32s|%12s|%12s|%14s|%10s|%10s|\n" \
    "$(printf '%0.s-' {1..32})" \
    "$(printf '%0.s-' {1..12})" \
    "$(printf '%0.s-' {1..12})" \
    "$(printf '%0.s-' {1..14})" \
    "$(printf '%0.s-' {1..10})" \
    "$(printf '%0.s-' {1..10})"

for i in "${!KEYS[@]}"; do
    key="${KEYS[$i]}"
    label="${LABELS[$i]}"
    od="${odin_ns[$key]:-0}"
    py="${py_ns[$key]:-0}"
    cpp="${cpp_ns[$key]:-0}"

    od_ms=$(ns_to_ms "$od")
    py_ms=$(ns_to_ms "$py")
    cpp_ms=$(ns_to_ms "$cpp")

    r_py=$(ratio "$py" "$od")
    r_cpp=$(ratio "$cpp" "$od")

    printf "| %-30s | %10s | %10s | %13s | %8s | %8s |\n" \
        "$label" "$od_ms" "$py_ms" "$cpp_ms" "$r_py" "$r_cpp"
done

echo ""
echo "_Py/Odin and C++/Odin: Python or C++ time divided by Odin time._"
echo "_Values > 1x mean Odin is faster; < 1x mean Odin is slower._"
