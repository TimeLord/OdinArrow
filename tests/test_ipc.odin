package odinarrow_tests

import "core:testing"
import "core:os"
import oa "../src"

// ── helpers ───────────────────────────────────────────────────────────────────

make_i32_array :: proc(vals: []i32) -> oa.Array {
    b := oa.builder_make(i32, len(vals))
    defer oa.builder_destroy(&b)
    for v in vals { oa.builder_append(&b, v) }
    arr, _ := oa.builder_finish(&b)
    return arr
}

make_f64_array :: proc(vals: []f64) -> oa.Array {
    b := oa.builder_make(f64, len(vals))
    defer oa.builder_destroy(&b)
    for v in vals { oa.builder_append(&b, v) }
    arr, _ := oa.builder_finish(&b)
    return arr
}

make_string_array :: proc(vals: []string) -> oa.Array {
    b := oa.string_builder_make(len(vals))
    defer oa.string_builder_destroy(&b)
    for v in vals { oa.string_builder_append(&b, v) }
    arr, _ := oa.string_builder_finish(&b)
    return arr
}

// ── IPC round-trip ────────────────────────────────────────────────────────────

@(test)
test_ipc_write_read_i32 :: proc(t: ^testing.T) {
    path := "/tmp/test_ipc_i32.arrow"
    defer os.remove(path)

    // Build schema + batch
    fields := []oa.Field{oa.field_make("x", oa.Int32_Type{}), oa.field_make("y", oa.Int32_Type{})}
    schema, _ := oa.schema_make(fields)
    defer oa.schema_free(&schema)

    col_x := make_i32_array([]i32{1, 2, 3, 4, 5})
    col_y := make_i32_array([]i32{10, 20, 30, 40, 50})
    // batch takes ownership of the column buffers; do not free col_x/col_y separately
    cols := []oa.Array{col_x, col_y}
    batch, ok := oa.record_batch_make(&schema, cols)
    testing.expect(t, ok, "record_batch_make failed")
    defer oa.record_batch_free(&batch)

    // Write
    write_ok := oa.ipc_write_file(path, &schema, []oa.Record_Batch{batch})
    testing.expect(t, write_ok, "ipc_write_file failed")

    // Read back
    schema2, batches, read_ok := oa.ipc_read_file(path)
    testing.expect(t, read_ok, "ipc_read_file failed")
    defer {
        oa.schema_free(schema2)
        free(schema2)
        for bx in batches { bc := bx; oa.record_batch_free(&bc) }
        delete(batches)
    }

    testing.expect_value(t, len(batches), 1)
    testing.expect_value(t, batches[0].length, 5)
    testing.expect_value(t, len(schema2.fields), 2)
    testing.expect_value(t, schema2.fields[0].name, "x")
    testing.expect_value(t, schema2.fields[1].name, "y")

    x := oa.record_batch_column(&batches[0], "x")
    testing.expect(t, x != nil)
    testing.expect_value(t, oa.array_get(x, 0, i32), i32(1))
    testing.expect_value(t, oa.array_get(x, 4, i32), i32(5))

    y := oa.record_batch_column(&batches[0], "y")
    testing.expect(t, y != nil)
    testing.expect_value(t, oa.array_get(y, 2, i32), i32(30))
}

@(test)
test_ipc_write_read_f64 :: proc(t: ^testing.T) {
    path := "/tmp/test_ipc_f64.arrow"
    defer os.remove(path)

    fields := []oa.Field{oa.field_make("v", oa.Float64_Type{})}
    schema, _ := oa.schema_make(fields)
    defer oa.schema_free(&schema)

    col := make_f64_array([]f64{1.5, 2.5, 3.5})
    cols := []oa.Array{col}
    batch, _ := oa.record_batch_make(&schema, cols)
    defer oa.record_batch_free(&batch)

    write_ok := oa.ipc_write_file(path, &schema, []oa.Record_Batch{batch})
    testing.expect(t, write_ok)

    schema2, batches, ok := oa.ipc_read_file(path)
    testing.expect(t, ok)
    defer {
        oa.schema_free(schema2)
        free(schema2)
        for bx in batches { bc := bx; oa.record_batch_free(&bc) }
        delete(batches)
    }

    testing.expect_value(t, len(batches), 1)
    v := oa.record_batch_column(&batches[0], "v")
    testing.expect(t, v != nil)
    testing.expect(t, approx_eq(oa.array_get(v, 0, f64), 1.5, 1e-10))
    testing.expect(t, approx_eq(oa.array_get(v, 2, f64), 3.5, 1e-10))
}

@(test)
test_ipc_write_read_string :: proc(t: ^testing.T) {
    path := "/tmp/test_ipc_str.arrow"
    defer os.remove(path)

    fields := []oa.Field{oa.field_make("name", oa.String_Type{})}
    schema, _ := oa.schema_make(fields)
    defer oa.schema_free(&schema)

    col := make_string_array([]string{"alice", "bob", "charlie"})
    cols := []oa.Array{col}
    batch, _ := oa.record_batch_make(&schema, cols)
    defer oa.record_batch_free(&batch)

    write_ok := oa.ipc_write_file(path, &schema, []oa.Record_Batch{batch})
    testing.expect(t, write_ok)

    schema2, batches, ok := oa.ipc_read_file(path)
    testing.expect(t, ok)
    defer {
        oa.schema_free(schema2)
        free(schema2)
        for bx in batches { bc := bx; oa.record_batch_free(&bc) }
        delete(batches)
    }

    testing.expect_value(t, len(batches), 1)
    nm := oa.record_batch_column(&batches[0], "name")
    testing.expect(t, nm != nil)
    testing.expect_value(t, oa.array_get_string(nm, 0), "alice")
    testing.expect_value(t, oa.array_get_string(nm, 2), "charlie")
}

