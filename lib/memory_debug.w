/*
Guard-page debug allocator backend: debug_malloc, debug_free and
debug_realloc.

Selected instead of the free-list backend (lib/memory_freelist.w) when
lib/memory.w's dispatcher is in debug mode. In native mode each allocation gets its
own private mmap region sized in whole pages, with the payload
right-aligned (to its size rounded up to 8, so pointers stay 8-byte
aligned) against the end of the last resident page and the page
immediately after unmapped. Overruns past the rounded size fault;
up to seven alignment bytes and sixteen bytes before the payload are
canaries checked on free, realloc and explicit leak reports.

The trailing guard is created with munmap (not mprotect PROT_NONE) so
each live block is a single VMA on ordinary Linux hosts. Android keeps
the guard reserved as PROT_NONE because its native translation runtime
can reuse unmapped guest holes. Quarantine reclamation also releases
that reserved guard. mprotect-splitting the mapping into a
RW payload + PROT_NONE guard doubled the VMA count and made modest
programs hit Linux's default vm.max_map_count (65530) -- wexec under
W_DEBUG_ALLOC OOMed before finishing `hello`. Raise max_map_count for
very allocation-heavy debug runs; the single-VMA layout plus the
quarantine below is what keeps ordinary tool use workable.

free() first mprotects the payload PROT_NONE so a recent use-after-free
still faults, then parks the block in a byte-budgeted quarantine. When
quarantined bytes exceed the budget (or a fresh mmap fails), the oldest
quarantined regions are munmap'd so long-running alloc/free churn does
not exhaust address space. Double-free checks apply while a block remains quarantined. After reclaim,
its metadata slot is reusable and a dangling free reports an invalid
pointer, unless that address has since been allocated again. UAF on a
reclaimed block can miss if the address is remapped for another purpose.

Native mode is deliberately wasteful while a block is quarantined (one
page minimum per allocation). Prefix canaries detect nearby underflow
writes at check time, but cannot detect reads or writes that skip them.
W_DEBUG_ALLOC=valgrind instead pools storage through the freelist with
16-byte redzones and Memcheck client requests. Memcheck checks accesses
and undefined values as code executes, including instrumented C code.
That mode requires Valgrind on Linux x86/x64 and avoids per-block VMAs.

The bookkeeping table (one entry per live or quarantined block: pointer,
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
import lib.page_size


int debug_page_size():
	return runtime_page_size()


# Fill byte for the alignment slack after each payload (0x5a, 'Z').
const int debug_canary = 90


# wasm32 linear memory has no unmapped pages and no page protection
# (lib/__arch__/wasm/syscalls.w: munmap is a no-op, mprotect fails), so
# guards cannot fault there. The substitute is deferred detection: the
# guard page stays resident and holds canaries, and a freed payload is
# filled with this poison byte (0x6b, the Linux slab POISON_FREE value)
# instead of being protected. Canary and poison checks run on free,
# realloc, quarantine release and every leak report; a stray read is
# not detected, only a write that disturbs a canary or poison byte.
const int debug_freed_poison = 107


int debug_linear_memory():
	return __target_isa__ == 2


void debug_linear_fill(int addr, int length, int value):
	char* p = cast(char*, addr)
	for i in range(length): p[i] = value


# Quarantine release (below) verifies the poison before recycling a slot.
void debug_check_freed(int idx);


# Freed-but-still-mapped quarantine budget. ~32 MiB keeps recent UAFs
# faulting on PROT_NONE while bounding VMA growth under alloc/free
# churn. Linux defaults vm.max_map_count to 65530; each live block is
# one VMA with the munmap-guard layout.
int debug_quarantine_budget():
	return 32 * 1024 * 1024


# --- bookkeeping table, backed directly by mmap (never malloc/free) --

int* debug_tbl_ptr         # payload pointer, per entry
int* debug_tbl_region      # mmap'd payload base, per entry
int* debug_tbl_region_size # native mapped length (no guard), or pooled span
int* debug_tbl_size        # requested payload size, per entry
# 0 = live, 1 = freed and still mapped (quarantined PROT_NONE),
# 2 = freed and released to the OS (native) or freelist (Memcheck)
int* debug_tbl_freed
int debug_tbl_count
int debug_tbl_capacity
int debug_guard_warned     # already printed the guard-failure notice
int debug_quarantine_bytes # sum of region sizes with freed == 1
int debug_quarantine_head   # FIFO links are slot + 1; zero means empty
int debug_quarantine_tail
int debug_history_count     # retained Memcheck frees (native uses byte budget)
int debug_tbl_available     # reusable metadata slots, linked through next
int* debug_tbl_next
int* debug_tbl_sequence     # allocation identity, independent of slot reuse
int debug_alloc_sequence
int* debug_tbl_index       # open-addressed pointer -> newest slot + 1
int debug_tbl_probes       # lookup work, for regression tests


int debug_tbl_bucket(int ptr):
	return ((ptr >> 3) ^ (ptr >> 15)) & (debug_tbl_capacity * 2 - 1)


void debug_tbl_index_add(int idx):
	int ptr = debug_tbl_ptr[idx]
	int bucket = debug_tbl_bucket(ptr)
	while (debug_tbl_index[bucket] != 0):
		int old = debug_tbl_index[bucket] - 1
		if (debug_tbl_ptr[old] == ptr):
			if (debug_tbl_sequence[old] > debug_tbl_sequence[idx]): return
			break
		bucket = (bucket + 1) & (debug_tbl_capacity * 2 - 1)
	debug_tbl_index[bucket] = idx + 1


# mmap reports failure as a small negative (errno-shaped) value, the same
# convention debug_malloc already checks a few lines above -- never a null
# pointer, so an unchecked result silently becomes a bogus "valid" pointer
# that segfaults on first use with no diagnostic at all.
int debug_tbl_mmap_failed(int addr):
	return (addr < 0) && (addr > -4096)


# Delete only this slot's index entry: a newer allocation may already own
# the same address. Reinsert the following probe cluster so deletion
# leaves no holes hiding colliding keys, and slot reuse leaves no stale
# index entries referring to a different pointer.
void debug_tbl_index_remove(int idx):
	int ptr = debug_tbl_ptr[idx]
	int bucket = debug_tbl_bucket(ptr)
	while (debug_tbl_index[bucket] != 0):
		if (debug_tbl_index[bucket] == idx + 1):
			debug_tbl_index[bucket] = 0
			bucket = (bucket + 1) & (debug_tbl_capacity * 2 - 1)
			while (debug_tbl_index[bucket] != 0):
				int displaced = debug_tbl_index[bucket] - 1
				debug_tbl_index[bucket] = 0
				debug_tbl_index_add(displaced)
				bucket = (bucket + 1) & (debug_tbl_capacity * 2 - 1)
			return
		bucket = (bucket + 1) & (debug_tbl_capacity * 2 - 1)


void debug_tbl_recycle(int idx):
	debug_tbl_index_remove(idx)
	debug_tbl_ptr[idx] = 0
	debug_tbl_next[idx] = debug_tbl_available
	debug_tbl_available = idx + 1


void debug_quarantine_push(int idx):
	debug_tbl_next[idx] = 0
	if (debug_quarantine_tail): debug_tbl_next[debug_quarantine_tail - 1] = idx + 1
	else: debug_quarantine_head = idx + 1
	debug_quarantine_tail = idx + 1


int debug_quarantine_pop():
	int idx = debug_quarantine_head - 1
	debug_quarantine_head = debug_tbl_next[idx]
	if (debug_quarantine_head == 0): debug_quarantine_tail = 0
	return idx


void debug_tbl_ensure_capacity():
	if (debug_tbl_count < debug_tbl_capacity): return
	int new_capacity = 4096
	if (debug_tbl_capacity > 0): new_capacity = debug_tbl_capacity * 2
	int bytes = new_capacity * __word_size__
	int flags = 34 /* MAP_PRIVATE|MAP_ANONYMOUS */
	int r_ptr = mmap(0, bytes, 3, flags)
	int r_region = mmap(0, bytes, 3, flags)
	int r_region_size = mmap(0, bytes, 3, flags)
	int r_size = mmap(0, bytes, 3, flags)
	int r_freed = mmap(0, bytes, 3, flags)
	int r_next = mmap(0, bytes, 3, flags)
	int r_sequence = mmap(0, bytes, 3, flags)
	int r_index = mmap(0, bytes * 2, 3, flags)
	if (debug_tbl_mmap_failed(r_ptr) | debug_tbl_mmap_failed(r_region) | debug_tbl_mmap_failed(r_region_size) | debug_tbl_mmap_failed(r_size) | debug_tbl_mmap_failed(r_freed) | debug_tbl_mmap_failed(r_next) | debug_tbl_mmap_failed(r_sequence) | debug_tbl_mmap_failed(r_index)):
		st_write_cstr(c"memory_debug: out of memory (bookkeeping table mmap failed)\x0a")
		exit(1)
	int* new_ptr = cast(int*, r_ptr)
	int* new_region = cast(int*, r_region)
	int* new_region_size = cast(int*, r_region_size)
	int* new_size = cast(int*, r_size)
	int* new_freed = cast(int*, r_freed)
	int* new_next = cast(int*, r_next)
	int* new_sequence = cast(int*, r_sequence)
	int i = 0
	while (i < debug_tbl_count):
		new_ptr[i] = debug_tbl_ptr[i]
		new_region[i] = debug_tbl_region[i]
		new_region_size[i] = debug_tbl_region_size[i]
		new_size[i] = debug_tbl_size[i]
		new_freed[i] = debug_tbl_freed[i]
		new_next[i] = debug_tbl_next[i]
		new_sequence[i] = debug_tbl_sequence[i]
		i = i + 1
	if (debug_tbl_capacity > 0):
		int old_bytes = debug_tbl_capacity * __word_size__
		munmap(cast(int, debug_tbl_ptr), old_bytes)
		munmap(cast(int, debug_tbl_region), old_bytes)
		munmap(cast(int, debug_tbl_region_size), old_bytes)
		munmap(cast(int, debug_tbl_size), old_bytes)
		munmap(cast(int, debug_tbl_freed), old_bytes)
		munmap(cast(int, debug_tbl_next), old_bytes)
		munmap(cast(int, debug_tbl_sequence), old_bytes)
		munmap(cast(int, debug_tbl_index), old_bytes * 2)
	debug_tbl_ptr = new_ptr
	debug_tbl_region = new_region
	debug_tbl_region_size = new_region_size
	debug_tbl_size = new_size
	debug_tbl_freed = new_freed
	debug_tbl_next = new_next
	debug_tbl_sequence = new_sequence
	debug_tbl_capacity = new_capacity
	debug_tbl_index = cast(int*, r_index)
	for j in range(debug_tbl_count):
		if (debug_tbl_ptr[j] != 0): debug_tbl_index_add(j)


