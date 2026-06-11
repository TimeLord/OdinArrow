/* Standalone Apache Arrow C++ benchmark.
 * Outputs key=nanoseconds on stdout (one per line), same format as the Odin
 * and Python benchmarks so compare.sh can parse all three.
 */
#include <arrow/api.h>
#include <arrow/compute/api.h>
#include <arrow/io/file.h>
#include <arrow/ipc/api.h>

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <string>
#include <vector>

// Explicit kernel registration (PyArrow-bundled Arrow doesn't auto-register)
namespace arrow { namespace compute { namespace internal {
    void RegisterScalarAggregateBasic(FunctionRegistry*);
    void RegisterScalarStringUtf8(FunctionRegistry*);
}}}

static constexpr int     N_LARGE  = 10'000'000;
static constexpr int     N_STRING = 1'000'000;
static constexpr int     TRIALS   = 5;
static constexpr double  SINK_INIT = 0.0;

static double g_sink = SINK_INIT;  // prevent DCE

using Clock = std::chrono::steady_clock;
using ns_t  = long long;

static ns_t now_ns() {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(
        Clock::now().time_since_epoch()).count();
}

static ns_t median(std::vector<ns_t> v) {
    std::nth_element(v.begin(), v.begin() + v.size() / 2, v.end());
    return v[v.size() / 2];
}

static void report(const char* key, ns_t ns) {
    std::printf("%s=%lld\n", key, ns);
}

// ── array build ───────────────────────────────────────────────────────────────

static ns_t bench_array_build() {
    auto t0 = now_ns();

    arrow::Int32Builder b;
    for (int i = 0; i < N_LARGE; ++i) {
        if (i % 100 == 0)
            (void)b.AppendNull();
        else
            (void)b.Append(i);
    }
    std::shared_ptr<arrow::Array> arr;
    (void)b.Finish(&arr);
    g_sink += static_cast<double>(arr->length());

    return now_ns() - t0;
}

// ── sum ───────────────────────────────────────────────────────────────────────

static ns_t bench_sum_f64() {
    arrow::DoubleBuilder b;
    for (int i = 0; i < N_LARGE; ++i)
        (void)b.Append(i * 0.001);
    std::shared_ptr<arrow::Array> arr;
    (void)b.Finish(&arr);

    auto t0 = now_ns();
    auto res = arrow::compute::Sum(arr).ValueOrDie();
    g_sink += res.scalar_as<arrow::DoubleScalar>().value;
    return now_ns() - t0;
}

static ns_t bench_sum_i32() {
    arrow::Int32Builder b;
    for (int i = 0; i < N_LARGE; ++i)
        (void)b.Append(i);
    std::shared_ptr<arrow::Array> arr;
    (void)b.Finish(&arr);

    auto t0 = now_ns();
    auto res = arrow::compute::Sum(arr).ValueOrDie();
    g_sink += static_cast<double>(res.scalar_as<arrow::Int64Scalar>().value);
    return now_ns() - t0;
}

// ── min / max ─────────────────────────────────────────────────────────────────

static ns_t bench_min_max_i32() {
    arrow::Int32Builder b;
    for (int i = 0; i < N_LARGE; ++i)
        (void)b.Append(N_LARGE - i);
    std::shared_ptr<arrow::Array> arr;
    (void)b.Finish(&arr);

    auto t0  = now_ns();
    auto res = arrow::compute::MinMax(arr).ValueOrDie();
    auto mm  = res.scalar_as<arrow::StructScalar>();
    auto mn  = std::static_pointer_cast<arrow::Int32Scalar>(mm.field("min").ValueOrDie());
    auto mx  = std::static_pointer_cast<arrow::Int32Scalar>(mm.field("max").ValueOrDie());
    g_sink += mn->value + mx->value;
    return now_ns() - t0;
}

// ── filter ────────────────────────────────────────────────────────────────────

