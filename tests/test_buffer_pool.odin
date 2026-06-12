package odinarrow_tests

import "core:testing"
import oa "../src"

// A build → free → build cycle through a Buffer_Pool should reuse the same
// underlying block (warm pages), and the values must still be correct.
@(test)
test_buffer_pool_reuse :: proc(t: ^testing.T) {
	pool: oa.Buffer_Pool
	oa.buffer_pool_init(&pool)
	defer oa.buffer_pool_destroy(&pool)
	alloc := oa.buffer_pool_allocator(&pool)

	// First build.
	b1 := oa.builder_make(i32, 1000, alloc)
	for i in 0..<1000 { oa.builder_append(&b1, i32(i)) }
	a1, _ := oa.builder_finish(&b1, alloc)
	ptr1 := a1.buffers[1].data
	testing.expect_value(t, oa.array_get(&a1, 999, i32), i32(999))

	// Return it to the pool.
	oa.array_free(&a1)
	oa.builder_destroy(&b1)

	// Second build of the same size should reuse the same data block.
	b2 := oa.builder_make(i32, 1000, alloc)
	for i in 0..<1000 { oa.builder_append(&b2, i32(2 * i)) }
	a2, _ := oa.builder_finish(&b2, alloc)
	ptr2 := a2.buffers[1].data
	defer { oa.array_free(&a2); oa.builder_destroy(&b2) }

	testing.expect(t, ptr1 == ptr2, "pool should hand back the recycled block")
	testing.expect_value(t, oa.array_get(&a2, 0, i32), i32(0))
	testing.expect_value(t, oa.array_get(&a2, 999, i32), i32(1998))
}

// Nulls must round-trip correctly even though reused blocks are not pre-zeroed
// (the validity bitmap is allocated through the zeroing .Alloc path).
@(test)
test_buffer_pool_nulls :: proc(t: ^testing.T) {
	pool: oa.Buffer_Pool
	oa.buffer_pool_init(&pool)
	defer oa.buffer_pool_destroy(&pool)
	alloc := oa.buffer_pool_allocator(&pool)

	// Pre-warm and dirty a same-sized bitmap block, then free it.
	warm := oa.builder_make(i32, 64, alloc)
	for _ in 0..<64 { oa.builder_append_null(&warm) }   // forces a full validity bitmap
	wa, _ := oa.builder_finish(&warm, alloc)
	oa.array_free(&wa); oa.builder_destroy(&warm)

	// New builder of the same shape: every other element null.
	b := oa.builder_make(i32, 64, alloc)
	for i in 0..<64 {
		if i % 2 == 0 { oa.builder_append(&b, i32(i)) }
		else          { oa.builder_append_null(&b) }
	}
	a, _ := oa.builder_finish(&b, alloc)
	defer { oa.array_free(&a); oa.builder_destroy(&b) }

	testing.expect_value(t, a.null_count, 32)
	testing.expect(t, !oa.array_is_null(&a, 0))
	testing.expect(t, oa.array_is_null(&a, 1))
	testing.expect_value(t, oa.array_get(&a, 4, i32), i32(4))
}

// String builders work through the pool too (data, offsets, and validity all
// come from the pool).
@(test)
test_buffer_pool_strings :: proc(t: ^testing.T) {
	pool: oa.Buffer_Pool
	oa.buffer_pool_init(&pool)
	defer oa.buffer_pool_destroy(&pool)
	alloc := oa.buffer_pool_allocator(&pool)

	b := oa.string_builder_make(8, alloc)
	words := []string{"alpha", "beta", "gamma"}
	for w in words { oa.string_builder_append(&b, w) }
	a, _ := oa.string_builder_finish(&b, alloc)
	defer { oa.array_free(&a); oa.string_builder_destroy(&b) }

	testing.expect_value(t, a.length, 3)
	testing.expect_value(t, oa.array_get_string(&a, 0), "alpha")
	testing.expect_value(t, oa.array_get_string(&a, 2), "gamma")
}