void debug_tbl_append(int ptr, int region, int region_size, int size):
	# Fail explicitly instead of wrapping allocation identities and hiding
	# leaks from tests which snapshot the sequence counter.
	if (debug_alloc_sequence + 1 <= 0):
		st_write_cstr(c"memory_debug: allocation sequence exhausted\x0a")
		exit(1)
	int idx
	if (debug_tbl_available):
		idx = debug_tbl_available - 1
		debug_tbl_available = debug_tbl_next[idx]
	else:
		debug_tbl_ensure_capacity()
		idx = debug_tbl_count
		debug_tbl_count = debug_tbl_count + 1
	debug_alloc_sequence = debug_alloc_sequence + 1
	debug_tbl_sequence[idx] = debug_alloc_sequence
	debug_tbl_ptr[idx] = ptr
	debug_tbl_region[idx] = region
	debug_tbl_region_size[idx] = region_size
	debug_tbl_size[idx] = size
	debug_tbl_freed[idx] = 0
	debug_tbl_next[idx] = 0
	debug_tbl_index_add(idx)


# The index always names the newest allocation at a reused address.
# Recycled entries are removed from the probe chain before slot reuse.
# Load stays below one half.
int debug_tbl_find(int ptr):
	if ((ptr == 0) || (debug_tbl_capacity == 0)): return -1
	int bucket = debug_tbl_bucket(ptr)
	while (debug_tbl_index[bucket] != 0):
		debug_tbl_probes = debug_tbl_probes + 1
		int i = debug_tbl_index[bucket] - 1
		if (debug_tbl_ptr[i] == ptr): return i
		bucket = (bucket + 1) & (debug_tbl_capacity * 2 - 1)
	return -1


