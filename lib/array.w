/*
lib.array: slice-level helpers for `T[]` heap arrays, starting with the
`array_free(T[] view)` shape staged by
docs/projects/arrays_slices_strings.md Milestone 5 ("byte-level
implementation first").

Layout contract (grammar/unary_expression.w's `new T[n]` lowering): one
malloc'd block holds the two-word {data, length} descriptor followed
immediately by the payload, and `data` always points at
`block + 2 * __word_size__`. array_free inverts that: given any view of
the FULL buffer (`view.data`, `view.length`), the malloc'd block is
`view.data - 2 * __word_size__`, released through lib/memory.w's free.
The element type never enters the math, so the byte-level core
(array_free_data) works for every element width; the generic wrapper
only exists so call sites keep the staged typed shape. `T[]` parameters
do not bind type-argument inference (docs/projects/generics.md), so
call it with an explicit argument: `array_free[float](buf)`.

What may be freed: exactly a full view of a buffer allocated by
`new T[n]` -- the original slice or any full-range copy of it (all
aliases die together; the buffer is freed once). Guards are the
best-effort sanity asserts below, per the staged design:

- A PROPER sub-slice (`a[i:j]` narrower than the whole buffer) fails
  the header check -- its data pointer lands mid-payload (or its length
  disagrees with the block header) -- and is a fatal assert, not a
  heap-corrupting free.
- A double free through any alias is a fatal assert under the default
  allocator: the first free poisons the block's length word to -1
  before releasing it (free itself never touches those words), so the
  header re-check fails. Under W_DEBUG_ALLOC the freed block is
  PROT_NONE and the re-read crashes with a stack trace instead --
  either way the bug is caught at the second call.
- NOT catchable at this level: a fixed `T[N]` stack/global array or a
  wrapped foreign buffer that happens to carry a matching
  {data, length} header (fixed arrays use the same inline-header
  layout). Freeing those is undefined behavior, same as passing any
  non-malloc pointer to free. Only pass buffers that came from
  `new T[n]`.

A {0, 0} view (null data) is a no-op, mirroring free(0).

Still unimplemented from the Milestone 5 helper list: array_clone,
array_copy, array_fill_zero.
*/
import lib.lib
import lib.assert


# Byte-level core: free the `new T[n]` block whose payload starts at
# data and holds `length` elements. See the header comment for the
# layout contract and what the asserts can and cannot catch.
void array_free_data(void* data, int length):
	if (data == 0):
		return
	char* p = cast(char*, data)
	int* block = cast(int*, p - 2 * __word_size__)
	int header_ok = block[0] == cast(int, data) && block[1] == length && length >= 0
	asserts(c"array_free: not an unsliced heap array", header_ok)
	# Poison the length word so a second free through any alias fails
	# the header check above (free() leaves these words untouched; the
	# allocator's own header lives before the block).
	block[1] = 0 - 1
	free(cast(void*, block))


# The staged typed shape: free the heap buffer behind a full `T[]`
# view. Explicit type argument required (`array_free[int](buf)`) --
# `T[]` parameter shapes do not drive inference.
void array_free[T](T[] view):
	array_free_data(cast(void*, view.data), view.length)
