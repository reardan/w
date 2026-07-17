/*
Guard-page debug allocator backend: debug_malloc, debug_free and
debug_realloc.

Selected instead of the free-list backend (lib/memory_freelist.w) when
lib/memory.w's dispatcher is in debug mode. Every allocation gets its
own private mmap region sized in whole pages, with the payload
right-aligned against the end of the last resident page and an
unmapped/PROT_NONE guard page immediately after it: writing even one
byte past the requested size lands on the guard page and faults
immediately, instead of silently corrupting the free-list allocator's
next block header. free() never reuses or unmaps a block's pages -- it
mprotects the whole region PROT_NONE instead, so a use-after-free access
also faults immediately rather than reading or corrupting memory some
other allocation has since reused.

This is deliberately wasteful (one page minimum per allocation, and
freed pages are never reclaimed) and only catches overflow past the end
of a block, not underflow before its start -- it is a debugging aid for
one process run, not a general-purpose allocator.

The bookkeeping table (one entry per live-or-freed block: pointer,
region, size) is what free()/realloc() need to find a block's region,
since there is nowhere to put a header next to a payload that sits
flush against its guard page. As a side effect the same table is what
makes leak reporting possible: debug_alloc_report_leaks() walks it at
any point and reports every block never freed. The table manages its
own backing storage directly via mmap rather than through malloc/free,
since malloc/free are exactly what it is tracking.
*/
import lib.linux
import lib.stack_trace


int debug_page_size():
	return 4096


# --- bookkeeping table, backed directly by mmap (never malloc/free) --

int* debug_tbl_ptr         # payload pointer, per entry
int* debug_tbl_region      # mmap'd region base, per entry
int* debug_tbl_region_size # mmap'd region length in bytes, per entry
int* debug_tbl_size        # requested payload size, per entry
int* debug_tbl_freed       # 0 live, 1 freed, per entry
int debug_tbl_count
int debug_tbl_capacity
int debug_guard_warned     # already printed the "guard pages unsupported" notice


void debug_tbl_ensure_capacity():
	if (debug_tbl_count < debug_tbl_capacity):
		return
	int new_capacity = 4096
	if (debug_tbl_capacity > 0):
		new_capacity = debug_tbl_capacity * 2
	int bytes = new_capacity * __word_size__
	int flags = 34 /* MAP_PRIVATE|MAP_ANONYMOUS */
	int* new_ptr = cast(int*, mmap(0, bytes, 3, flags))
	int* new_region = cast(int*, mmap(0, bytes, 3, flags))
	int* new_region_size = cast(int*, mmap(0, bytes, 3, flags))
	int* new_size = cast(int*, mmap(0, bytes, 3, flags))
	int* new_freed = cast(int*, mmap(0, bytes, 3, flags))
	int i = 0
	while (i < debug_tbl_count):
		new_ptr[i] = debug_tbl_ptr[i]
		new_region[i] = debug_tbl_region[i]
		new_region_size[i] = debug_tbl_region_size[i]
		new_size[i] = debug_tbl_size[i]
		new_freed[i] = debug_tbl_freed[i]
		i = i + 1
	if (debug_tbl_capacity > 0):
		int old_bytes = debug_tbl_capacity * __word_size__
		munmap(cast(int, debug_tbl_ptr), old_bytes)
		munmap(cast(int, debug_tbl_region), old_bytes)
		munmap(cast(int, debug_tbl_region_size), old_bytes)
		munmap(cast(int, debug_tbl_size), old_bytes)
		munmap(cast(int, debug_tbl_freed), old_bytes)
	debug_tbl_ptr = new_ptr
	debug_tbl_region = new_region
	debug_tbl_region_size = new_region_size
	debug_tbl_size = new_size
	debug_tbl_freed = new_freed
	debug_tbl_capacity = new_capacity


void debug_tbl_append(int ptr, int region, int region_size, int size):
	debug_tbl_ensure_capacity()
	debug_tbl_ptr[debug_tbl_count] = ptr
	debug_tbl_region[debug_tbl_count] = region
	debug_tbl_region_size[debug_tbl_count] = region_size
	debug_tbl_size[debug_tbl_count] = size
	debug_tbl_freed[debug_tbl_count] = 0
	debug_tbl_count = debug_tbl_count + 1


int debug_tbl_find(int ptr):
	int i = 0
	while (i < debug_tbl_count):
		if (debug_tbl_ptr[i] == ptr):
			return i
		i = i + 1
	return -1