# Free order is independent of allocation order. A FIFO keeps every
# quarantined region reachable, even when older live blocks are freed
# after newer allocations have already been reclaimed. budget 0 drains.
void debug_quarantine_reclaim_to(int budget):
	if (vg_active): return
	while ((debug_quarantine_bytes > budget) && debug_quarantine_head):
		int i = debug_quarantine_head - 1
		debug_check_freed(i)
		int span = debug_tbl_region_size[i]
		if (os_android()): span = span + debug_page_size()
		if (munmap(debug_tbl_region[i], span) != 0):
			st_write_cstr(c"memory_debug: quarantine release failed\x0a")
			exit(1)
		debug_quarantine_pop()
		debug_quarantine_bytes = debug_quarantine_bytes - debug_tbl_region_size[i]
		debug_tbl_freed[i] = 2
		debug_tbl_recycle(i)


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
	int pages = (size + page - 1) / page
	if (pages < 1): pages = 1
	return pages


void* debug_malloc(int size):
	# Leave room for redzones, rounding and two 64-KiB pages.
	if ((size < 0) || (size + 196608 < 0)): return cast(void*, 0)
	if (size < 1): size = 1
	if (vg_active):
		# Pool storage through the ordinary allocator, with 16-byte
		# redzones on both sides. Headers remain outside the redzones.
		int base = cast(int, freelist_malloc(size + 32))
		if (base == 0): return cast(void*, 0)
		int payload = base + 16
		vg_request(vg_malloclike, payload, size, 16, 0)
		debug_tbl_append(payload, base, size + 32, size)
		return cast(void*, payload)
	# The payload ends on an 8-byte boundary below the guard, so the
	# pointer is 8-byte aligned like the free-list backend's (issue #530).
	# An overflow into the up-to-7-byte rounding slack cannot fault; the
	# slack holds a canary that free()/realloc() check instead.
	int placed = ((size + 7) >> 3) << 3
	int page = debug_page_size()
	int payload_pages = debug_pages_for(placed + 16)
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
	int guard_result = 0
	if (debug_linear_memory()):
		# The guard page stays resident on wasm; canaries replace the hole.
		debug_linear_fill(guard_addr, page, debug_canary)
	else if (os_android() || os_windows()):
		# Reserve the guard: Android native translation may reuse an
		# unmapped guest hole while creating its own mappings.
		# Windows VirtualFree cannot release a suffix of an allocation.
		guard_result = mprotect(guard_addr, page, 0)
	else: guard_result = munmap(guard_addr, page)
	if (guard_result != 0):
		if (debug_guard_warned == 0):
			debug_guard_warned = 1
			st_write_cstr(c"memory_debug: guard page setup failed; overflow may not fault\x0a")
	int ptr = guard_addr - placed
	char* slack = cast(char*, ptr)
	for j in range(16): slack[j - 16] = debug_canary
	int i = size
	while (i < placed):
		slack[i] = debug_canary
		i = i + 1
	debug_tbl_append(ptr, region, payload_size, size)
	return cast(void*, ptr)


