"""PyArrow benchmarks — compute kernels."""
import statistics, time
import pyarrow as pa
import pyarrow.compute as pc

N_LARGE = 10_000_000
TRIALS  = 5

def median_ns(times_ns):
    return statistics.median(times_ns)

def report(key, ns):
    print(f"{key}={int(ns)}")

# ── sum ───────────────────────────────────────────────────────────────────────

def bench_sum_f64():
    arr = pa.array([i * 0.001 for i in range(N_LARGE)], type=pa.float64())
    times = []
    for _ in range(TRIALS):
        t0 = time.perf_counter_ns()
        pc.sum(arr)
        times.append(time.perf_counter_ns() - t0)
    return median_ns(times)

def bench_sum_i32():
    arr = pa.array(range(N_LARGE), type=pa.int32())
    times = []
    for _ in range(TRIALS):
        t0 = time.perf_counter_ns()
        pc.sum(arr)
        times.append(time.perf_counter_ns() - t0)
    return median_ns(times)

# ── min / max ─────────────────────────────────────────────────────────────────

def bench_min_max_i32():
    arr = pa.array(range(N_LARGE, 0, -1), type=pa.int32())
    times = []
    for _ in range(TRIALS):
        t0 = time.perf_counter_ns()
        pc.min(arr)
        pc.max(arr)
        times.append(time.perf_counter_ns() - t0)
    return median_ns(times)

# ── filter ────────────────────────────────────────────────────────────────────

def bench_filter_i32():
    arr  = pa.array(range(N_LARGE), type=pa.int32())
    mask = pa.array([i % 2 == 0 for i in range(N_LARGE)], type=pa.bool_())
    times = []
    for _ in range(TRIALS):
        t0 = time.perf_counter_ns()
        result = pc.filter(arr, mask)
        times.append(time.perf_counter_ns() - t0)
        del result
    return median_ns(times)

if __name__ == "__main__":
    report("sum_10m_f64",     bench_sum_f64())
    report("sum_10m_i32",     bench_sum_i32())
    report("min_max_10m_i32", bench_min_max_i32())
    report("filter_10m_i32",  bench_filter_i32())
