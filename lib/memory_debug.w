/*
Guard-page debug allocator backend: debug_malloc, debug_free and
debug_realloc.

Selected instead of the free-list backend (lib/memory_freelist.w) when
lib/memory.w's dispatcher is in debug mode. Every allocation gets its
own private mmap region sized in whole pages, with the payload
right-aligned against the end of the last resident page and the page
immediately after unmapped: writing even one byte past the requested
size lands in the hole and faults immediately, instead of silently
corrupting the free-list allocator's next block header.

The trailing guard is created with munmap (not mprotect PROT_NONE) so
each live block is a single VMA. mprotect-splitting the mapping into a
RW payload + PROT_NONE guard doubled the VMA count and made modest
programs hit Linux's default vm.max_map_count (65530) -- wexec under
W_DEBUG_ALLOC OOMed before finishing `hello`. Raise max_map_count for
very allocation-heavy debug runs; the single-VMA layout plus the
quarantine below is what keeps ordinary tool use workable.

free() first mprotects the payload PROT_NONE so a recent use-after-free
still faults, then parks the block in a byte-budgeted quarantine. When
quarantined bytes exceed the budget (or a fresh mmap fails), the oldest
quarantined regions are munmap'd so long-running alloc/free churn does
not exhaust address space. Double-free and invalid-free checks keep
working after reclaim because the bookkeeping table entry stays; UAF on
a reclaimed block still usually SIGSEGVs on the hole, but can miss if
the address is remapped for a later allocation.

This is deliberately wasteful while a block is quarantined (one page
minimum per allocation) and only catches overflow past the end of a
block, not underflow before its start -- it is a debugging aid for one
process run, not a general-purpose allocator.

The bookkeeping table (one entry per live-or-freed block: pointer,
region, size) is what free()/realloc() need to find a block's region,
since there is nowhere to put a header next to a payload that sits
flush against its guard hole. As a side effect the same table is what
makes leak reporting possible: debug_alloc_report_leaks() walks it at
any point and reports every block never freed. The table manages its
own backing storage directly via mmap rather than through malloc/free,
since malloc/free are exactly what it is tracking.
*/
import lib.linux
import lib.stack_trace


int debug_page_size():
	return 4096


# Freed-but-still-mapped quarantine budget. ~32 MiB keeps recent UAFs
# faulting on PROT_NONE while bounding VMA growth under alloc/free
# churn. Linux defaults vm.max_map_count to 65530; each live block is
# one VMA with the munmap-guard layout.
int debug_quarantine_budget():
	return 32 * 1024 * 1024


# --- bookkeeping table, backed directly by mmap (never malloc/free) --

int* debug_tbl_ptr         # payload pointer, per entry
int* debug_tbl_region      # mmap'd payload base, per entry
int* debug_tbl_region_size # mapped payload length in bytes (no guard), per entry
int* debug_tbl_size        # requested payload size, per entry
# 0 = live, 1 = freed and still mapped (quarantined PROT_NONE),
# 2 = freed and munmap'd (reclaimed from quarantine)
int* debug_tbl_freed
int debug_tbl_count
int debug_tbl_capacity
int debug_guard_warned     # already printed the guard-failure notice
int debug_quarantine_bytes # sum of region sizes with freed == 1
int debug_quarantine_cursor # next index to consider for reclaim


# mmap reports failure as a small negative (errno-shaped) value, the same
# convention debug_malloc already checks a few lines above -- never a null
# pointer, so an unchecked result silently becomes a bogus "valid" pointer
# that segfaults on first use with no diagnostic at all.
int debug_tbl_mmap_failed(int addr):
	return (addr < 0) && (addr > -4096)


