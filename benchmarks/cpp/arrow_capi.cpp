#include "arrow_capi.h"

#include <arrow/api.h>
#include <arrow/compute/api.h>

#include <cassert>
#include <cstdlib>
#include <cstring>
#include <mutex>

// ── compute kernel registration ───────────────────────────────────────────────
//
// PyArrow bundles Arrow C++ with compute kernels split across multiple shared
// libraries.  When linking the standalone binary (not via Python), the kernel
// registration static-initializers inside libarrow_compute.so do not run
// automatically — only the 13 core vector kernels in libarrow.so are present.
//
// We call the internal registration functions once at library init time.
// These symbols are stable across Arrow 24.x (verified via nm).

namespace arrow { namespace compute { namespace internal {
    void RegisterScalarAggregateBasic(FunctionRegistry*);  // sum, count, min, max, …
    void RegisterScalarStringUtf8(FunctionRegistry*);       // utf8_length, utf8_upper, …
}}}

static void ensure_kernels_registered() {
    static std::once_flag once;
    std::call_once(once, []() {
        auto* reg = arrow::compute::GetFunctionRegistry();
        arrow::compute::internal::RegisterScalarAggregateBasic(reg);
        arrow::compute::internal::RegisterScalarStringUtf8(reg);
    });
}

// ── helpers ───────────────────────────────────────────────────────────────────

// Count null elements by scanning the packed-bit validity bitmap.
static int64_t count_nulls(const uint8_t* validity, int64_t n) {
    if (!validity) return 0;
    int64_t valid = 0;
    int64_t full  = n / 8;
    for (int64_t i = 0; i < full; ++i)
        valid += __builtin_popcount(validity[i]);
    if (int rem = n % 8; rem != 0) {
        uint8_t last = validity[full] & ((1u << rem) - 1);
        valid += __builtin_popcount(last);
    }
    return n - valid;
}

// Wrap a raw pointer in an Arrow Buffer without taking ownership.
static std::shared_ptr<arrow::Buffer> wrap(const void* ptr, int64_t bytes) {
    return std::make_shared<arrow::Buffer>(
        static_cast<const uint8_t*>(ptr), bytes);
}

// Build an ArrayData for a fixed-width primitive type.
// validity may be nullptr (all valid).
static std::shared_ptr<arrow::ArrayData> make_i32_data(
    const uint8_t* validity, const int32_t* data, int64_t n)
{
    int64_t null_count = count_nulls(validity, n);
    int64_t bm_bytes   = (n + 7) / 8;
    std::vector<std::shared_ptr<arrow::Buffer>> bufs;
    bufs.push_back(validity ? wrap(validity, bm_bytes) : nullptr);
    bufs.push_back(wrap(data, n * sizeof(int32_t)));
    return arrow::ArrayData::Make(arrow::int32(), n, std::move(bufs), null_count);
}

static std::shared_ptr<arrow::ArrayData> make_f64_data(
    const uint8_t* validity, const double* data, int64_t n)
{
    int64_t null_count = count_nulls(validity, n);
    int64_t bm_bytes   = (n + 7) / 8;
    std::vector<std::shared_ptr<arrow::Buffer>> bufs;
    bufs.push_back(validity ? wrap(validity, bm_bytes) : nullptr);
    bufs.push_back(wrap(data, n * sizeof(double)));
    return arrow::ArrayData::Make(arrow::float64(), n, std::move(bufs), null_count);
}

// ── sum ───────────────────────────────────────────────────────────────────────

ArrowScalar arrow_capi_sum_i32(const uint8_t* validity, const int32_t* data, int64_t n) {
    ensure_kernels_registered();
    auto ad  = make_i32_data(validity, data, n);
    auto arr = arrow::MakeArray(ad);
    auto res = arrow::compute::Sum(arr).ValueOrDie();
    auto s   = res.scalar_as<arrow::Int64Scalar>();
    return { static_cast<double>(s.value), n - ad->GetNullCount() };
}

