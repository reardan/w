# Element-wise memory helpers: the memcpy/memset/memcmp W lacks. Generic
# over the element type T with counts in ELEMENTS: indexing scales by
# T's width, so there is no `T* + int` byte-offset pitfall (lib/ptr.w).
# Call with the element type inferred (`mem_copy(dst, src, n)`) or
# spelled out (`mem_fill[int32](counts, 0, n)`).
import lib.memory
import lib.lib


# Copies n elements from src to dst, lowest index first. Overlapping
# ranges are only safe when dst precedes src; an LZ77-style match copy
# that must replicate its own output keeps its explicit byte loop.
void mem_copy[T](T* dst, T* src, int n):
	int i = 0
	while (i < n):
		dst[i] = src[i]
		i = i + 1


# Sets the first n elements of dst to v.
void mem_fill[T](T* dst, T v, int n):
	int i = 0
	while (i < n):
		dst[i] = v
		i = i + 1


# 1 when the first n elements of a and b are equal, else 0.
int mem_eq[T](T* a, T* b, int n):
	int i = 0
	while (i < n):
		if (a[i] != b[i]):
			return 0
		i = i + 1
	return 1


# Malloc'd copy of n bytes from src with a convenience NUL appended
# (binary-safe: the NUL is not part of the n bytes). Caller frees.
char* mem_dup(char* src, int n):
	char* out = malloc(n + 1)
	mem_copy(out, src, n)
	out[n] = 0
	return out


# 1 when data[offset .. offset + strlen(prefix)) equals prefix, without
# reading past `length` (a keyword straddling the end is a mismatch).
int mem_starts_with(char* data, int length, int offset, char* prefix):
	int n = strlen(prefix)
	return (offset + n <= length) && mem_eq(data + offset, prefix, n)
