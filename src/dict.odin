package odinarrow

import "core:mem"

// Dictionary encoding for low-cardinality string columns: the distinct values
// are stored once in a `dict` string array, and each logical element is an i32
// `code` indexing into it.
//
// The encoding-aware payoff is group-by / value_counts: the codes ARE the group
// ids, so counting occurrences is an integer histogram over the codes — O(n)
// integer increments with no string hashing or comparison at all. The same idea
// extends to grouped aggregation (sum a second column bucketed by code). This is
// what columnar engines exploit when a column arrives dictionary-encoded from
// storage (Parquet stores columns this way), where the encode cost is already
// paid and amortised across many queries.
//
// Separate type (not in the Arrow Array union); transcoded at an Arrow boundary.

Str_Dict_Array :: struct {
	dict:      Array, // string Array of the distinct values
	codes:     []i32, // one dictionary index per logical element
	length:    int,
	allocator: mem.Allocator,
}

str_dict_free :: proc(d: ^Str_Dict_Array) {
	array_free(&d.dict, d.allocator)
	delete(d.codes, d.allocator)
	d^ = {}
}

n_dict :: proc(d: ^Str_Dict_Array) -> int { return d.dict.length }

// Dictionary-encode a plain Arrow string array (deduplicating values).
str_dict_encode :: proc(src: ^Array, allocator := context.allocator) -> Str_Dict_Array {
	n := src.length
	// Keys are zero-copy views into `src`'s data buffer, valid for this proc.
	lookup := make(map[string]i32, 1 << 8, context.temp_allocator)
	defer delete(lookup)

	codes := make([]i32, n, allocator)
	db := string_builder_make(64, allocator)
	for i in 0..<n {
		s := array_get_string(src, i)
		code, ok := lookup[s]
		if !ok {
			code = i32(db.length)
			string_builder_append(&db, s)
			lookup[s] = code
		}
		codes[i] = code
	}
	dict, _ := string_builder_finish(&db, allocator)
	string_builder_destroy(&db)
	return Str_Dict_Array{ dict = dict, codes = codes, length = n, allocator = allocator }
}

// Zero-copy view of logical element i.
str_dict_get :: proc(d: ^Str_Dict_Array, i: int) -> string {
	return array_get_string(&d.dict, int(d.codes[i]))
}

// ── encoding-aware kernels ──────────────────────────────────────────────────

// value_counts: occurrences of each dictionary entry. counts[c] is the number
// of logical elements whose value is dict[c]. Pure integer histogram over the
// codes — no string work.
str_dict_value_counts :: proc(d: ^Str_Dict_Array, allocator := context.allocator) -> []i64 {
	counts := make([]i64, d.dict.length, allocator)
	for c in d.codes {
		counts[c] += 1
	}
	return counts
}

// group-by sum: sum the parallel numeric column `weights` bucketed by this
// column's dictionary code. out[c] = Σ weights[i] where codes[i] == c.
str_dict_group_sum :: proc(d: ^Str_Dict_Array, weights: ^Array, allocator := context.allocator) -> []f64 {
	out := make([]f64, d.dict.length, allocator)
	wdata := cast([^]f64)weights.buffers[1].data
	woff  := weights.offset
	n := min(d.length, weights.length)
	for i in 0..<n {
		out[d.codes[i]] += wdata[woff + i]
	}
	return out
}

// Expand back into a plain Arrow string array.
str_dict_decode :: proc(d: ^Str_Dict_Array, allocator := context.allocator) -> (arr: Array, err: mem.Allocator_Error) {
	b := string_builder_make(d.length, allocator)
	defer string_builder_destroy(&b)
	for i in 0..<d.length {
		string_builder_append(&b, str_dict_get(d, i))
	}
	return string_builder_finish(&b, allocator)
}
