#include "parquet_capi.h"

#include <arrow/api.h>
#include <arrow/csv/api.h>
#include <arrow/csv/writer.h>
#include <arrow/io/file.h>
#include <arrow/io/interfaces.h>
#include <arrow/io/stdio.h>
#include <parquet/arrow/reader.h>
#include <parquet/arrow/writer.h>
#include <parquet/properties.h>

#include <algorithm>
#include <climits>
#include <cstring>
#include <memory>
#include <string>

// ── helpers ───────────────────────────────────────────────────────────────────

static void set_err(char* errbuf, int len, const std::string& msg) {
    if (errbuf && len > 0) {
        strncpy(errbuf, msg.c_str(), len - 1);
        errbuf[len - 1] = '\0';
    }
}

static std::shared_ptr<arrow::io::OutputStream>
open_output(const char* path, char* errbuf, int errbuf_len) {
    if (std::string(path) == "-") {
        return std::make_shared<arrow::io::StdoutStream>();
    }
    auto result = arrow::io::FileOutputStream::Open(path);
    if (!result.ok()) {
        set_err(errbuf, errbuf_len, result.status().ToString());
        return nullptr;
    }
    return result.MoveValueUnsafe();
}

// ── parquet_capi_to_csv ───────────────────────────────────────────────────────

extern "C"
int parquet_capi_to_csv(
    const char* input_path,
    const char* output_path,
    char*       errbuf,
    int         errbuf_len)
{
    return parquet_capi_to_csv_mem(input_path, output_path, INT64_MAX, errbuf, errbuf_len);
}

// ── parquet_capi_to_csv_mem ───────────────────────────────────────────────────
//
// Reads one row group at a time so the live Arrow memory stays bounded.

extern "C"
int parquet_capi_to_csv_mem(
    const char* input_path,
    const char* output_path,
    int64_t     max_memory_bytes,
    char*       errbuf,
    int         errbuf_len)
{
    (void)max_memory_bytes; // row-group reading already bounds memory

    std::shared_ptr<arrow::io::ReadableFile> infile;
    {
        auto r = arrow::io::ReadableFile::Open(input_path);
        if (!r.ok()) { set_err(errbuf, errbuf_len, r.status().ToString()); return -1; }
        infile = r.MoveValueUnsafe();
    }

    std::unique_ptr<parquet::arrow::FileReader> reader;
    {
        auto r = parquet::arrow::OpenFile(infile, arrow::default_memory_pool());
        if (!r.ok()) { set_err(errbuf, errbuf_len, r.status().ToString()); return -1; }
        reader = r.MoveValueUnsafe();
    }

    auto outfile = open_output(output_path, errbuf, errbuf_len);
    if (!outfile) { return -1; }

    int n_rg = reader->num_row_groups();
    auto opts = arrow::csv::WriteOptions::Defaults();
    opts.quoting_style = arrow::csv::QuotingStyle::Needed;

    for (int rg = 0; rg < n_rg; rg++) {
        std::shared_ptr<arrow::Table> table;
        {
            auto r = reader->ReadRowGroup(rg);
            if (!r.ok()) { set_err(errbuf, errbuf_len, r.status().ToString()); return -1; }
            table = r.MoveValueUnsafe();
        }
        opts.include_header = (rg == 0);
        auto status = arrow::csv::WriteCSV(*table, opts, outfile.get());
        if (!status.ok()) { set_err(errbuf, errbuf_len, status.ToString()); return -1; }
        table.reset(); // release before loading next row group
    }
    return 0;
}

// ── parquet_capi_from_csv ────────────────────────────────────────────────────

extern "C"
int parquet_capi_from_csv(
    const char* input_path,
    const char* output_path,
    char*       errbuf,
    int         errbuf_len)
{
    return parquet_capi_from_csv_mem(input_path, output_path,
                                     200LL * 1024 * 1024, errbuf, errbuf_len);
}