# Check both native redzones without reading the uninitialized payload.
void debug_check_canary(int idx):
	if (vg_active): return
	int size = debug_tbl_size[idx]
	int placed = ((size + 7) >> 3) << 3
	char* p = cast(char*, debug_tbl_ptr[idx])
	for j in range(16):
		if (p[j - 16] != debug_canary): debug_fatal(c"heap buffer underflow: bytes before the start of a block were overwritten", debug_tbl_ptr[idx])
	int i = size
	int end = placed
	if (debug_linear_memory()): end = placed + debug_page_size()
	while (i < end):
		if (p[i] != debug_canary): debug_fatal(c"heap buffer overflow: bytes past the end of a block were overwritten", debug_tbl_ptr[idx])
		i = i + 1


# wasm only: a quarantined payload must still hold the free poison.
void debug_check_freed(int idx):
	if (debug_linear_memory() == 0): return
	debug_check_canary(idx)
	char* p = cast(char*, debug_tbl_ptr[idx])
	for i in range(debug_tbl_size[idx]):
		if (p[i] != debug_freed_poison): debug_fatal(c"heap use after free: a freed block was written", debug_tbl_ptr[idx])


# Quarantine: PROT_NONE the payload so a near-term UAF faults, keep the
# table entry for double-free detection, and reclaim oldest quarantined
# regions when over budget so the process does not wedge on VMA/address
# space exhaustion.
int debug_free(void* mem_address):
	if (mem_address == 0): return 0
	int ptr = cast(int, mem_address)
	int idx = debug_tbl_find(ptr)
	if (idx < 0): debug_fatal(c"free() called on a pointer the debug allocator never returned", ptr)
	if (debug_tbl_freed[idx]): debug_fatal(c"double free() detected", ptr)
	debug_check_canary(idx)
	if (vg_active):
		freelist_free(cast(void*, debug_tbl_region[idx]))
		vg_request(vg_freelike, ptr, 16, 0, 0)
		debug_tbl_freed[idx] = 2
		# Keep recent invalid-free diagnostics without retaining every
		# allocation ever made. Memcheck owns its own access history.
		debug_quarantine_push(idx)
		debug_history_count = debug_history_count + 1
		if (debug_history_count > 4096):
			debug_tbl_recycle(debug_quarantine_pop())
			debug_history_count = debug_history_count - 1
		return 1
	if (debug_linear_memory()): debug_linear_fill(ptr, debug_tbl_size[idx], debug_freed_poison)
	else if (mprotect(debug_tbl_region[idx], debug_tbl_region_size[idx], 0) != 0):
		st_write_cstr(c"memory_debug: cannot protect freed allocation\x0a")
		exit(1)
	debug_tbl_freed[idx] = 1
	debug_quarantine_push(idx)
	debug_quarantine_bytes = debug_quarantine_bytes + debug_tbl_region_size[idx]
	debug_quarantine_reclaim_if_needed()
	return 1


