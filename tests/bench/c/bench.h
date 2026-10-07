/* Shared helpers for the C twins of the tests/bench programs (bench_lib.w).
 *
 * Each <name>.c is a line-for-line port of tests/bench/<name>.w: the same
 * algorithm, the same data, the same default size and the same output
 * line, so `tools/bench_vs_c.sh` can compare W's code generation against
 * gcc -O2 / clang -O2 on identical work. Where a W program leans on a
 * library (lib/sha256.w, lib/regex.w, the container runtime's hash table
 * and sort, libs/extras/compress/inflate.w) the C file carries a
 * straightforward port of that W code rather than calling a system
 * library, so the comparison measures codegen, not library quality.
 *
 * W's `int` is word-sized (32 bits on x86, 64 on x64); `word` below is
 * its C counterpart (`long` on Linux is 32 bits under -m32, 64 otherwise).
 * Checksums are 32-bit, as in bench_lib.w. */
#ifndef W_BENCH_H
#define W_BENCH_H
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef long word;
typedef unsigned long uword;

static inline word bench_size(int argc, char** argv, word default_size) {
	if (argc < 2) return default_size;
	word n = atol(argv[1]);
	if (n < 1) return default_size;
	return n;
}

static inline void bench_report(const char* name, word size, uint32_t checksum) {
	printf("%s size=%ld checksum=%08x\n", name, (long)size, (unsigned)checksum);
}

static inline uint32_t bench_fold(uint32_t h, uint32_t v) {
	return h * 31u + v;
}

/* xorshift32, as bench_lib.w's bench_rand. */
static inline uint32_t bench_rand(uint32_t* state) {
	uint32_t x = *state;
	x ^= x << 13;
	x ^= x >> 17;
	x ^= x << 5;
	*state = x;
	return x;
}

#endif
