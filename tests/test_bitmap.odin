package opyarrow_tests

import "core:testing"
import oa "../src"

// ── byte count ────────────────────────────────────────────────────────────────

@(test)
test_bitmap_byte_count :: proc(t: ^testing.T) {
	cases := [][2]int{
		// 0 bits → 0 bytes (no bitmap needed)
		{0,   0},
		{1,   64},
		{8,   64},
		{63,  64},
		{64,  64},
		{65,  64},
		{512, 64},
		{513, 128},
	}
	for c in cases {
		got := oa.bitmap_byte_count(c[0])
		testing.expect_value(t, got, c[1])
		testing.expect(t, got % oa.ARROW_ALIGNMENT == 0, "byte count must be aligned")
	}
}

// ── set / get / clear ─────────────────────────────────────────────────────────

@(test)
test_bitmap_set_get_single :: proc(t: ^testing.T) {
	buf, _ := oa.buffer_make(oa.bitmap_byte_count(64))
	defer oa.buffer_free(&buf)

	oa.bitmap_set(buf.data, 0)
	testing.expect(t, oa.bitmap_get(buf.data, 0), "bit 0 must be set")
	testing.expect(t, !oa.bitmap_get(buf.data, 1), "bit 1 must remain clear")
}

@(test)
test_bitmap_clear_after_set :: proc(t: ^testing.T) {
	buf, _ := oa.buffer_make(oa.bitmap_byte_count(64))
	defer oa.buffer_free(&buf)

	oa.bitmap_set(buf.data, 5)
	testing.expect(t, oa.bitmap_get(buf.data, 5))
	oa.bitmap_clear(buf.data, 5)
	testing.expect(t, !oa.bitmap_get(buf.data, 5), "bit 5 must be clear after bitmap_clear")
}

// Exhaustively check every bit position in a 64-bit window
@(test)
test_bitmap_all_positions_in_64_bits :: proc(t: ^testing.T) {
	buf, _ := oa.buffer_make(oa.bitmap_byte_count(64))
	defer oa.buffer_free(&buf)

	for pos in 0..<64 {
		// Set one bit, verify only that bit is set
		oa.bitmap_set(buf.data, pos)
		for probe in 0..<64 {
			got := oa.bitmap_get(buf.data, probe)
			if probe == pos {
				testing.expect(t, got, "the set bit must read back as 1")
			} else {
				testing.expect(t, !got, "neighbouring bits must stay 0")
			}
		}
		oa.bitmap_clear(buf.data, pos)
	}
}

// ── set_all ───────────────────────────────────────────────────────────────────

@(test)
test_bitmap_set_all_correctness :: proc(t: ^testing.T) {
	sizes := []int{1, 7, 8, 9, 63, 64, 65, 128, 200}
	for n_bits in sizes {
		buf, _ := oa.buffer_make(oa.bitmap_byte_count(n_bits))
		defer oa.buffer_free(&buf)

		oa.bitmap_set_all(buf.data, n_bits)

		// Every bit in range must be set
		for i in 0..<n_bits {
			testing.expect(t, oa.bitmap_get(buf.data, i), "bit in range must be 1 after set_all")
		}
		// Bits beyond n_bits in the last byte must be 0 (invariant for popcount)
		n_bytes := (n_bits + 7) / 8
		remainder := n_bits % 8
		if remainder != 0 {
			last := buf.data[n_bytes - 1]
			mask := u8((1 << uint(remainder)) - 1)
			testing.expect(t, last == mask, "bits beyond n_bits in last byte must be 0")
		}
	}
}

// ── clear_all ─────────────────────────────────────────────────────────────────

@(test)
test_bitmap_clear_all :: proc(t: ^testing.T) {
	n_bits := 128
	buf, _ := oa.buffer_make(oa.bitmap_byte_count(n_bits))
	defer oa.buffer_free(&buf)

	oa.bitmap_set_all(buf.data, n_bits)
	n_bytes := oa.bitmap_byte_count(n_bits)
	oa.bitmap_clear_all(buf.data, n_bytes)

	for i in 0..<n_bits {
		testing.expect(t, !oa.bitmap_get(buf.data, i), "all bits must be 0 after clear_all")
	}
}

// ── popcount ──────────────────────────────────────────────────────────────────

@(test)
test_bitmap_popcount_zero :: proc(t: ^testing.T) {
	buf, _ := oa.buffer_make(64)
	defer oa.buffer_free(&buf)
	testing.expect_value(t, oa.bitmap_popcount(buf.data, 0), 0)
	testing.expect_value(t, oa.bitmap_popcount(buf.data, 64), 0)
}

@(test)
test_bitmap_popcount_all_set :: proc(t: ^testing.T) {
	sizes2 := []int{1, 8, 64, 65, 128, 511, 512}
	for n_bits in sizes2 {
		buf, _ := oa.buffer_make(oa.bitmap_byte_count(n_bits))
		defer oa.buffer_free(&buf)

		oa.bitmap_set_all(buf.data, n_bits)
		got := oa.bitmap_popcount(buf.data, n_bits)
		testing.expect_value(t, got, n_bits)
	}
}

@(test)
test_bitmap_popcount_every_other :: proc(t: ^testing.T) {
	n_bits := 128
	buf, _ := oa.buffer_make(oa.bitmap_byte_count(n_bits))
	defer oa.buffer_free(&buf)

	// Set even-numbered bits
	for i := 0; i < n_bits; i += 2 {
		oa.bitmap_set(buf.data, i)
	}
	got := oa.bitmap_popcount(buf.data, n_bits)
	testing.expect_value(t, got, n_bits / 2)
}

@(test)
test_bitmap_popcount_known_pattern :: proc(t: ^testing.T) {
	buf, _ := oa.buffer_make(64)
	defer oa.buffer_free(&buf)

	// Set bits 0, 3, 7 — popcount must be 3
	oa.bitmap_set(buf.data, 0)
	oa.bitmap_set(buf.data, 3)
	oa.bitmap_set(buf.data, 7)
	testing.expect_value(t, oa.bitmap_popcount(buf.data, 8), 3)
}

// Large test: popcount on 10M bits (exercises the u64 fast path)
@(test)
test_bitmap_popcount_large :: proc(t: ^testing.T) {
	n_bits := 10_000_000
	buf, _ := oa.buffer_make(oa.bitmap_byte_count(n_bits))
	defer oa.buffer_free(&buf)

	oa.bitmap_set_all(buf.data, n_bits)
	got := oa.bitmap_popcount(buf.data, n_bits)
	testing.expect_value(t, got, n_bits)
}

// popcount must mask out bits beyond n_bits even when the raw byte has them set.
// This is what makes slice-range counting correct (a slice endpoint can land
// mid-byte where neighbouring elements have set bits).
@(test)
test_bitmap_popcount_masks_last_byte :: proc(t: ^testing.T) {
	buf, _ := oa.buffer_make(64)
	defer oa.buffer_free(&buf)

	buf.data[0] = 0xFF // all 8 bits set in the raw byte
	testing.expect_value(t, oa.bitmap_popcount(buf.data, 5), 5) // only first 5 count
	testing.expect_value(t, oa.bitmap_popcount(buf.data, 1), 1)
	testing.expect_value(t, oa.bitmap_popcount(buf.data, 8), 8) // full byte: no masking needed
}
