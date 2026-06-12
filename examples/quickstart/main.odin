// OdinArrow quickstart — build arrays, run compute kernels, and round-trip an
// Arrow IPC file (which PyArrow / Arrow C++ can read directly).
//
// Run from the repo root with:
//     odin run examples/quickstart -out:/tmp/quickstart
package main

import oa "../../src"
import "core:fmt"
import "core:os"

main :: proc() {
	fmt.println("== OdinArrow quickstart ==")

	primitives()
	strings_demo()
	sorting()
	ipc_roundtrip()
}

// ── primitive arrays + compute ──────────────────────────────────────────────────

primitives :: proc() {
	fmt.println("\n-- primitives + compute --")

	// Build an Int32 array: 0,1,2,...,9 with index 3 set to null.
	b := oa.builder_make(i32, 10)
	defer oa.builder_destroy(&b)
	for i in 0..<10 {
		if i == 3 { oa.builder_append_null(&b) }
		else      { oa.builder_append(&b, i32(i)) }
	}
	arr, _ := oa.builder_finish(&b)
	defer oa.array_free(&arr)

	fmt.printfln("  length=%d  null_count=%d", arr.length, arr.null_count)

	sum, n := oa.compute_sum(&arr)
	lo, hi, _ := oa.compute_min_max(&arr)
	mean, _ := oa.compute_mean(&arr)
	fmt.printfln("  sum=%.0f (over %d non-null)  min=%.0f  max=%.0f  mean=%.2f", sum, n, lo, hi, mean)

	// Filter: keep the even values via a boolean mask.
	mb := oa.builder_make(bool, 10)
	defer oa.builder_destroy(&mb)
	for i in 0..<10 { oa.builder_append(&mb, i % 2 == 0) }
	mask, _ := oa.builder_finish(&mb)
	defer oa.array_free(&mask)

	evens, _ := oa.compute_filter(&arr, &mask)
	defer oa.array_free(&evens)
	fmt.printf("  even values: [")
	for i in 0..<evens.length {
		if oa.array_is_null(&evens, i) { fmt.printf("%snull", i == 0 ? "" : ", ") }
		else { fmt.printf("%s%d", i == 0 ? "" : ", ", oa.array_get(&evens, i, i32)) }
	}
	fmt.println("]")
}

// ── strings ─────────────────────────────────────────────────────────────────────

strings_demo :: proc() {
	fmt.println("\n-- strings --")

	b := oa.string_builder_make(4)
	defer oa.string_builder_destroy(&b)
	words := []string{"apache", "arrow", "in", "odin"}
	for w in words { oa.string_builder_append(&b, w) }
	arr, _ := oa.string_builder_finish(&b)
	defer oa.array_free(&arr)

	total := 0
	for i in 0..<arr.length { total += len(oa.array_get_string(&arr, i)) }
	fmt.printfln("  %d strings, %d total bytes; arr[1]=%q", arr.length, total, oa.array_get_string(&arr, 1))
}

// ── sort_indices + take ─────────────────────────────────────────────────────────

sorting :: proc() {
	fmt.println("\n-- sort_indices + take --")

	b := oa.builder_make(i32, 5)
	defer oa.builder_destroy(&b)
	vals := []i32{30, 10, 20, 50, 40}
	for v in vals { oa.builder_append(&b, v) }
	arr, _ := oa.builder_finish(&b)
	defer oa.array_free(&arr)

	idx, _ := oa.compute_sort_indices(&arr)   // Int64 indices that sort ascending
	defer oa.array_free(&idx)

	sorted, _ := oa.compute_take(&arr, &idx)   // gather into sorted order
	defer oa.array_free(&sorted)

	fmt.printf("  sorted: [")
	for i in 0..<sorted.length { fmt.printf("%s%d", i == 0 ? "" : ", ", oa.array_get(&sorted, i, i32)) }
	fmt.println("]")
}

// ── Arrow IPC round-trip ────────────────────────────────────────────────────────

ipc_roundtrip :: proc() {
	fmt.println("\n-- Arrow IPC file round-trip --")
	path := "/tmp/odinarrow_quickstart.arrow"
	defer os.remove(path)

	// A two-column schema: an Int32 id and a Utf8 name.
	schema, _ := oa.schema_make([]oa.Field{
		oa.field_make("id",   oa.Int32_Type{}),
		oa.field_make("name", oa.String_Type{}),
	})
	defer oa.schema_free(&schema)

	ib := oa.builder_make(i32, 3)
	id_vals := []i32{1, 2, 3}
	for v in id_vals { oa.builder_append(&ib, v) }
	ids, _ := oa.builder_finish(&ib)
	oa.builder_destroy(&ib)

	sb := oa.string_builder_make(3)
	name_vals := []string{"ada", "alan", "grace"}
	for w in name_vals { oa.string_builder_append(&sb, w) }
	names, _ := oa.string_builder_finish(&sb)
	oa.string_builder_destroy(&sb)

	// The batch takes ownership of the column buffers — free via the batch only.
	batch, _ := oa.record_batch_make(&schema, []oa.Array{ids, names})
	defer oa.record_batch_free(&batch)

	if !oa.ipc_write_file(path, &schema, []oa.Record_Batch{batch}) {
		fmt.println("  write failed"); return
	}
	fmt.printfln("  wrote %s (readable by pyarrow.ipc.open_file)", path)

	// Read it back — columns are zero-copy views into the memory-mapped file.
	sc, batches, ok := oa.ipc_read_file(path)
	if !ok { fmt.println("  read failed"); return }
	defer {
		oa.schema_free(sc); free(sc)
		for bx in batches { bc := bx; oa.record_batch_free(&bc) }
		delete(batches)
	}

	col_id   := oa.record_batch_column_at(&batches[0], 0)
	col_name := oa.record_batch_column_at(&batches[0], 1)
	fmt.printfln("  read back %d row(s):", batches[0].length)
	for i in 0..<batches[0].length {
		fmt.printfln("    id=%d name=%q", oa.array_get(col_id, i, i32), oa.array_get_string(col_name, i))
	}
}
