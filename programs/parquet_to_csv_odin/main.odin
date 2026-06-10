package parquet_to_csv_odin

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:time"

// ── output buffer ─────────────────────────────────────────────────────────────

Out :: struct {
	fd:  ^os.File,
	buf: []u8,
	pos: int,
}

out_make :: proc(fd: ^os.File) -> Out {
	return Out{fd = fd, buf = make([]u8, 1 << 20)}
}

out_destroy :: proc(o: ^Out) { delete(o.buf) }

out_flush :: proc(o: ^Out) {
	if o.pos > 0 {
		os.write(o.fd, o.buf[:o.pos])
		o.pos = 0
	}
}

out_bytes :: proc(o: ^Out, b: []u8) {
	src := b
	for len(src) > 0 {
		avail := len(o.buf) - o.pos
		n := min(avail, len(src))
		copy(o.buf[o.pos:], src[:n])
		o.pos += n
		src = src[n:]
		if o.pos == len(o.buf) { out_flush(o) }
	}
}

out_str :: proc(o: ^Out, s: string) { out_bytes(o, transmute([]u8)s) }

// out_csv_field writes s as a CSV field, quoting per RFC 4180 when needed.
out_csv_field :: proc(o: ^Out, s: string) {
	needs_quoting := false
	for c in s {
		if c == '"' || c == ',' || c == '\n' || c == '\r' {
			needs_quoting = true
			break
		}
	}
	if !needs_quoting {
		out_str(o, s)
		return
	}
	out_str(o, "\"")
	start := 0
	for i := 0; i < len(s); i += 1 {
		if s[i] == '"' {
			out_str(o, s[start:i+1])
			out_str(o, "\"")
			start = i + 1
		}
	}
	out_str(o, s[start:])
	out_str(o, "\"")
}

out_i32 :: proc(o: ^Out, v: i32) {
	tmp: [16]u8
	s := strconv.write_int(tmp[:], i64(v), 10)
	out_str(o, s)
}

// ── main ──────────────────────────────────────────────────────────────────────

main :: proc() {
	args := os.args[1:]
	max_mb   := 200
	in_path  : string
	out_path := "-"

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

	if in_path == "" {
		fmt.eprintln("usage: parquet_to_csv_odin [-m MB] <input.parquet> [output.csv]")
		fmt.eprintln("  -m MB   memory limit in MB (default: 200)")
		os.exit(1)
	}

	mem_limit := i64(max_mb) * 1024 * 1024

	// Open file for footer reading only
	file, file_err := os.open(in_path)
	if file_err != nil {
		fmt.eprintfln("error: cannot open %s: %v", in_path, file_err)
		os.exit(1)
	}

	t0 := time.now()

	num_rows, metas, footer_ok := parse_footer_from_file(file)
	os.close(file) // footer parsed; column streams open their own handles
	if !footer_ok {
		fmt.eprintln("error: bad parquet footer")
		os.exit(1)
	}
	defer delete(metas)

	n_cols := len(metas)

	// Compute chunk_rows from memory budget.
	// Budget = 1 MB output buf + n_cols * 1 MB page bufs + chunk column arrays.
	overhead := i64(1 << 20) + i64(n_cols) * i64(1 << 20)
	avail    := mem_limit - overhead
	if avail < 8 * 1024 * 1024 { avail = 8 * 1024 * 1024 }

	bytes_per_row := i64(0)
	for i in 0..<n_cols {
		m := metas[i]
		if m.ptype == PTYPE_INT32 {
			bytes_per_row += 4
		} else if m.has_dict {
			bytes_per_row += 16 // just the string header; dict stays loaded
		} else {
			// PLAIN BYTE_ARRAY: string header + estimated value bytes
			avg := i64(80) // conservative default
			if m.num_values > 0 { avg = m.uncomp_size / m.num_values }
			bytes_per_row += 16 + avg
		}
	}
	if bytes_per_row == 0 { bytes_per_row = 80 }

	chunk_rows := int(avail / bytes_per_row)
	if chunk_rows < 1            { chunk_rows = 1 }
	if chunk_rows > int(num_rows) { chunk_rows = int(num_rows) }

	// Open per-column streaming readers
	streams := make([]Col_Stream, n_cols)
	defer {
		for j in 0..<n_cols { col_stream_destroy(&streams[j]) }
		delete(streams)
	}
	for j in 0..<n_cols {
		s, s_ok := col_stream_init(in_path, metas[j])
		if !s_ok {
			fmt.eprintfln("error: failed to open stream for column %s", metas[j].name)
			os.exit(1)
		}
		streams[j] = s
	}

	// Allocate reusable chunk buffers
	str_bufs := make([][]string, n_cols)
	i32_bufs := make([][]i32,    n_cols)
	defer {
		for j in 0..<n_cols {
			if str_bufs[j] != nil { delete(str_bufs[j]) }
			if i32_bufs[j] != nil { delete(i32_bufs[j]) }
		}
		delete(str_bufs)
		delete(i32_bufs)
	}
	for j in 0..<n_cols {
		if metas[j].ptype == PTYPE_INT32 {
			i32_bufs[j] = make([]i32, chunk_rows)
		} else {
			str_bufs[j] = make([]string, chunk_rows)
		}
	}

	// Shared buffer for PLAIN BYTE_ARRAY string bytes; reset (not freed) each chunk
	data_buf := make([dynamic]u8, 0, 32 << 20)
	defer delete(data_buf)

	// Open output — declare the file handle at the same scope level as the Out
	// buffer to avoid lifetime issues with ^os.File inside nested blocks.
	opened_file: ^os.File
	using_file := out_path != "-"
	if using_file {
		f, err := os.open(out_path, {.Write, .Create, .Trunc}, os.Permissions_Default_File)
		if err != nil {
			fmt.eprintfln("error: cannot open %s: %v", out_path, err)
			os.exit(1)
		}
		opened_file = f
	}
	defer if using_file && opened_file != nil { os.close(opened_file) }

	out_file := opened_file if using_file else os.stdout

	o := out_make(out_file)
	defer out_destroy(&o)

	// CSV header
	for j in 0..<n_cols {
		if j > 0 { out_str(&o, ",") }
		out_str(&o, metas[j].name)
	}
	out_str(&o, "\n")

	// Process in chunks
	rows_done := 0
	total     := int(num_rows)
	for rows_done < total {
		n := min(chunk_rows, total - rows_done)

		clear(&data_buf)
		for j in 0..<n_cols {
			if i32_bufs[j] != nil {
				col_stream_read_i32s(&streams[j], n, i32_bufs[j][:n])
			} else {
				col_stream_read_strings(&streams[j], n, str_bufs[j][:n], &data_buf)
			}
		}

		for r in 0..<n {
			for j in 0..<n_cols {
				if j > 0 { out_str(&o, ",") }
				if i32_bufs[j] != nil {
					out_i32(&o, i32_bufs[j][r])
				} else {
					out_csv_field(&o, str_bufs[j][r])
				}
			}
			out_str(&o, "\n")
		}

		rows_done += n
	}
	out_flush(&o)

	total_ns := time.duration_nanoseconds(time.since(t0))
	fmt.eprintfln("rows:       %d", num_rows)
	fmt.eprintfln("chunk_rows: %d", chunk_rows)
	fmt.eprintfln("mem_limit:  %dMB", max_mb)
	fmt.eprintfln("total_ms:   %.1f", f64(total_ns) / 1e6)
}
