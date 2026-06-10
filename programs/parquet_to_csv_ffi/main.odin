package parquet_to_csv_ffi

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:time"

// ── FFI declarations ──────────────────────────────────────────────────────────

when ODIN_OS == .Linux {
	foreign import libparquet_capi "../../lib/libparquet_capi.so"
}

@(default_calling_convention = "c")
foreign libparquet_capi {
	parquet_capi_to_csv_mem :: proc(
		input_path:      cstring,
		output_path:     cstring,
		max_memory_bytes: i64,
		errbuf:          [^]u8,
		errbuf_len:      i32,
	) -> i32 ---
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
		fmt.eprintln("usage: parquet_to_csv_ffi [-m MB] <input.parquet> [output.csv]")
		fmt.eprintln("  -m MB   memory limit in MB (default: 200)")
		os.exit(1)
	}

	errbuf: [1024]u8
	t0 := time.now()

	rc := parquet_capi_to_csv_mem(
		to_cstring(in_path),
		to_cstring(out_path),
		i64(max_mb) * 1024 * 1024,
		&errbuf[0],
		i32(len(errbuf)),
	)

	total_ns := time.duration_nanoseconds(time.since(t0))

	if rc != 0 {
		fmt.eprintfln("error: %s", string(errbuf[:]))
		os.exit(1)
	}

	fmt.eprintfln("mem_limit: %dMB", max_mb)
	fmt.eprintfln("total_ms:  %.1f", f64(total_ns) / 1e6)
}

@(private)
to_cstring :: proc(s: string) -> cstring {
	buf := make([]u8, len(s)+1, context.temp_allocator)
	copy(buf, s)
	buf[len(s)] = 0
	return cstring(raw_data(buf))
}
