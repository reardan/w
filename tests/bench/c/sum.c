/* C twin of tests/bench/sum.w (see bench.h). The sum wraps in the word;
 * unsigned so the wrap is defined. Note that gcc/clang at -O2 fold this
 * loop into a closed form, so the C row measures the optimiser, not a
 * loop: that is the honest ceiling. */
#include "bench.h"

static uword sum_to(uword n) {
	uword i = 0;
	uword s = 0;
	while (i < n) {
		s = s + i;
		i = i + 1;
	}
	return s;
}

int main(int argc, char** argv) {
	word n = bench_size(argc, argv, 600000000);
	uword s = sum_to((uword)n);
	bench_report("sum", n, (uint32_t)s);
	return 0;
}
