package opyarrow_tests

import "core:mem"
import "core:testing"
import oa "../src"

// ── helpers ──────────────────────────────────────────────────────────────────

setup_tracking :: proc(t: ^testing.T) -> (track: mem.Tracking_Allocator) {
	mem.tracking_allocator_init(&track, context.allocator)
	return
}

check_no_leaks :: proc(t: ^testing.T, track: ^mem.Tracking_Allocator) {
	for _, leak in track.allocation_map {
		testing.expectf(t, false, "memory leak: %v bytes at %v", leak.size, leak.location)
	}
	mem.tracking_allocator_destroy(track)
}

// ── alignment ────────────────────────────────────────────────────────────────

@(test)
test_buffer_is_64_byte_aligned :: proc(t: ^testing.T) {
	sizes := []int{0, 1, 63, 64, 65, 127, 128, 1024, 10001}
	for size in sizes {
		buf, err := oa.buffer_make(size)
		defer oa.buffer_free(&buf)
		testing.expect(t, err == nil, "allocation must succeed")
		testing.expect(
			t,
			uintptr(buf.data) % oa.ARROW_ALIGNMENT == 0,
			"data pointer must be 64-byte aligned",
		)
	}
}

@(test)
test_buffer_capacity_is_multiple_of_alignment :: proc(t: ^testing.T) {
	sizes2 := []int{0, 1, 63, 64, 65, 200}
	for size in sizes2 {
		buf, _ := oa.buffer_make(size)
		defer oa.buffer_free(&buf)
		testing.expect(
			t,
			buf.capacity % oa.ARROW_ALIGNMENT == 0,
			"capacity must be multiple of ARROW_ALIGNMENT",
		)
		testing.expect(t, buf.capacity >= size, "capacity must cover requested size")
	}
}

// ── zero initialisation ───────────────────────────────────────────────────────

@(test)
test_buffer_is_zero_initialised :: proc(t: ^testing.T) {
	buf, _ := oa.buffer_make(128)
	defer oa.buffer_free(&buf)
	for i in 0..<buf.size {
		testing.expect(t, buf.data[i] == 0, "every byte must start at zero")
	}
}

// ── size 0 edge case ─────────────────────────────────────────────────────────

@(test)
test_buffer_size_zero :: proc(t: ^testing.T) {
	buf, err := oa.buffer_make(0)
	defer oa.buffer_free(&buf)
	testing.expect(t, err == nil)
	testing.expect(t, buf.size == 0)
	testing.expect(t, buf.capacity >= oa.ARROW_ALIGNMENT)
	testing.expect(t, buf.data != nil, "even a zero-size buffer must have a valid pointer")
}

// ── resize ────────────────────────────────────────────────────────────────────

@(test)
test_buffer_resize_grow_preserves_data :: proc(t: ^testing.T) {
	buf, _ := oa.buffer_make(64)
	defer oa.buffer_free(&buf)

	buf.data[0]  = 0xAB
	buf.data[63] = 0xCD

	err := oa.buffer_resize(&buf, 128)
	testing.expect(t, err == nil, "resize must succeed")
	testing.expect_value(t, buf.size, 128)
	testing.expect_value(t, buf.data[0], u8(0xAB))
	testing.expect_value(t, buf.data[63], u8(0xCD))
}

@(test)
test_buffer_resize_grow_zeroes_new_region :: proc(t: ^testing.T) {
	buf, _ := oa.buffer_make(64)
	defer oa.buffer_free(&buf)

	oa.buffer_resize(&buf, 192)
	for i in 64..<192 {
		testing.expect(t, buf.data[i] == 0, "newly grown region must be zero")
	}
}

@(test)
test_buffer_resize_shrink_no_realloc :: proc(t: ^testing.T) {
	buf, _ := oa.buffer_make(128)
	defer oa.buffer_free(&buf)

	orig_cap := buf.capacity
	buf.data[0] = 0x55

	oa.buffer_resize(&buf, 32)
	testing.expect_value(t, buf.size, 32)
	testing.expect_value(t, buf.capacity, orig_cap) // capacity unchanged
	testing.expect_value(t, buf.data[0], u8(0x55))
}

// ── slice (zero-copy view) ────────────────────────────────────────────────────

@(test)
test_buffer_slice_shares_memory :: proc(t: ^testing.T) {
	buf, _ := oa.buffer_make(128)
	defer oa.buffer_free(&buf)

	buf.data[10] = 0xFF
	view := oa.buffer_slice(&buf, 10, 20)

	// Read through slice sees original write
	testing.expect_value(t, view.data[0], u8(0xFF))
	testing.expect_value(t, view.size, 10)

	// Write through slice is visible in original buffer
	view.data[0] = 0x42
	testing.expect_value(t, buf.data[10], u8(0x42))

	// Pointer identity
	testing.expect(
		t,
		uintptr(view.data) == uintptr(buf.data) + 10,
		"slice data must point into parent buffer",
	)
}

@(test)
test_buffer_slice_zero_length :: proc(t: ^testing.T) {
	buf, _ := oa.buffer_make(64)
	defer oa.buffer_free(&buf)

	view := oa.buffer_slice(&buf, 32, 32)
	testing.expect_value(t, view.size, 0)
}

// ── deep copy ────────────────────────────────────────────────────────────────

@(test)
test_buffer_copy_is_independent :: proc(t: ^testing.T) {
	src, _ := oa.buffer_make(64)
	defer oa.buffer_free(&src)
	src.data[7] = 0xBE

	dst, err := oa.buffer_copy(&src)
	defer oa.buffer_free(&dst)
	testing.expect(t, err == nil)
	testing.expect_value(t, dst.data[7], u8(0xBE))

	// Mutate source — destination must be unaffected
	src.data[7] = 0x00
	testing.expect_value(t, dst.data[7], u8(0xBE))
}

// ── no memory leaks ───────────────────────────────────────────────────────────

@(test)
test_buffer_no_leak :: proc(t: ^testing.T) {
	track := setup_tracking(t)
	defer check_no_leaks(t, &track)
	context.allocator = mem.tracking_allocator(&track)

	buf, _ := oa.buffer_make(256)
	oa.buffer_resize(&buf, 512)
	oa.buffer_free(&buf)
}

// ── align_up ──────────────────────────────────────────────────────────────────

@(test)
test_align_up :: proc(t: ^testing.T) {
	cases := [][3]int{
		// align_up(0, n) = 0: zero is already aligned to every power of 2
		{0,  64, 0},
		{0,  8,  0},
		{1,  64, 64},
		{63, 64, 64},
		{64, 64, 64},
		{65, 64, 128},
		{7,  8,  8},
		{8,  8,  8},
		{9,  8,  16},
	}
	for c in cases {
		got := oa.align_up(c[0], c[1])
		testing.expect_value(t, got, c[2])
	}
}
