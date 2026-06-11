"""PyArrow benchmarks — array construction and string operations."""
import statistics, time
import pyarrow as pa
import pyarrow.compute as pc
import pyarrow.ipc as ipc

N_LARGE  = 10_000_000
N_STRING = 1_000_000
TRIALS   = 5
IPC_BENCH_PATH = "/tmp/py_bench_ipc.arrow"

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

# ── IPC roundtrip ─────────────────────────────────────────────────────────────

def bench_ipc_roundtrip():
    schema = pa.schema([pa.field("v", pa.int32())])
    batch = pa.record_batch([pa.array(range(N_LARGE), type=pa.int32())], schema=schema)
    times = []
    for _ in range(TRIALS):
        t0 = time.perf_counter_ns()
        with pa.OSFile(IPC_BENCH_PATH, "wb") as f:
            w = ipc.new_file(f, schema)
            w.write_batch(batch)
            w.close()
        rd = ipc.open_file(IPC_BENCH_PATH)
        out = rd.get_batch(0)
        times.append(time.perf_counter_ns() - t0)
        _ = out.column("v")[0].as_py()
    return median_ns(times)

if __name__ == "__main__":
    report("array_build_10m_i32",   bench_array_build())
    report("string_build_1m",       bench_string_build())
    report("string_scan_1m",        bench_string_scan())
    report("ipc_roundtrip_10m_i32", bench_ipc_roundtrip())
