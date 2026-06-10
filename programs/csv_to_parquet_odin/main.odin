package csv_to_parquet_odin

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:time"

main :: proc() {
	args := os.args[1:]
	max_mb   := 200
	in_path  : string
	out_path : string

	i := 0
	for i < len(args) {
		switch args[i] {
		case "-m":
			if i+1 < len(args) {
				if v, ok := strconv.parse_int(args[i+1]); ok && v > 0 { max_mb = v }
				i += 2
			} else {
				i += 1
			}
		case:
			if in_path == "" { in_path = args[i] } else { out_path = args[i] }
			i += 1
		}
	}

	if in_path == "" || out_path == "" {
		fmt.eprintln("usage: csv_to_parquet_odin [-m MB] <input.csv> <output.parquet>")
		fmt.eprintln("  -m MB   memory limit in MB (default: 200)")
		os.exit(1)
	}

	mem_limit := i64(max_mb) * 1024 * 1024

	// ── CSV reader ────────────────────────────────────────────────────────────
	// Read buffer: 10% of memory limit, clamped to [4 MB, 64 MB].
	buf_size := int(mem_limit / 10)
	if buf_size < 4  * 1024 * 1024 { buf_size = 4  * 1024 * 1024 }
	if buf_size > 64 * 1024 * 1024 { buf_size = 64 * 1024 * 1024 }

	csv, csv_ok := csv_stream_open(in_path, buf_size)
	if !csv_ok {
		fmt.eprintfln("error: cannot open CSV %s", in_path)
		os.exit(1)
	}
	defer csv_stream_destroy(&csv)

	n_cols := csv.n_cols

	// ── Parquet output ────────────────────────────────────────────────────────
	out_file, out_err := os.open(out_path, {.Write, .Create, .Trunc}, os.Permissions_Default_File)
	if out_err != nil {
		fmt.eprintfln("error: cannot create %s: %v", out_path, out_err)
		os.exit(1)
	}
	defer os.close(out_file)

	pw := pw_open(out_file, csv.col_names)
	defer pw_destroy(&pw)

	// ── Memory budget → chunk size ────────────────────────────────────────────
	// arena holds string bytes for one row group.
	// Budget breakdown:
	//   buf_size   - CSV read buffer
	//   arena_cap  - string bytes for one row group (we compute this)
	//   32 MB      - runtime overhead, Parquet write buffers, etc.
	overhead  := i64(buf_size) + 32 * 1024 * 1024
	arena_cap := mem_limit - overhead
	if arena_cap < 8 * 1024 * 1024 { arena_cap = 8 * 1024 * 1024 }

	// Estimate bytes per row (conservative: 200 bytes per column).
	// This governs max_rows and the overflow guard in csv_stream_read_chunk.
	per_row_est := n_cols * 200
	if per_row_est < 1 { per_row_est = 200 }

	max_rows := int(arena_cap) / per_row_est
	if max_rows < 1 { max_rows = 1 }

	// ── Allocate reusable structures ──────────────────────────────────────────
	// col_data[ci][ri] → string view into arena; valid until arena is cleared.
	col_data := make([][]string, n_cols)
	defer {
		for ci in 0..<n_cols { delete(col_data[ci]) }
		delete(col_data)
	}
	for ci in 0..<n_cols { col_data[ci] = make([]string, max_rows) }

	// Arena: pre-reserved to arena_cap bytes so append never reallocates
	// (which would invalidate existing string pointers).
	arena := make([dynamic]u8, 0, int(arena_cap))
	defer delete(arena)

	// ── Conversion loop ───────────────────────────────────────────────────────
	t0          := time.now()
	total_rows  := 0
	total_chunks := 0

	for {
		clear(&arena) // reset len to 0; capacity stays at arena_cap → no realloc

		n := csv_stream_read_chunk(&csv, col_data, max_rows, &arena, per_row_est)
		if n == 0 { break }

		pw_write_row_group(&pw, col_data[:n_cols], n)

		total_rows   += n
		total_chunks += 1
	}

	pw_finish(&pw)

	total_ns := time.duration_nanoseconds(time.since(t0))
	fmt.eprintfln("rows:        %d", total_rows)
	fmt.eprintfln("row_groups:  %d", total_chunks)
	fmt.eprintfln("mem_limit:   %dMB", max_mb)
	fmt.eprintfln("total_ms:    %.1f", f64(total_ns) / 1e6)
}