// ── IPC stream format ─────────────────────────────────────────────────────────

@(test)
test_ipc_stream_roundtrip :: proc(t: ^testing.T) {
    path := "/tmp/test_ipc_stream.arrows"
    defer os.remove(path)

    fields := []oa.Field{oa.field_make("n", oa.Int32_Type{})}
    schema, _ := oa.schema_make(fields)
    defer oa.schema_free(&schema)

    a1 := make_i32_array([]i32{1, 2, 3})
    a2 := make_i32_array([]i32{4, 5})
    b1, _ := oa.record_batch_make(&schema, []oa.Array{a1})
    b2, _ := oa.record_batch_make(&schema, []oa.Array{a2})
    defer oa.record_batch_free(&b1); defer oa.record_batch_free(&b2)

    write_ok := oa.ipc_write_stream(path, &schema, []oa.Record_Batch{b1, b2})
    testing.expect(t, write_ok, "ipc_write_stream failed")

    schema2, batches, read_ok := oa.ipc_read_stream(path)
    testing.expect(t, read_ok, "ipc_read_stream failed")
    defer {
        oa.schema_free(schema2)
        free(schema2)
        for bx in batches { bc := bx; oa.record_batch_free(&bc) }
        delete(batches)
    }

    testing.expect_value(t, len(batches), 2)
    testing.expect_value(t, len(schema2.fields), 1)
    testing.expect_value(t, schema2.fields[0].name, "n")
    testing.expect_value(t, batches[0].length, 3)
    testing.expect_value(t, batches[1].length, 2)

    c0 := oa.record_batch_column_at(&batches[0], 0)
    c1 := oa.record_batch_column_at(&batches[1], 0)
    testing.expect_value(t, oa.array_get(c0, 0, i32), i32(1))
    testing.expect_value(t, oa.array_get(c0, 2, i32), i32(3))
    testing.expect_value(t, oa.array_get(c1, 1, i32), i32(5))
}

@(test)
test_ipc_stream_string :: proc(t: ^testing.T) {
    path := "/tmp/test_ipc_stream_str.arrows"
    defer os.remove(path)

    fields := []oa.Field{oa.field_make("s", oa.String_Type{})}
    schema, _ := oa.schema_make(fields)
    defer oa.schema_free(&schema)

    col := make_string_array([]string{"one", "two", "three"})
    batch, _ := oa.record_batch_make(&schema, []oa.Array{col})
    defer oa.record_batch_free(&batch)

    testing.expect(t, oa.ipc_write_stream(path, &schema, []oa.Record_Batch{batch}))

    schema2, batches, ok := oa.ipc_read_stream(path)
    testing.expect(t, ok)
    defer {
        oa.schema_free(schema2)
        free(schema2)
        for bx in batches { bc := bx; oa.record_batch_free(&bc) }
        delete(batches)
    }

    testing.expect_value(t, len(batches), 1)
    s := oa.record_batch_column_at(&batches[0], 0)
    testing.expect_value(t, oa.array_get_string(s, 0), "one")
    testing.expect_value(t, oa.array_get_string(s, 2), "three")
}

@(test)
test_ipc_multiple_batches :: proc(t: ^testing.T) {
    path := "/tmp/test_ipc_multi.arrow"
    defer os.remove(path)

    fields := []oa.Field{oa.field_make("n", oa.Int32_Type{})}
    schema, _ := oa.schema_make(fields)
    defer oa.schema_free(&schema)

    a1 := make_i32_array([]i32{1, 2, 3})
    a2 := make_i32_array([]i32{4, 5})
    c1 := []oa.Array{a1}; c2 := []oa.Array{a2}
    b1, _ := oa.record_batch_make(&schema, c1)
    b2, _ := oa.record_batch_make(&schema, c2)
    defer oa.record_batch_free(&b1); defer oa.record_batch_free(&b2)

    batches_in := []oa.Record_Batch{b1, b2}
    oa.ipc_write_file(path, &schema, batches_in)

    schema2, batches, ok := oa.ipc_read_file(path)
    testing.expect(t, ok)
    defer {
        oa.schema_free(schema2)
        free(schema2)
        for bx in batches { bc := bx; oa.record_batch_free(&bc) }
        delete(batches)
    }

    testing.expect_value(t, len(batches), 2)
    testing.expect_value(t, batches[0].length, 3)
    testing.expect_value(t, batches[1].length, 2)

    col0 := oa.record_batch_column_at(&batches[0], 0)
    col1 := oa.record_batch_column_at(&batches[1], 0)
    testing.expect_value(t, oa.array_get(col0, 2, i32), i32(3))
    testing.expect_value(t, oa.array_get(col1, 1, i32), i32(5))
}
