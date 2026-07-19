/*
Pointer-offset helper (docs/projects/ai_tooling_next_steps.md, 2026-07-16
inflate.w Huffman-table bug).

THE RULE: `T* + int` is a RAW, UNSCALED BYTE offset for every pointee
width -- `int* p; p + n` advances `n` BYTES, not `n` ints (same for
`char*`, struct pointers, everything). Only INDEXING scales: `p[n]` and
`&p[n]` multiply `n` by the pointee's width before adding it to `p`.
The compiler warns about nothing here -- `int* + int -> int*` is
perfectly well-typed, so a forgotten `* width` (or a stray plain `+`
where indexing was meant) silently reads/writes the wrong address. See
`lib/sha256.w`'s `p + i * 4` (or, at a call site, `lengths + hlit *
__word_size__` in libs/extras/compress/inflate.w) for the hand-scaled
idiom this file replaces with a name.

Use `ptr_add(p, n)` instead of `p + n` whenever you mean "n elements
past p", for any pointee type T (int, char, struct, another pointer,
...). It is defined as `&p[n]`, so it inherits the compiler's
already-correct indexing scale for T's width -- no `sizeof`, no
`__word_size__` bookkeeping, and it stays correct if T's size changes.
Negative n walks backward, same as negative array indexing.

Do NOT reach for this when you already have `p[n]` / `&p[n]` available
directly -- it exists only for call sites (like a function argument)
where writing `&p[n]` inline is awkward and a named helper reads
better.
*/


T* ptr_add[T](T* p, int n):
	return &p[n]


# Signed distance from `a` to `b`, in ELEMENTS of T (not bytes) -- the
# inverse of ptr_add: ptr_add(a, ptr_diff(b, a)) == b for pointers into
# the same array (first argument is the destination, second the base). Byte distance is computed with an explicit cast to
# char* (whose indexing stride is 1) and then divided by T's stride,
# recovered the same way __word_size__ recovers int's stride: by
# comparing where index 1 lands.
int ptr_diff[T](T* b, T* a):
	char* stride_probe = cast(char*, &a[1])
	int stride = stride_probe - cast(char*, a)
	char* bb = cast(char*, b)
	char* ab = cast(char*, a)
	return (bb - ab) / stride
