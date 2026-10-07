/* C twin of tests/bench/strcmp_sort.w (see bench.h): the same words, sorted
 * by a port of the container runtime's stable bottom-up merge sort
 * (structures/w_list.w __w_list_merge_sort: it sorts a permutation of
 * indices, then applies it once) with the runtime's inline string
 * compare (__w_list_compare_values, kind 2). */
#include "bench.h"

static word compare_cstr(const char* sa, const char* sb) {
	word j = 0;
	while (sa[j] != 0 && sa[j] == sb[j]) j = j + 1;
	return (word)sa[j] - (word)sb[j];
}

static void apply_permutation(char** items, word n, word* perm) {
	char** staged = malloc(n * sizeof(char*));
	word k = 0;
	while (k < n) {
		staged[k] = items[perm[k]];
		k = k + 1;
	}
	memcpy(items, staged, n * sizeof(char*));
	free(staged);
}

static void merge_sort(char** items, word n) {
	if (n < 2) return;
	word* perm = malloc(n * sizeof(word));
	word* tmp = malloc(n * sizeof(word));
	word k = 0;
	while (k < n) {
		perm[k] = k;
		k = k + 1;
	}
	word width = 1;
	while (width < n) {
		word lo = 0;
		while (lo < n) {
			word mid = lo + width;
			if (mid > n) mid = n;
			word hi = mid + width;
			if (hi > n) hi = n;
			word i = lo;
			word j = mid;
			word out = lo;
			while (out < hi) {
				if (i < mid && (j >= hi || compare_cstr(items[perm[i]], items[perm[j]]) <= 0)) {
					tmp[out] = perm[i];
					i = i + 1;
				} else {
					tmp[out] = perm[j];
					j = j + 1;
				}
				out = out + 1;
			}
			lo = hi;
		}
		word* swap = perm;
		perm = tmp;
		tmp = swap;
		width = width * 2;
	}
	apply_permutation(items, n, perm);
	free(perm);
	free(tmp);
}

int main(int argc, char** argv) {
	word n = bench_size(argc, argv, 500000);
	char** words = malloc(n * sizeof(char*));
	uint32_t state = 123456789;
	word i = 0;
	while (i < n) {
		word len = 6 + (bench_rand(&state) & 7);
		char* w = malloc(len + 1);
		word j = 0;
		while (j < len) {
			w[j] = 'a' + ((bench_rand(&state) & 0x7fffffff) % 26);
			j = j + 1;
		}
		w[len] = 0;
		words[i] = w;
		i = i + 1;
	}
	merge_sort(words, n);
	uint32_t h = 0;
	i = 0;
	while (i < n) {
		const char* w = words[i];
		word j = 0;
		while (w[j] != 0) {
			h = bench_fold(h, (uint32_t)w[j]);
			j = j + 1;
		}
		h = bench_fold(h, 0);
		i = i + 1;
	}
	bench_report("strcmp_sort", n, h);
	return 0;
}