# Uses lib.stack_trace's own write helpers (st_write_*), not lib.lib's
# print2/hex/itoa: this file is part of the container runtime the
# compiler auto-imports into every program, so it must not pull in
# lib.lib, which defines _main -- a handful of minimal fixtures define
# their own _main to bypass the standard runtime entirely, and importing
# lib.lib here would conflict with those. See lib/memory.w's header
# comment for the same constraint on the dispatcher.
void debug_fatal(char* message, int addr):
	st_write_cstr(c"memory_debug: ")
	st_write_cstr(message)
	st_write_cstr(c" (address ")
	st_write_hex(addr)
	st_write_cstr(c")\x0a")
	print_stack_trace()
	exit(1)


int debug_pages_for(int size):
	int page = debug_page_size()
	int pages = (size + page - 1) >> 12
	if (pages < 1):
		pages = 1
	return pages


void* debug_malloc(int size):
	if (size < 1):
		size = 1
	int page = debug_page_size()
	int payload_pages = debug_pages_for(size)
	int region_size = (payload_pages + 1) * page
	int flags = 34 /* MAP_PRIVATE|MAP_ANONYMOUS */
	int region = mmap(0, region_size, 3, flags)
	if ((region < 0) && (region > -4096)):
		st_write_cstr(c"memory_debug: out of memory (mmap failed)\x0a")
		return cast(void*, 0)
	int guard_addr = region + payload_pages * page
	if (mprotect(guard_addr, page, 0) != 0):
		if (debug_guard_warned == 0):
			debug_guard_warned = 1
			st_write_cstr(c"memory_debug: guard pages are not supported on this target -- overflow and use-after-free will not be caught, only leak tracking remains active\x0a")
	int ptr = guard_addr - size
	debug_tbl_append(ptr, region, region_size, size)
	return cast(void*, ptr)


# Push the whole region (payload pages and guard page alike) to
# PROT_NONE and mark it freed, but never munmap or reuse it: any future
# touch, or a second free(), is a bug and should fault or be caught
# rather than silently succeed against memory something else now owns.
int debug_free(void* mem_address):
	if (mem_address == 0):
		return 0
	int ptr = cast(int, mem_address)
	int idx = debug_tbl_find(ptr)
	if (idx < 0):
		debug_fatal(c"free() called on a pointer the debug allocator never returned", ptr)
	if (debug_tbl_freed[idx]):
		debug_fatal(c"double free() detected", ptr)
	mprotect(debug_tbl_region[idx], debug_tbl_region_size[idx], 0)
	debug_tbl_freed[idx] = 1
	return 1


# Same contract as freelist_realloc (copies exactly oldlen bytes, even
# when newlen < oldlen), plus a sanity check that oldlen matches what
# was actually tracked at malloc time -- a mismatch is itself a real bug
# this allocator is well placed to catch.
char* debug_realloc(void* old, int oldlen, int newlen):
	if (old != 0):
		int idx = debug_tbl_find(cast(int, old))
		if (idx < 0):
			debug_fatal(c"realloc() called on a pointer the debug allocator never returned", cast(int, old))
		if (debug_tbl_freed[idx]):
			debug_fatal(c"realloc() called on an already-freed pointer", cast(int, old))
		if (debug_tbl_size[idx] != oldlen):
			debug_fatal(c"realloc() oldlen does not match the tracked allocation size", cast(int, old))
	char* grown = debug_malloc(newlen)
	char* src = old
	int i = 0
	while (i < oldlen):
		grown[i] = src[i]
		i = i + 1
	debug_free(old)
	return grown


# Prints every block never freed (address + size) and returns how many
# there were. Safe to call at any point, not just at process exit --
# there is no automatic exit hook, so callers (tests, or a program's own
# shutdown path) call this explicitly.
#
# Snapshots the table length up front: st_write_dec/st_write_hex each
# malloc and free a small scratch buffer internally, and without this
# snapshot the resulting (immediately-freed, so not itself a leak)
# table growth would let the loop chase its own tail.
int debug_alloc_report_leaks():
	int leaked = 0
	int leaked_bytes = 0
	int n = debug_tbl_count
	int i = 0
	while (i < n):
		if (debug_tbl_freed[i] == 0):
			st_write_cstr(c"memory_debug: leaked ")
			st_write_dec(debug_tbl_size[i])
			st_write_cstr(c" byte(s) at ")
			st_write_hex(debug_tbl_ptr[i])
			st_write_cstr(c"\x0a")
			leaked = leaked + 1
			leaked_bytes = leaked_bytes + debug_tbl_size[i]
		i = i + 1
	if (leaked > 0):
		st_write_cstr(c"memory_debug: ")
		st_write_dec(leaked)
		st_write_cstr(c" block(s), ")
		st_write_dec(leaked_bytes)
		st_write_cstr(c" byte(s) leaked\x0a")
	return leaked
