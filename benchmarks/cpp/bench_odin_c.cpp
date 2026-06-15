// Comprehensive single-threaded Arrow C++ benchmark, paired 1:1 with the Odin
// benchmark in benchmarks/odin_c. Output: `key=nanoseconds` per line (median of
// TRIALS), parsed by benchmarks/bench_odin_c.sh.
//
// Single-threaded on both sides: this isolates per-core implementation
// efficiency (OdinArrow also ships threaded *_parallel kernels — see the 3-way
// compare.sh — but those are excluded here for an apples-to-apples comparison).
#include <arrow/api.h>
#include <arrow/compute/api.h>
#include <arrow/compute/initialize.h>
#include <arrow/io/file.h>
#include <arrow/ipc/api.h>

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <random>
#include <vector>

static constexpr int N      = 10'000'000;  // large numeric
static constexpr int NS     = 1'000'000;   // strings
static constexpr int NSORT  = 1'000'000;   // sort input
static constexpr int NIDX   = 1'000'000;   // take indices
static constexpr int NVC    = 10'000'000;  // value_counts rows
static constexpr int NVCD   = 100;         // value_counts distinct
static constexpr int TRIALS = 5;

static double g_sink = 0;
using ns_t  = long long;
using Clock = std::chrono::steady_clock;
static ns_t now_ns() { return std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now().time_since_epoch()).count(); }
static ns_t median(std::vector<ns_t> v) { std::nth_element(v.begin(), v.begin()+v.size()/2, v.end()); return v[v.size()/2]; }
static void report(const char* k, ns_t ns) { printf("%s=%lld\n", k, ns); }
template<typename F> static ns_t run(F f) {
    std::vector<ns_t> t; t.reserve(TRIALS);
    for (int i=0;i<TRIALS;i++){ auto a=now_ns(); f(); t.push_back(now_ns()-a); }
    return median(t);
}

static std::shared_ptr<arrow::Array> finish(arrow::ArrayBuilder& b){ std::shared_ptr<arrow::Array> a; (void)b.Finish(&a); return a; }