// ── parquet_capi_from_csv_mem ────────────────────────────────────────────────
//
// Streams the CSV in blocks of ~max_memory_bytes/2, writing one Parquet row
// group per block.  Arrow auto-detects column types.

extern "C"
int parquet_capi_from_csv_mem(
    const char* input_path,
    const char* output_path,
    int64_t     max_memory_bytes,
    char*       errbuf,
    int         errbuf_len)
{
    // Open CSV input
    std::shared_ptr<arrow::io::ReadableFile> infile;
    {
        auto r = arrow::io::ReadableFile::Open(input_path);
        if (!r.ok()) { set_err(errbuf, errbuf_len, r.status().ToString()); return -1; }
        infile = r.MoveValueUnsafe();
    }

    // Block size = half the memory limit, capped at 64 MB
    int64_t block = std::min(max_memory_bytes / 2, (int64_t)(64 * 1024 * 1024));
    block = std::max(block, (int64_t)(1 * 1024 * 1024)); // floor at 1 MB

    auto read_opts    = arrow::csv::ReadOptions::Defaults();
    read_opts.block_size = (int32_t)std::min(block, (int64_t)INT32_MAX);

    // Build streaming CSV reader
    std::shared_ptr<arrow::csv::StreamingReader> csv_reader;
    {
        auto r = arrow::csv::StreamingReader::Make(
            arrow::io::default_io_context(), infile,
            read_opts,
            arrow::csv::ParseOptions::Defaults(),
            arrow::csv::ConvertOptions::Defaults());
        if (!r.ok()) { set_err(errbuf, errbuf_len, r.status().ToString()); return -1; }
        csv_reader = r.MoveValueUnsafe();
    }

    // Read first batch to get schema
    std::shared_ptr<arrow::RecordBatch> first_batch;
    {
        auto status = csv_reader->ReadNext(&first_batch);
        if (!status.ok()) { set_err(errbuf, errbuf_len, status.ToString()); return -1; }
        if (!first_batch) { return 0; } // empty CSV
    }

    // Open Parquet output
    std::shared_ptr<arrow::io::OutputStream> outfile;
    {
        auto r = arrow::io::FileOutputStream::Open(output_path);
        if (!r.ok()) { set_err(errbuf, errbuf_len, r.status().ToString()); return -1; }
        outfile = r.MoveValueUnsafe();
    }

    // Create Parquet writer
    auto write_props = parquet::WriterProperties::Builder()
        .compression(parquet::Compression::UNCOMPRESSED)
        ->build();
    auto arrow_props = parquet::ArrowWriterProperties::Builder().build();

    std::unique_ptr<parquet::arrow::FileWriter> writer;
    {
        auto r = parquet::arrow::FileWriter::Open(
            *first_batch->schema(),
            arrow::default_memory_pool(),
            outfile, write_props, arrow_props);
        if (!r.ok()) { set_err(errbuf, errbuf_len, r.status().ToString()); return -1; }
        writer = r.MoveValueUnsafe();
    }

    // Write first batch as row group
    {
        auto table = arrow::Table::FromRecordBatches({first_batch}).MoveValueUnsafe();
        auto status = writer->WriteTable(*table, first_batch->num_rows());
        if (!status.ok()) { set_err(errbuf, errbuf_len, status.ToString()); return -1; }
    }
    first_batch.reset();

    // Stream remaining batches, one row group each
    while (true) {
        std::shared_ptr<arrow::RecordBatch> batch;
        auto status = csv_reader->ReadNext(&batch);
        if (!status.ok()) { set_err(errbuf, errbuf_len, status.ToString()); return -1; }
        if (!batch) { break; }

        auto table = arrow::Table::FromRecordBatches({batch}).MoveValueUnsafe();
        status = writer->WriteTable(*table, batch->num_rows());
        if (!status.ok()) { set_err(errbuf, errbuf_len, status.ToString()); return -1; }
        batch.reset();
    }

    auto status = writer->Close();
    if (!status.ok()) { set_err(errbuf, errbuf_len, status.ToString()); return -1; }
    return 0;
}