# Same contract as freelist_realloc (copies min(oldlen, newlen) bytes),
# plus a sanity check that oldlen matches what was actually tracked at
# malloc time -- a mismatch is itself a real bug this allocator is well
# placed to catch. A null result (mmap failure) leaves old allocated.
char* debug_realloc(void* old, int oldlen, int newlen):
	if (old != 0):
		int idx = debug_tbl_find(cast(int, old))
		if (idx < 0):
			debug_fatal(c"realloc() called on a pointer the debug allocator never returned", cast(int, old))
		if (debug_tbl_freed[idx]):
			debug_fatal(c"realloc() called on an already-freed pointer", cast(int, old))
		if (debug_tbl_size[idx] != oldlen):
			debug_fatal(c"realloc() oldlen does not match the tracked allocation size", cast(int, old))
		debug_check_canary(idx)
	char* grown = cast(char*, debug_malloc(newlen))
	if (grown == 0): return grown
	int n = oldlen
	if (old == 0): n = 0
	if (n > newlen): n = newlen
	char* src = cast(char*, old)
	for i in range(n): grown[i] = src[i]
	debug_free(old)
	return grown


# Prints every block never freed (address + size) and returns how many
# there were. Safe to call at any point, not just at process exit --
# there is no automatic exit hook, so callers (tests, or a program's own
# shutdown path) call this explicitly.
#
# Snapshots the table length up front. st_write_dec/st_write_hex print
# through an mmap'd scratch page (lib/stack_trace.w st_scratch_ensure),
# never malloc, so the walk cannot grow the table it is reporting on --
# and, just as important for callers asserting exact leak-count deltas
# (raft_ownership_test), reporting cannot change the leak count itself.
int debug_alloc_report_leaks():
	int leaked = 0
	int leaked_bytes = 0
	int n = debug_tbl_count
	for i in range(n):
		if (debug_tbl_freed[i] == 1): debug_check_freed(i)
		if (debug_tbl_freed[i] == 0):
			debug_check_canary(i)
			st_write_cstr(c"memory_debug: leaked ")
			st_write_dec(debug_tbl_size[i])
			st_write_cstr(c" byte(s) at ")
			st_write_hex(debug_tbl_ptr[i])
			st_write_cstr(c"\x0a")
			leaked = leaked + 1
			leaked_bytes = leaked_bytes + debug_tbl_size[i]
	if (leaked > 0):
		st_write_cstr(c"memory_debug: ")
		st_write_dec(leaked)
		st_write_cstr(c" block(s), ")
		st_write_dec(leaked_bytes)
		st_write_cstr(c" byte(s) leaked\x0a")
	return leaked