int main() {
    if (!arrow::compute::Initialize().ok()) { fprintf(stderr, "compute init failed\n"); return 1; }
    namespace cp = arrow::compute;

    // ── construction (timed) ──────────────────────────────────────────────────
    report("build_i32_10m", run([]{
        arrow::Int32Builder b; (void)b.Reserve(N);
        for (int i=0;i<N;i++){ if(i%100==0)(void)b.AppendNull(); else (void)b.Append(i); }
        g_sink += finish(b)->length();
    }));
    report("build_str_1m", run([]{
        arrow::StringBuilder b;
        for (int i=0;i<NS;i++){ if(i%50==0)(void)b.AppendNull(); else (void)b.Append("hello_world"); }
        g_sink += finish(b)->length();
    }));

    // ── prebuilt inputs (untimed) ─────────────────────────────────────────────
    auto f64 = [&]{ arrow::DoubleBuilder b;(void)b.Reserve(N); for(int i=0;i<N;i++)(void)b.Append(i*0.001); return finish(b);}();
    auto f64n= [&]{ arrow::DoubleBuilder b;(void)b.Reserve(N); for(int i=0;i<N;i++){if(i%100==0)(void)b.AppendNull();else(void)b.Append(i*0.001);} return finish(b);}();
    auto i32 = [&]{ arrow::Int32Builder b;(void)b.Reserve(N); for(int i=0;i<N;i++)(void)b.Append(i); return finish(b);}();
    auto i32b= [&]{ arrow::Int32Builder b;(void)b.Reserve(N); for(int i=0;i<N;i++)(void)b.Append(i%1000); return finish(b);}();
    auto mask50=[&]{ arrow::BooleanBuilder b;(void)b.Reserve(N); for(int i=0;i<N;i++)(void)b.Append(i%2==0); return finish(b);}();
    auto mask1 =[&]{ arrow::BooleanBuilder b;(void)b.Reserve(N); for(int i=0;i<N;i++)(void)b.Append(i%100==0); return finish(b);}();
    auto strs  =[&]{ arrow::StringBuilder b; for(int i=0;i<NS;i++)(void)b.Append("hello_world"); return finish(b);}();
    auto i32sort=[&]{ arrow::Int32Builder b;(void)b.Reserve(NSORT); std::mt19937 r(7); for(int i=0;i<NSORT;i++)(void)b.Append(int(r())); return finish(b);}();
    auto idxa  =[&]{ arrow::Int64Builder b;(void)b.Reserve(NIDX); std::mt19937_64 r(42); for(int i=0;i<NIDX;i++)(void)b.Append(int64_t(r()%N)); return finish(b);}();
    // value_counts on a dictionary-encoded low-cardinality string column
    auto vc_plain=[&]{ arrow::StringBuilder b; char buf[16]; for(int i=0;i<NVC;i++){ int k=i%NVCD; snprintf(buf,sizeof buf,"category_%02d",k); (void)b.Append(buf);} return finish(b);}();
    auto vc_dict = cp::DictionaryEncode(vc_plain).ValueOrDie().make_array();

    // ── aggregation ───────────────────────────────────────────────────────────
    report("sum_f64_10m",        run([&]{ g_sink += cp::Sum(f64).ValueOrDie().scalar_as<arrow::DoubleScalar>().value; }));
    report("sum_f64_nulls_10m",  run([&]{ g_sink += cp::Sum(f64n).ValueOrDie().scalar_as<arrow::DoubleScalar>().value; }));
    report("minmax_i32_10m",     run([&]{ auto r=cp::MinMax(i32).ValueOrDie(); g_sink += r.scalar_as<arrow::StructScalar>().value.size(); }));
    report("mean_f64_10m",       run([&]{ g_sink += cp::CallFunction("mean",{f64}).ValueOrDie().scalar_as<arrow::DoubleScalar>().value; }));

    // ── selection / reshape ───────────────────────────────────────────────────
    report("filter_i32_10m_50",  run([&]{ g_sink += cp::Filter(i32, mask50).ValueOrDie().make_array()->length(); }));
    report("filter_i32_10m_1",   run([&]{ g_sink += cp::Filter(i32, mask1).ValueOrDie().make_array()->length(); }));
    report("take_i32_10m",       run([&]{ g_sink += cp::Take(i32, idxa).ValueOrDie().make_array()->length(); }));
    report("sort_i32_1m",        run([&]{ g_sink += cp::CallFunction("sort_indices",{i32sort}).ValueOrDie().make_array()->length(); }));

    // ── element-wise ──────────────────────────────────────────────────────────
    report("cast_i32_f64_10m",   run([&]{ g_sink += cp::Cast(i32, arrow::float64()).ValueOrDie().make_array()->length(); }));
    report("add_i32_10m",        run([&]{ g_sink += cp::CallFunction("add",{i32,i32b}).ValueOrDie().make_array()->length(); }));
    report("compare_f64_10m",    run([&]{ g_sink += cp::CallFunction("greater",{f64, arrow::Datum(arrow::MakeScalar(5000.0))}).ValueOrDie().make_array()->length(); }));

    // ── strings ───────────────────────────────────────────────────────────────
    report("scan_str_1m",        run([&]{ auto l=cp::CallFunction("utf8_length",{strs}).ValueOrDie(); g_sink += cp::Sum(l).ValueOrDie().scalar_as<arrow::Int64Scalar>().value; }));

    // ── fused filter+sum (Arrow has no fused kernel: filter then sum) ──────────
    report("sumwhere_f64_10m",   run([&]{ auto fr=cp::Filter(f64,mask50).ValueOrDie(); g_sink += cp::Sum(fr).ValueOrDie().scalar_as<arrow::DoubleScalar>().value; }));

    // ── group-by (value_counts over the encoded codes) ────────────────────────
    report("valuecounts_str_10m",run([&]{ g_sink += cp::CallFunction("value_counts",{vc_dict}).ValueOrDie().make_array()->length(); }));

    // ── IPC roundtrip (write + read 10M i32) ──────────────────────────────────
    {
        auto schema = arrow::schema({arrow::field("v", arrow::int32())});
        auto batch  = arrow::RecordBatch::Make(schema, i32->length(), {i32});
        report("ipc_roundtrip_i32_10m", run([&]{
            const char* path = "/tmp/odc_cpp_ipc.arrow";
            auto out = arrow::io::FileOutputStream::Open(path).ValueOrDie();
            auto w   = arrow::ipc::MakeFileWriter(out, schema).ValueOrDie();
            (void)w->WriteRecordBatch(*batch); (void)w->Close(); (void)out->Close();
            auto in  = arrow::io::ReadableFile::Open(path).ValueOrDie();
            auto rd  = arrow::ipc::RecordBatchFileReader::Open(in).ValueOrDie();
            auto got = rd->ReadRecordBatch(0).ValueOrDie();
            g_sink += got->num_rows(); (void)in->Close();
        }));
    }

    if (g_sink < -1e300) std::printf("sink=%f\n", g_sink);
    return 0;
}
