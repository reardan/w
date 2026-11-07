/* C driver for tests/object_layout/layout_library.w (tests/object_layout_test.w). */
#include <stdio.h>
#include <string.h>

long layout_register(const char *name);
long layout_value_call(long a);
void *layout_lock(void);

static long recorded_flags;

long c_record(const char *name, long flags)
{
	recorded_flags = flags;
	return strcmp(name, "rootfs") == 0 ? 40 : -1;
}

long c_twice(long a, long b)
{
	return 2 * a + b;
}

int main(void)
{
	if (layout_register("rootfs") != 40 || recorded_flags != 7) {
		printf("record call failed: %ld\n", recorded_flags);
		return 1;
	}
	if (layout_value_call(20) != 41) {
		printf("value call failed\n");
		return 1;
	}
	if (layout_lock() == 0) {
		printf("lock address missing\n");
		return 1;
	}
	printf("object layout OK\n");
	return 0;
}
