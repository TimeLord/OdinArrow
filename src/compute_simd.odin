package odinarrow

import "base:intrinsics"

// SIMD-accelerated inner kernels.  All procs assume offset == 0; callers must
// advance the pointer by the array offset before calling.
//
// Strategy:
//   f64 sum : 4-wide SIMD with 4 unrolled accumulators (hides 4-cycle VADDPD latency)
//   i32 sum : 4-wide i64 SIMD (sign-extends i32 → i64 to prevent overflow)
//   min/max : 8-way scalar unroll so LLVM emits vpminsd/vpmaxsd ymm (AVX2)
//   min+max : single pass combined; ~2× faster than two separate passes

// ── f64 sum ───────────────────────────────────────────────────────────────────

_sum_f64_simd :: #force_inline proc "contextless" (data: [^]f64, n: int) -> f64 {
	V  :: #simd[4]f64
	vp := cast([^]V)data
	nv := n / 4

	// 4 independent accumulators break the 4-cycle VADDPD dependency chain.
	a, b, c, d: V = {}, {}, {}, {}
	v4 := nv / 4
	for i in 0..<v4 {
		j := i * 4
		a += vp[j]; b += vp[j+1]; c += vp[j+2]; d += vp[j+3]
	}
	acc := a + b + c + d
	for i := v4 * 4; i < nv; i += 1 { acc += vp[i] }

	sum := intrinsics.simd_reduce_add_ordered(acc)
	for i := nv * 4; i < n; i += 1 { sum += data[i] }
	return sum
}

// ── i32 sum ───────────────────────────────────────────────────────────────────

// 8-way unrolled i64 accumulation; LLVM emits vpmovsxdq + vpaddq (AVX2).
_sum_i32_simd :: #force_inline proc "contextless" (data: [^]i32, n: int) -> i64 {
	a0, a1, a2, a3, a4, a5, a6, a7: i64 = 0, 0, 0, 0, 0, 0, 0, 0
	i := 0
	for i + 8 <= n {
		a0 += i64(data[i]);   a1 += i64(data[i+1])
		a2 += i64(data[i+2]); a3 += i64(data[i+3])
		a4 += i64(data[i+4]); a5 += i64(data[i+5])
		a6 += i64(data[i+6]); a7 += i64(data[i+7])
		i += 8
	}
	sum := a0 + a1 + a2 + a3 + a4 + a5 + a6 + a7
	for ; i < n; i += 1 { sum += i64(data[i]) }
	return sum
}

// ── i32 min / max ─────────────────────────────────────────────────────────────

_min_i32_simd :: #force_inline proc "contextless" (data: [^]i32, n: int) -> i32 {
	a, b, c, d, e, f, g, h := data[0], data[0], data[0], data[0],
	                           data[0], data[0], data[0], data[0]
	i := 0
	for i + 8 <= n {
		a = min(a, data[i]);   b = min(b, data[i+1])
		c = min(c, data[i+2]); d = min(d, data[i+3])
		e = min(e, data[i+4]); f = min(f, data[i+5])
		g = min(g, data[i+6]); h = min(h, data[i+7])
		i += 8
	}
	best := min(min(min(a, b), min(c, d)), min(min(e, f), min(g, h)))
	for ; i < n; i += 1 { best = min(best, data[i]) }
	return best
}

_max_i32_simd :: #force_inline proc "contextless" (data: [^]i32, n: int) -> i32 {
	a, b, c, d, e, f, g, h := data[0], data[0], data[0], data[0],
	                           data[0], data[0], data[0], data[0]
	i := 0
	for i + 8 <= n {
		a = max(a, data[i]);   b = max(b, data[i+1])
		c = max(c, data[i+2]); d = max(d, data[i+3])
		e = max(e, data[i+4]); f = max(f, data[i+5])
		g = max(g, data[i+6]); h = max(h, data[i+7])
		i += 8
	}
	best := max(max(max(a, b), max(c, d)), max(max(e, f), max(g, h)))
	for ; i < n; i += 1 { best = max(best, data[i]) }
	return best
}

// ── i32 min+max combined ──────────────────────────────────────────────────────

// Single-pass min and max.  Returns (min, max); n must be > 0.
_min_max_i32_simd :: #force_inline proc "contextless" (data: [^]i32, n: int) -> (lo: i32, hi: i32) {
	lo_a, lo_b, lo_c, lo_d := data[0], data[0], data[0], data[0]
	hi_a, hi_b, hi_c, hi_d := data[0], data[0], data[0], data[0]
	i := 0
	for i + 4 <= n {
		lo_a = min(lo_a, data[i]);   hi_a = max(hi_a, data[i])
		lo_b = min(lo_b, data[i+1]); hi_b = max(hi_b, data[i+1])
		lo_c = min(lo_c, data[i+2]); hi_c = max(hi_c, data[i+2])
		lo_d = min(lo_d, data[i+3]); hi_d = max(hi_d, data[i+3])
		i += 4
	}
	lo = min(min(lo_a, lo_b), min(lo_c, lo_d))
	hi = max(max(hi_a, hi_b), max(hi_c, hi_d))
	for ; i < n; i += 1 { lo = min(lo, data[i]); hi = max(hi, data[i]) }
	return
}
