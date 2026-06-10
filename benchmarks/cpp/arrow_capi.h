/* C API wrapping Apache Arrow C++ compute kernels.
 * All functions accept Arrow-layout buffers directly (zero-copy).
 * Buffer layout matches Apache Arrow columnar format spec:
 *   - validity: packed-bit bitmap (bit i = element i is valid), NULL = no nulls
 *   - data: contiguous typed values (for fixed-width) or offsets (for strings)
 *   - utf8_data: character bytes (strings only)
 */
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    double  value;
    int64_t valid_count;
} ArrowScalar;

/* Fixed-width numeric kernels.
 * validity: optional packed-bit bitmap; NULL means all elements are valid.
 * data:     contiguous array of the matching C type.
 * n:        number of elements.
 */
ArrowScalar arrow_capi_sum_i32 (const uint8_t* validity, const int32_t* data, int64_t n);
ArrowScalar arrow_capi_sum_f64 (const uint8_t* validity, const double*   data, int64_t n);
ArrowScalar arrow_capi_min_i32 (const uint8_t* validity, const int32_t* data, int64_t n);
ArrowScalar arrow_capi_max_i32 (const uint8_t* validity, const int32_t* data, int64_t n);

/* Filter an Int32 array through a packed-bit Boolean mask.
 * Both src and mask may have independent validity bitmaps.
 * Null mask entries are treated as false (element excluded).
 * Returns the number of elements that passed the filter.
 */
int64_t arrow_capi_filter_i32(
    const uint8_t* src_validity,  /* nullable */
    const int32_t* src_data,
    const uint8_t* mask_validity, /* nullable */
    const uint8_t* mask_bits,     /* packed-bit bool values */
    int64_t n);

/* Sum of UTF-8 string lengths via Arrow utf8_length + sum.
 * offsets: (n+1) int32 offset values (Arrow StringArray format).
 * utf8_data: raw character bytes.
 * Returns total bytes across all valid strings.
 */
int64_t arrow_capi_string_scan(
    const uint8_t* validity,
    const int32_t* offsets,
    const uint8_t* utf8_data,
    int64_t n);

#ifdef __cplusplus
}
#endif