static ns_t bench_filter_i32() {
    arrow::Int32Builder b;
    for (int i = 0; i < N_LARGE; ++i)
        (void)b.Append(i);
    std::shared_ptr<arrow::Array> arr;
    (void)b.Finish(&arr);

    arrow::BooleanBuilder mb;
    for (int i = 0; i < N_LARGE; ++i)
        (void)mb.Append(i % 2 == 0);
    std::shared_ptr<arrow::Array> mask;
    (void)mb.Finish(&mask);

    auto t0     = now_ns();
    auto result = arrow::compute::Filter(arr, mask).ValueOrDie();
    g_sink += static_cast<double>(result.make_array()->length());
    return now_ns() - t0;
}

// ── string build ──────────────────────────────────────────────────────────────

static ns_t bench_string_build() {
    auto t0 = now_ns();

    arrow::StringBuilder b;
    for (int i = 0; i < N_STRING; ++i) {
        if (i % 50 == 0)
            (void)b.AppendNull();
        else
            (void)b.Append("hello_world");
    }
    std::shared_ptr<arrow::Array> arr;
    (void)b.Finish(&arr);
    g_sink += static_cast<double>(arr->length());

    return now_ns() - t0;
}

// ── string scan ───────────────────────────────────────────────────────────────

static ns_t bench_string_scan() {
    arrow::StringBuilder b;
    for (int i = 0; i < N_STRING; ++i)
        (void)b.Append("hello_world");
    std::shared_ptr<arrow::Array> arr;
    (void)b.Finish(&arr);

    auto t0      = now_ns();
    auto lengths = arrow::compute::CallFunction("utf8_length", {arr}).ValueOrDie();
    auto total   = arrow::compute::Sum(lengths).ValueOrDie();
    g_sink += static_cast<double>(total.scalar_as<arrow::Int64Scalar>().value);
    return now_ns() - t0;
}

// ── IPC roundtrip ─────────────────────────────────────────────────────────────

static const char* IPC_BENCH_PATH = "/tmp/cpp_bench_ipc.arrow";

static ns_t bench_ipc_roundtrip() {
    arrow::Int32Builder b;
    for (int i = 0; i < N_LARGE; ++i) (void)b.Append(i);
    std::shared_ptr<arrow::Array> arr;
    (void)b.Finish(&arr);
    auto schema = arrow::schema({arrow::field("v", arrow::int32())});
    auto batch  = arrow::RecordBatch::Make(schema, arr->length(), {arr});

    auto t0 = now_ns();
    {
        auto out = arrow::io::FileOutputStream::Open(IPC_BENCH_PATH).ValueOrDie();
        auto w   = arrow::ipc::MakeFileWriter(out, schema).ValueOrDie();
        (void)w->WriteRecordBatch(*batch);
        (void)w->Close();
        (void)out->Close();
    }
    auto in  = arrow::io::ReadableFile::Open(IPC_BENCH_PATH).ValueOrDie();
    auto rd  = arrow::ipc::RecordBatchFileReader::Open(in).ValueOrDie();
    auto got = rd->ReadRecordBatch(0).ValueOrDie();
    auto ns  = now_ns() - t0;
    g_sink += static_cast<double>(got->num_rows());
    (void)in->Close();
    return ns;
}

// ── main ──────────────────────────────────────────────────────────────────────

template<typename F>
static ns_t run(F f) {
    std::vector<ns_t> times;
    times.reserve(TRIALS);
    for (int i = 0; i < TRIALS; ++i)
        times.push_back(f());
    return median(times);
}

int main() {
    // Register compute kernels that aren't auto-registered in the PyArrow bundle
    auto* reg = arrow::compute::GetFunctionRegistry();
    arrow::compute::internal::RegisterScalarAggregateBasic(reg);
    arrow::compute::internal::RegisterScalarStringUtf8(reg);

    report("array_build_10m_i32", run(bench_array_build));
    report("sum_10m_f64",         run(bench_sum_f64));
    report("sum_10m_i32",         run(bench_sum_i32));
    report("min_max_10m_i32",     run(bench_min_max_i32));
    report("filter_10m_i32",      run(bench_filter_i32));
    report("string_build_1m",     run(bench_string_build));
    report("string_scan_1m",      run(bench_string_scan));
    report("ipc_roundtrip_10m_i32", run(bench_ipc_roundtrip));

    // Emit sink so the compiler can't prove it's dead
    if (g_sink < -1e300) std::printf("sink=%f\n", g_sink);
    return 0;
}
