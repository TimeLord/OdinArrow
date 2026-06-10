"""PyArrow benchmarks — array construction and string operations."""
import statistics, time
import pyarrow as pa
import pyarrow.compute as pc

N_LARGE  = 10_000_000
N_STRING = 1_000_000
TRIALS   = 5

def median_ns(times_ns):
    return statistics.median(times_ns)

def report(key, ns):
    print(f"{key}={int(ns)}")

# ── array build ───────────────────────────────────────────────────────────────

def bench_array_build():
    times = []
    for _ in range(TRIALS):
        t0 = time.perf_counter_ns()
        vals = [None if i % 100 == 0 else i for i in range(N_LARGE)]
        arr = pa.array(vals, type=pa.int32())
        times.append(time.perf_counter_ns() - t0)
        del arr, vals
    return median_ns(times)

# ── string build ──────────────────────────────────────────────────────────────

def bench_string_build():
    times = []
    for _ in range(TRIALS):
        t0 = time.perf_counter_ns()
        vals = [None if i % 50 == 0 else "hello_world" for i in range(N_STRING)]
        arr = pa.array(vals, type=pa.utf8())
        times.append(time.perf_counter_ns() - t0)
        del arr, vals
    return median_ns(times)

# ── string scan ───────────────────────────────────────────────────────────────

def bench_string_scan():
    vals = ["hello_world"] * N_STRING
    arr = pa.array(vals, type=pa.utf8())
    times = []
    for _ in range(TRIALS):
        t0 = time.perf_counter_ns()
        lengths = pc.utf8_length(arr)
        total = pc.sum(lengths).as_py()
        times.append(time.perf_counter_ns() - t0)
    _ = total
    return median_ns(times)

if __name__ == "__main__":
    report("array_build_10m_i32", bench_array_build())
    report("string_build_1m",     bench_string_build())
    report("string_scan_1m",      bench_string_scan())