ArrowScalar arrow_capi_sum_f64(const uint8_t* validity, const double* data, int64_t n) {
    ensure_kernels_registered();
    auto ad  = make_f64_data(validity, data, n);
    auto arr = arrow::MakeArray(ad);
    auto res = arrow::compute::Sum(arr).ValueOrDie();
    auto s   = res.scalar_as<arrow::DoubleScalar>();
    return { s.value, n - ad->GetNullCount() };
}

// ── min / max ─────────────────────────────────────────────────────────────────

ArrowScalar arrow_capi_min_i32(const uint8_t* validity, const int32_t* data, int64_t n) {
    ensure_kernels_registered();
    auto ad  = make_i32_data(validity, data, n);
    auto arr = arrow::MakeArray(ad);
    auto res = arrow::compute::MinMax(arr).ValueOrDie();
    auto mm  = res.scalar_as<arrow::StructScalar>();
    auto val = std::static_pointer_cast<arrow::Int32Scalar>(mm.field("min").ValueOrDie());
    return { static_cast<double>(val->value), n - ad->GetNullCount() };
}

ArrowScalar arrow_capi_max_i32(const uint8_t* validity, const int32_t* data, int64_t n) {
    ensure_kernels_registered();
    auto ad  = make_i32_data(validity, data, n);
    auto arr = arrow::MakeArray(ad);
    auto res = arrow::compute::MinMax(arr).ValueOrDie();
    auto mm  = res.scalar_as<arrow::StructScalar>();
    auto val = std::static_pointer_cast<arrow::Int32Scalar>(mm.field("max").ValueOrDie());
    return { static_cast<double>(val->value), n - ad->GetNullCount() };
}

// ── filter ────────────────────────────────────────────────────────────────────

int64_t arrow_capi_filter_i32(
    const uint8_t* src_validity,
    const int32_t* src_data,
    const uint8_t* mask_validity,
    const uint8_t* mask_bits,
    int64_t n)
{
    // Source Int32 array
    auto src_ad  = make_i32_data(src_validity, src_data, n);
    auto src_arr = arrow::MakeArray(src_ad);

    // Boolean mask array (bit-packed values in buf[1])
    int64_t mask_null = count_nulls(mask_validity, n);
    int64_t bm_bytes  = (n + 7) / 8;
    std::vector<std::shared_ptr<arrow::Buffer>> mask_bufs;
    mask_bufs.push_back(mask_validity ? wrap(mask_validity, bm_bytes) : nullptr);
    mask_bufs.push_back(wrap(mask_bits, bm_bytes));
    auto mask_ad  = arrow::ArrayData::Make(arrow::boolean(), n, std::move(mask_bufs), mask_null);
    auto mask_arr = arrow::MakeArray(mask_ad);

    auto result = arrow::compute::Filter(src_arr, mask_arr).ValueOrDie();
    return result.make_array()->length();
}

// ── string scan ───────────────────────────────────────────────────────────────

int64_t arrow_capi_string_scan(
    const uint8_t* validity,
    const int32_t* offsets,
    const uint8_t* utf8_data,
    int64_t n)
{
    ensure_kernels_registered();
    int64_t null_count  = count_nulls(validity, n);
    int64_t bm_bytes    = (n + 7) / 8;
    int64_t off_bytes   = (n + 1) * static_cast<int64_t>(sizeof(int32_t));
    int64_t data_bytes  = offsets[n];  // last offset = total byte count

    std::vector<std::shared_ptr<arrow::Buffer>> bufs;
    bufs.push_back(validity ? wrap(validity, bm_bytes) : nullptr);
    bufs.push_back(wrap(offsets,   off_bytes));
    bufs.push_back(wrap(utf8_data, data_bytes));
    auto ad  = arrow::ArrayData::Make(arrow::utf8(), n, std::move(bufs), null_count);
    auto arr = arrow::MakeArray(ad);

    auto lengths = arrow::compute::CallFunction("utf8_length", {arr}).ValueOrDie();
    auto total   = arrow::compute::Sum(lengths).ValueOrDie();
    return total.scalar_as<arrow::Int64Scalar>().value;
}
