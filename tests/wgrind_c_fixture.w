# Prove Memcheck sees allocations made by libc, outside W's allocator.
import lib.lib
c_lib "libc.so.6"
extern void* c_malloc(int size) = "malloc"
extern void c_free(void* p) = "free"
extern void* c_memset(void* p, int value, int size) = "memset"


int main():
	char* p = cast(char*, c_malloc(13))
	# Both the allocation and the invalid write take place in libc.
	c_memset(p + 13, 1, 1)
	c_free(p)
	return 0
