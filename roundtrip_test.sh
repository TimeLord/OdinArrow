#!/usr/bin/env bash
# Round-trip integration test: CSV → Parquet → CSV for both FFI (Arrow C++) and
# native Odin pipelines.
#
# Generates 1 000 000 rows × 10 string fields, converts both ways with each
# pipeline, checks that every output matches the original CSV, and prints a
# timing comparison.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$ROOT/tmp_roundtrip"
mkdir -p "$WORK"

CSV_IN="$WORK/input.csv"
FFI_PARQUET="$WORK/ffi.parquet"
ODIN_PARQUET="$WORK/odin.parquet"
FFI_OUT="$WORK/ffi_output.csv"
ODIN_OUT="$WORK/odin_output.csv"

now_ms() { date +%s%3N; }

# ── Step 1: generate CSV ──────────────────────────────────────────────────────
echo "Generating 1 000 000 rows × 10 fields..."

python3 - "$CSV_IN" <<'PYEOF'
import sys

out_path = sys.argv[1]
N = 1_000_000

# All pools chosen so no value matches Arrow's auto-detect patterns
# (int, float, bool, ISO-8601 date/timestamp).
CITIES    = ["London","Paris","Tokyo","Berlin","Sydney","Toronto","Dubai","Singapore","Seoul","Amsterdam"]
COUNTRIES = ["GB","FR","JP","DE","AU","CA","AE","SG","KR","NL"]
DEPTS     = ["Engineering","Sales","HR","Finance","Marketing","Operations","Legal","IT","Support","Research"]
JOBTYPES  = ["fulltime","parttime","contract","intern","consultant","freelance","temporary"]
STATUSES  = ["ACTIVE","INACTIVE","PENDING","SUSPENDED","ONLEAVE"]

with open(out_path, "w") as f:
    f.write("id,username,email,city,country,department,jobtype,code,period,status\n")
    for i in range(1, N + 1):
        row = ",".join([
            f"R{i:07d}",                                  # string ID
            f"user_{i % 10000:05d}",                      # username
            f"u{i}@corp.example",                         # email
            CITIES[i % len(CITIES)],
            COUNTRIES[i % len(COUNTRIES)],
            DEPTS[i % len(DEPTS)],
            JOBTYPES[i % len(JOBTYPES)],
            f"C{i % 1000:03d}-{chr(i % 26 + ord('A'))}", # code like C007-B
            f"P{(i // 4) % 100:02d}Q{i % 4 + 1}",       # period like P03Q2
            STATUSES[i % len(STATUSES)],
        ])
        f.write(row + "\n")
PYEOF
echo "  → $CSV_IN"
wc -l "$CSV_IN" | awk '{printf "  → %d lines (header + %d data rows)\n", $1, $1-1}'

# ── Step 2: build binaries ────────────────────────────────────────────────────
echo ""
echo "Building binaries..."
make -C "$ROOT" csv-to-parquet-ffi parquet-ffi csv-to-parquet-odin parquet-odin \
    2>&1 | grep -vE '^make\[|^$' | sed 's/^/  /' || true

# ── Step 3: FFI pipeline ──────────────────────────────────────────────────────
echo ""
echo "=== FFI pipeline (Arrow C++) ==="

t0=$(now_ms)
"$ROOT/bin/csv_to_parquet_ffi"  "$CSV_IN"       "$FFI_PARQUET" 2>&1 \
    | grep -E 'total_ms|rows' | sed 's/^/  /'
t1=$(now_ms)
"$ROOT/bin/parquet_to_csv_ffi"  "$FFI_PARQUET"  "$FFI_OUT"     2>&1 \
    | grep -E 'total_ms|rows' | sed 's/^/  /'
t2=$(now_ms)

ffi_write_ms=$(( t1 - t0 ))
ffi_read_ms=$(( t2 - t1 ))
ffi_total_ms=$(( t2 - t0 ))
printf "  wall: csv→parquet=%dms  parquet→csv=%dms  total=%dms\n" \
    "$ffi_write_ms" "$ffi_read_ms" "$ffi_total_ms"

