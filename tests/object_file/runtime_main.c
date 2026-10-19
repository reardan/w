/* C host for tests/object_file/runtime_library.w: a W object that keeps
   its private runtime (sets, lists, maps, allocator) next to libc's. */
#include <stdio.h>
#include <stdlib.h>

long w_distinct(long *xs, long n);
long w_histogram_max(long *xs, long n);
extern long w_runtime_calls;

int main(void) {
	long xs[8] = {3, 1, 3, 2, 1, 3, 9, 9};
	char *mine = malloc(64);
	long distinct = w_distinct(xs, 8);
	long most = w_histogram_max(xs, 8);
	free(mine);
	if (distinct != 4 || most != 3 || w_runtime_calls != 2) {
		printf("FAIL %ld %ld %ld\n", distinct, most, w_runtime_calls);
		return 1;
	}
	printf("object runtime OK\n");
	return 0;
}
