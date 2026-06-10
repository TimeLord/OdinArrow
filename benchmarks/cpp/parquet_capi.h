#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

// Parquet → CSV.  Pass "-" as output_path for stdout.
// Returns 0 on success; on error fills errbuf and returns -1.
int parquet_capi_to_csv(
    const char* input_path,
    const char* output_path,
    char*       errbuf,
    int         errbuf_len);

// Same as above but reads row-group-by-row-group so at most one row group of
// decoded Arrow data is live at once.  max_memory_bytes is advisory (passed to
// Arrow; the actual peak depends on row-group size in the file).
int parquet_capi_to_csv_mem(
    const char* input_path,
    const char* output_path,
    int64_t     max_memory_bytes,
    char*       errbuf,
    int         errbuf_len);

// CSV → Parquet (uncompressed, auto-detect types).
int parquet_capi_from_csv(
    const char* input_path,
    const char* output_path,
    char*       errbuf,
    int         errbuf_len);

// Same but streams the CSV in blocks of roughly max_memory_bytes/2 so the
// working set stays bounded.  Each block becomes one Parquet row group.
int parquet_capi_from_csv_mem(
    const char* input_path,
    const char* output_path,
    int64_t     max_memory_bytes,
    char*       errbuf,
    int         errbuf_len);

#ifdef __cplusplus
}
#endif
