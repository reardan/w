/* C twin of tests/bench/sieve.w (see bench.h). */
#include "bench.h"

static uint32_t sieve(word n) {
	char* composite = malloc((size_t)n + 1);
	word i = 0;
	while (i <= n) {
		composite[i] = 0;
		i = i + 1;
	}
	i = 2;
	while (i * i <= n) {
		if (composite[i] == 0) {
			word j = i * i;
			while (j <= n) {
				composite[j] = 1;
				j = j + i;
			}
		}
		i = i + 1;
	}
	word count = 0;
	uint32_t h = 0;
	i = 2;
	while (i <= n) {
		if (composite[i] == 0) {
			count = count + 1;
			h = bench_fold(h, (uint32_t)i);
		}
		i = i + 1;
	}
	free(composite);
	return bench_fold(h, (uint32_t)count);
}

int main(int argc, char** argv) {
	word n = bench_size(argc, argv, 40000000);
	bench_report("sieve", n, sieve(n));
	return 0;
}