# ── Step 4: Odin pipeline ─────────────────────────────────────────────────────
echo ""
echo "=== Odin pipeline (native) ==="

t0=$(now_ms)
"$ROOT/bin/csv_to_parquet_odin"  "$CSV_IN"        "$ODIN_PARQUET" 2>&1 \
    | grep -E 'total_ms|rows' | sed 's/^/  /'
t1=$(now_ms)
"$ROOT/bin/parquet_to_csv_odin"  "$ODIN_PARQUET"  "$ODIN_OUT"     2>&1 \
    | grep -E 'total_ms|rows' | sed 's/^/  /'
t2=$(now_ms)

odin_write_ms=$(( t1 - t0 ))
odin_read_ms=$(( t2 - t1 ))
odin_total_ms=$(( t2 - t0 ))
printf "  wall: csv→parquet=%dms  parquet→csv=%dms  total=%dms\n" \
    "$odin_write_ms" "$odin_read_ms" "$odin_total_ms"

# ── Step 5: correctness ───────────────────────────────────────────────────────
echo ""
echo "=== Correctness ==="

pass=true

# CSV-aware comparison: reads both files with Python's csv module so quoting
# differences (Arrow 24 quotes all strings; Odin does not) don't cause false
# failures.  Only actual field-value differences are reported.
check_csv() {
    local label="$1" a="$2" b="$3"
    local result
    result=$(python3 - "$a" "$b" <<'PYEOF'
import csv, sys

def read(path):
    with open(path, newline="") as f:
        return list(csv.reader(f))

a_rows = read(sys.argv[1])
b_rows = read(sys.argv[2])

if len(a_rows) != len(b_rows):
    print(f"row count: {len(a_rows)} vs {len(b_rows)}")
    sys.exit(1)

diffs = []
for i, (ra, rb) in enumerate(zip(a_rows, b_rows)):
    if ra != rb:
        diffs.append((i + 1, ra, rb))
        if len(diffs) >= 4:
            break

if diffs:
    for lineno, ra, rb in diffs:
        print(f"  line {lineno}: {ra[:3]} != {rb[:3]}")
    if len(a_rows) - len(diffs) > 0:
        total_diffs = sum(1 for ra, rb in zip(a_rows, b_rows) if ra != rb)
        print(f"  ({total_diffs} differing rows total)")
    sys.exit(1)
PYEOF
)
    if [ $? -eq 0 ]; then
        printf "  [PASS] %s\n" "$label"
    else
        printf "  [FAIL] %s\n" "$label"
        echo "$result" | sed 's/^/         /'
        pass=false
    fi
}

check_csv "FFI round-trip  == input"   "$CSV_IN" "$FFI_OUT"
check_csv "Odin round-trip == input"   "$CSV_IN" "$ODIN_OUT"
check_csv "FFI output      == Odin"    "$FFI_OUT" "$ODIN_OUT"

# ── Step 6: timing summary ────────────────────────────────────────────────────
echo ""
echo "=== Timing summary ==="
printf "  %-22s  %12s  %12s  %12s\n" "Pipeline" "csv→parquet" "parquet→csv" "total"
printf "  %-22s  %12s  %12s  %12s\n" "──────────────────────" "────────────" "────────────" "────────────"
printf "  %-22s  %11dms  %11dms  %11dms\n" \
    "FFI (Arrow C++)"  "$ffi_write_ms"  "$ffi_read_ms"  "$ffi_total_ms"
printf "  %-22s  %11dms  %11dms  %11dms\n" \
    "Odin (native)"    "$odin_write_ms" "$odin_read_ms" "$odin_total_ms"

if ! $pass; then
    echo ""
    echo "RESULT: FAIL"
    exit 1
fi
echo ""
echo "RESULT: PASS"
