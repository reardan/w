/* C twin of tests/bench/matmul_256.w (see bench.h): word-sized matrix
 * elements, every result masked to 32 bits. */
#include "bench.h"

#define MM_N 256

static void matmul(uword* a, uword* b, uword* out, word n) {
	word i = 0;
	while (i < n) {
		word j = 0;
		while (j < n) {
			uword acc = 0;
			word k = 0;
			while (k < n) {
				acc = acc + a[i * n + k] * b[k * n + j];
				k = k + 1;
			}
			out[i * n + j] = (uint32_t)acc;
			j = j + 1;
		}
		i = i + 1;
	}
}

int main(int argc, char** argv) {
	word reps = bench_size(argc, argv, 10);
	word n = MM_N;
	uword* a = malloc(n * n * sizeof(uword));
	uword* b = malloc(n * n * sizeof(uword));
	uword* out = malloc(n * n * sizeof(uword));
	uint32_t state = 123456789;
	word i = 0;
	while (i < n * n) {
		a[i] = bench_rand(&state) & 0xffff;
		b[i] = bench_rand(&state) & 0xffff;
		i = i + 1;
	}
	word r = 0;
	while (r < reps) {
		matmul(a, b, out, n);
		uword* swap = a;
		a = out;
		out = swap;
		r = r + 1;
	}
	uint32_t h = 0;
	i = 0;
	while (i < n * n) {
		h = bench_fold(h, (uint32_t)a[i]);
		i = i + 1;
	}
	bench_report("matmul_256", reps, h);
	return 0;
}