void debug_tbl_ensure_capacity():
	if (debug_tbl_count < debug_tbl_capacity):
		return
	int new_capacity = 4096
	if (debug_tbl_capacity > 0):
		new_capacity = debug_tbl_capacity * 2
	int bytes = new_capacity * __word_size__
	int flags = 34 /* MAP_PRIVATE|MAP_ANONYMOUS */
	int r_ptr = mmap(0, bytes, 3, flags)
	int r_region = mmap(0, bytes, 3, flags)
	int r_region_size = mmap(0, bytes, 3, flags)
	int r_size = mmap(0, bytes, 3, flags)
	int r_freed = mmap(0, bytes, 3, flags)
	if (debug_tbl_mmap_failed(r_ptr) | debug_tbl_mmap_failed(r_region) | debug_tbl_mmap_failed(r_region_size) | debug_tbl_mmap_failed(r_size) | debug_tbl_mmap_failed(r_freed)):
		st_write_cstr(c"memory_debug: out of memory (bookkeeping table mmap failed)\x0a")
		exit(1)
	int* new_ptr = cast(int*, r_ptr)
	int* new_region = cast(int*, r_region)
	int* new_region_size = cast(int*, r_region_size)
	int* new_size = cast(int*, r_size)
	int* new_freed = cast(int*, r_freed)
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


# Newest-first: after quarantine reclaim munmaps a region, mmap may
# hand the same payload address to a later malloc. A oldest-first scan
# would hit the reclaimed entry and mis-report the new block's free()
# as a double free (and debug_fatal's own scratch malloc/free then
# recurses). Prefer the most recent entry for that pointer.
int debug_tbl_find(int ptr):
	int i = debug_tbl_count - 1
	while (i >= 0):
		if (debug_tbl_ptr[i] == ptr):
			return i
		i = i - 1
	return -1


# Munmap the oldest quarantined regions until quarantined bytes are at
# or under `budget`, or the table is exhausted. budget 0 drains all.
void debug_quarantine_reclaim_to(int budget):
	while ((debug_quarantine_bytes > budget) && (debug_quarantine_cursor < debug_tbl_count)):
		int i = debug_quarantine_cursor
		debug_quarantine_cursor = i + 1
		if (debug_tbl_freed[i] == 1):
			munmap(debug_tbl_region[i], debug_tbl_region_size[i])
			debug_quarantine_bytes = debug_quarantine_bytes - debug_tbl_region_size[i]
			debug_tbl_freed[i] = 2
			# Drop the payload address so a recycled mmap cannot alias
			# this slot; double-free of a truly dangling pointer then
			# reports "never returned" once the address is reused.
			debug_tbl_ptr[i] = 0


void debug_quarantine_reclaim_if_needed():
	debug_quarantine_reclaim_to(debug_quarantine_budget())


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
	int payload_size = payload_pages * page
	int region_size = payload_size + page
	int flags = 34 /* MAP_PRIVATE|MAP_ANONYMOUS */
	int region = mmap(0, region_size, 3, flags)
	if (debug_tbl_mmap_failed(region)):
		# Free quarantined VMAs and retry once -- the common failure
		# under W_DEBUG_ALLOC on long-running tools.
		debug_quarantine_reclaim_to(0)
		region = mmap(0, region_size, 3, flags)
		if (debug_tbl_mmap_failed(region)):
			st_write_cstr(c"memory_debug: out of memory (mmap failed)\x0a")
			return cast(void*, 0)
	int guard_addr = region + payload_size
	# Unmap the guard page so overflow faults on a hole. Prefer munmap
	# over mprotect(PROT_NONE): mprotect splits one mapping into two
	# VMAs and burns max_map_count twice as fast.
	if (munmap(guard_addr, page) != 0):
		if (debug_guard_warned == 0):
			debug_guard_warned = 1
			st_write_cstr(c"memory_debug: munmap guard page failed; overflow may not fault\x0a")
	int ptr = guard_addr - size
	debug_tbl_append(ptr, region, payload_size, size)
	return cast(void*, ptr)


# Quarantine: PROT_NONE the payload so a near-term UAF faults, keep the
# table entry for double-free detection, and reclaim oldest quarantined
# regions when over budget so the process does not wedge on VMA/address
# space exhaustion.
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
	debug_quarantine_bytes = debug_quarantine_bytes + debug_tbl_region_size[idx]
	debug_quarantine_reclaim_if_needed()
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
