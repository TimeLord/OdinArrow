package odinarrow_tests

import "core:mem"
import "core:testing"
import oa "../src"

// ── Schema ────────────────────────────────────────────────────────────────────

@(test)
test_schema_make_free :: proc(t: ^testing.T) {
	track := setup_tracking(t)
	defer check_no_leaks(t, &track)
	context.allocator = mem.tracking_allocator(&track)

	fields := []oa.Field{
		oa.field_make("id",   oa.Int32_Type{}),
		oa.field_make("name", oa.String_Type{}),
		oa.field_make("val",  oa.Float64_Type{}, false),
	}
	s, err := oa.schema_make(fields)
	testing.expect(t, err == nil)
	testing.expect_value(t, len(s.fields), 3)
	testing.expect_value(t, s.fields[0].name, "id")
	testing.expect_value(t, s.fields[2].nullable, false)
	oa.schema_free(&s)
}

@(test)
test_schema_field_index :: proc(t: ^testing.T) {
	fields := []oa.Field{
		oa.field_make("x", oa.Int32_Type{}),
		oa.field_make("y", oa.Float64_Type{}),
	}
	s, _ := oa.schema_make(fields)
	defer oa.schema_free(&s)

	idx, ok := oa.schema_field_index(&s, "y")
	testing.expect(t, ok)
	testing.expect_value(t, idx, 1)

	_, missing := oa.schema_field_index(&s, "z")
	testing.expect(t, !missing, "field 'z' must not be found")
}

// ── RecordBatch ───────────────────────────────────────────────────────────────

@(test)
test_record_batch_basic :: proc(t: ^testing.T) {
	track := setup_tracking(t)
	defer check_no_leaks(t, &track)
	context.allocator = mem.tracking_allocator(&track)

	fields := []oa.Field{
		oa.field_make("id",  oa.Int32_Type{}),
		oa.field_make("val", oa.Float64_Type{}),
	}
	s, _ := oa.schema_make(fields)
	defer oa.schema_free(&s)

	id_arr  := build_array([]i32{1, 2, 3})
	val_arr := build_array([]f64{1.1, 2.2, 3.3})

	rb, ok := oa.record_batch_make(&s, []oa.Array{id_arr, val_arr})
	testing.expect(t, ok)
	testing.expect_value(t, rb.length, 3)

	col := oa.record_batch_column(&rb, "val")
	testing.expect(t, col != nil)
	testing.expect_value(t, oa.array_get(col, 1, f64), f64(2.2))

	oa.record_batch_free(&rb) // frees id_arr and val_arr copies
}

@(test)
test_record_batch_length_mismatch :: proc(t: ^testing.T) {
	fields := []oa.Field{oa.field_make("a", oa.Int32_Type{}), oa.field_make("b", oa.Int32_Type{})}
	s, _ := oa.schema_make(fields)
	defer oa.schema_free(&s)

	a := build_array([]i32{1, 2, 3})
	b := build_array([]i32{1, 2})
	defer oa.array_free(&a)
	defer oa.array_free(&b)

	_, ok := oa.record_batch_make(&s, []oa.Array{a, b})
	testing.expect(t, !ok, "mismatched column lengths must be rejected")
}

@(test)
test_record_batch_column_count_mismatch :: proc(t: ^testing.T) {
	fields := []oa.Field{oa.field_make("a", oa.Int32_Type{})}
	s, _ := oa.schema_make(fields)
	defer oa.schema_free(&s)

	a := build_array([]i32{1, 2})
	b := build_array([]i32{3, 4})
	defer oa.array_free(&a)
	defer oa.array_free(&b)

	_, ok := oa.record_batch_make(&s, []oa.Array{a, b})
	testing.expect(t, !ok, "extra column must be rejected")
}

// ── Table ─────────────────────────────────────────────────────────────────────

@(test)
test_table_from_batches :: proc(t: ^testing.T) {
	track := setup_tracking(t)
	defer check_no_leaks(t, &track)
	context.allocator = mem.tracking_allocator(&track)

	fields := []oa.Field{oa.field_make("v", oa.Int32_Type{})}
	s, _ := oa.schema_make(fields)
	defer oa.schema_free(&s)

	a1 := build_array([]i32{1, 2, 3})
	a2 := build_array([]i32{4, 5})
	rb1, _ := oa.record_batch_make(&s, []oa.Array{a1})
	rb2, _ := oa.record_batch_make(&s, []oa.Array{a2})

	tbl, ok := oa.table_from_record_batches([]oa.Record_Batch{rb1, rb2})
	testing.expect(t, ok)
	testing.expect_value(t, tbl.length, 5)

	col, found := oa.table_column(&tbl, "v")
	testing.expect(t, found)
	testing.expect_value(t, col.length, 5)

	// ChunkedArray access across chunk boundary
	testing.expect_value(t, oa.chunked_array_get(col, 2, i32), i32(3)) // in chunk 0
	testing.expect_value(t, oa.chunked_array_get(col, 3, i32), i32(4)) // in chunk 1

	oa.table_free(&tbl)
	oa.record_batch_free(&rb1)
	oa.record_batch_free(&rb2)
}

@(test)
test_table_column_null_access :: proc(t: ^testing.T) {
	fields := []oa.Field{oa.field_make("x", oa.Int32_Type{})}
	s, _ := oa.schema_make(fields)
	defer oa.schema_free(&s)

	// Build an array with a null
	bld := oa.builder_make(i32)
	defer oa.builder_destroy(&bld)
	oa.builder_append(&bld, i32(10))
	oa.builder_append_null(&bld)
	col_arr, _ := oa.builder_finish(&bld)

	rb, _ := oa.record_batch_make(&s, []oa.Array{col_arr})
	defer oa.record_batch_free(&rb)

	tbl, ok := oa.table_from_record_batches([]oa.Record_Batch{rb})
	testing.expect(t, ok)
	defer oa.table_free(&tbl)

	col, _ := oa.table_column(&tbl, "x")
	testing.expect(t, !oa.chunked_array_is_null(col, 0))
	testing.expect(t, oa.chunked_array_is_null(col, 1))
}
