# Native wgrind shadow state. This module never reads application memory
# and never calls the application allocator. Execution frontends supply
# address/value events and must stop when error != 0. No Valgrind dependency.
import lib.linux

const int WG_READ = 1
const int WG_WRITE = 2
const int WG_INVALID_READ = 1
const int WG_INVALID_WRITE = 2
const int WG_UNDEFINED = 3
const int WG_INVALID_FREE = 4
const int WG_DOUBLE_FREE = 5
const int WG_BAD_REALLOC = 6
const int WG_INCOMPLETE = 100
const int WG_PAGE = 4096
const int WG_BUCKETS = 1024

struct wg_page:
	int key
	wg_page* next
	int active
	char* permissions
	char* undefined
	int* origins

struct wg_arena:
	wg_arena* next
	int length
	int used

struct wg_block:
	int address
	int size
	int allocated_at
	int freed_at
	int state # 0 reusable, 1 live, 2 freed
	wg_block* hash_next
	wg_block* older
	wg_block* newer
	wg_block* left
	wg_block* right
	int height

struct wg_context:
	wg_arena* arenas
	int* pages
	wg_page* spare_pages
	int page_count
	int page_limit
	int* blocks
	wg_block* spare_blocks
	wg_block* live_root
	wg_block* oldest
	wg_block* newest
	int block_count
	int block_limit
	int history_limit
	int history_count
	int live_blocks
	int live_bytes
	int reserved_bytes
	int error
	int error_address
	int error_size
	int error_site
	int error_origin
	int error_allocation
	int error_free
	int error_offset


int wg_less(int a, int b):
	# Unsigned address comparison, including high x86 addresses.
	if ((a < 0) != (b < 0)): return b < 0
	return a < b


int wg_range(int address, int size):
	if (size < 0): return 0
	if (size == 0): return 1
	return wg_less(address + size - 1, address) == 0


int wg_mask(int size):
	if (size == __word_size__): return -1
	return (1 << (size * 8)) - 1


int wg_error(wg_context* c, int kind, int address, int size, int site, int origin):
	if (c.error == 0):
		c.error = kind
		c.error_address = address
		c.error_size = size
		c.error_site = site
		c.error_origin = origin
	return 0


void wg_clear_error(wg_context* c):
	# For a consumer that has handled the report. Failed accesses have
	# no shadow side effects. Incomplete checks must terminate execution.
	if (c.error == WG_INCOMPLETE): return
	c.error = 0
	c.error_allocation = 0
	c.error_free = 0
	c.error_offset = 0


int wg_mmap_failed(int address):
	return (address < 0) && (address > -4096)


# Checker-owned slabs, amortized over many pages/records. Memory never
# moves, so a frontend can keep a context across application reallocs.
int wg_reserve(wg_context* c, int size):
	size = (size + 7) & ~7
	wg_arena* a = c.arenas
	if ((a == 0) || (size > a.length - a.used)):
		int length = 262144
		if (size + sizeof(wg_arena) > length): length = (size + sizeof(wg_arena) + 4095) & ~4095
		int p = mmap(0, length, 3, 34)
		if (wg_mmap_failed(p)):
			wg_error(c, WG_INCOMPLETE, 0, size, 0, 0)
			return 0
		a = cast(wg_arena*, p)
		a.next = c.arenas
		a.length = length
		a.used = (sizeof(wg_arena) + 7) & ~7
		c.arenas = a
		c.reserved_bytes = c.reserved_bytes + length
	int result = cast(int, a) + a.used
	a.used = a.used + size
	return result


wg_context* wg_create(int page_limit, int block_limit, int history_limit):
	if ((page_limit < 1) || (block_limit < 1) || (history_limit < 0) || (history_limit > block_limit)): return 0
	int p = mmap(0, 4096, 3, 34)
	if (wg_mmap_failed(p)): return 0
	wg_context* c = cast(wg_context*, p)
	c.reserved_bytes = 4096
	c.page_limit = page_limit
	c.block_limit = block_limit
	c.history_limit = history_limit
	c.pages = cast(int*, wg_reserve(c, WG_BUCKETS * __word_size__))
	c.blocks = cast(int*, wg_reserve(c, WG_BUCKETS * __word_size__))
	return c


void wg_destroy(wg_context* c):
	if (c == 0): return
	wg_arena* a = c.arenas
	while (a != 0):
		wg_arena* next = a.next
		munmap(cast(int, a), a.length)
		a = next
	munmap(cast(int, c), 4096)


int wg_bucket(int key):
	return (key ^ (key >> 11) ^ (key >> 23)) & (WG_BUCKETS - 1)


wg_page* wg_page_find(wg_context* c, int address):
	int key = address >> 12
	wg_page* p = cast(wg_page*, c.pages[wg_bucket(key)])
	while (p != 0):
		if (p.key == key): return p
		p = p.next
	return 0


wg_page* wg_page_get(wg_context* c, int address):
	wg_page* p = wg_page_find(c, address)
	if (p != 0): return p
	if (c.page_count == c.page_limit):
		wg_error(c, WG_INCOMPLETE, address, WG_PAGE, 0, 0)
		return 0
	if (c.spare_pages != 0):
		p = c.spare_pages
		c.spare_pages = p.next
	else:
		int base = wg_reserve(c, sizeof(wg_page) + WG_PAGE * (2 + __word_size__))
		if (base == 0): return 0
		p = cast(wg_page*, base)
		p.permissions = cast(char*, base + sizeof(wg_page))
		p.undefined = p.permissions + WG_PAGE
		p.origins = cast(int*, p.undefined + WG_PAGE)
	p.active = 0
	p.key = address >> 12
	int bucket = wg_bucket(p.key)
	p.next = cast(wg_page*, c.pages[bucket])
	c.pages[bucket] = cast(int, p)
	c.page_count = c.page_count + 1
	return p


void wg_page_release(wg_context* c, wg_page* page):
	int bucket = wg_bucket(page.key)
	wg_page* p = cast(wg_page*, c.pages[bucket])
	wg_page* prev = 0
	while (p != page):
		prev = p
		p = p.next
	if (prev == 0): c.pages[bucket] = cast(int, page.next)
	else: prev.next = page.next
	page.next = c.spare_pages
	c.spare_pages = page
	c.page_count = c.page_count - 1


# Mapping/accessibility events. origin is a stable site token/address,
# not a pointer into an allocation record that might later be recycled.
int wg_mark(wg_context* c, int address, int size, int permissions, int undefined, int origin):
	if (c.error): return 0
	if ((wg_range(address, size) == 0) || (permissions < 0) || (permissions > 3) || (undefined < 0) || (undefined > 255)):
		return wg_error(c, WG_INCOMPLETE, address, size, 0, origin)
	int pos = 0
	while (pos < size):
		int at = address + pos
		int offset = at & (WG_PAGE - 1)
		int n = WG_PAGE - offset
		if (n > size - pos): n = size - pos
		wg_page* p = wg_page_find(c, at)
		if ((p == 0) && permissions): p = wg_page_get(c, at)
		if (c.error): return 0
		if (p != 0):
			for i in range(offset, offset + n):
				if (p.permissions[i] != 0): p.active = p.active - 1
				if (permissions): p.active = p.active + 1
				p.permissions[i] = permissions
				p.undefined[i] = undefined
				p.origins[i] = 0
				if (permissions && undefined): p.origins[i] = origin
			if (p.active == 0): wg_page_release(c, p)
		pos = pos + n
	return 1


wg_block* wg_block_find(wg_context* c, int address):
	wg_block* p = cast(wg_block*, c.blocks[wg_bucket(address)])
	while (p != 0):
		if (p.address == address): return p
		p = p.hash_next
	return 0


# Error-only interval search: the execution fast path uses shadow pages.
# Pick a containing object or an edge within 64 bytes. Do not attribute
# an arbitrary unmapped address (for example null) to a distant object.
# Live objects win ties; among overlapping freed objects, prefer the
# newest lifetime, using the free-order list rather than hash order.
int wg_block_distance(wg_block* p, int address):
	if (wg_less(address, p.address)): return p.address - address
	if (wg_less(address - p.address, p.size) == 0): return address - p.address - p.size + 1
	return 0


void wg_describe(wg_context* c, int address):
	int nearest = 65
	wg_block* found = 0
	wg_block* p = c.newest
	while (p != 0):
		int distance = wg_block_distance(p, address)
		if (wg_less(distance, nearest)):
			found = p
			nearest = distance
		p = p.older
	for b in range(WG_BUCKETS):
		p = cast(wg_block*, c.blocks[b])
		while (p != 0):
			if (p.state == 1):
				int distance = wg_block_distance(p, address)
				int choose = wg_less(distance, nearest)
				if ((distance == nearest) && (found != 0)):
					if (found.state != 1): choose = 1
				if (choose):
					found = p
					nearest = distance
			p = p.hash_next
	if (found != 0):
		c.error_allocation = found.allocated_at
		c.error_free = found.freed_at
		c.error_offset = address - found.address


int wg_access(wg_context* c, int address, int size, int permission, int site):
	if (c.error): return 0
	if ((wg_range(address, size) == 0) || ((permission != WG_READ) && (permission != WG_WRITE))):
		return wg_error(c, WG_INCOMPLETE, address, size, site, 0)
	int pos = 0
	while (pos < size):
		int at = address + pos
		wg_page* p = wg_page_find(c, at)
		int offset = at & (WG_PAGE - 1)
		int n = WG_PAGE - offset
		if (n > size - pos): n = size - pos
		for i in range(n):
			int valid = 0
			if (p != 0): valid = p.permissions[offset + i] & permission
			if (valid == 0):
				int kind = WG_INVALID_READ
				if (permission == WG_WRITE): kind = WG_INVALID_WRITE
				wg_error(c, kind, at + i, size, site, 0)
				wg_describe(c, at + i)
				return 0
		pos = pos + n
	return 1


struct wg_value:
	int value
	int undefined
	int origin


int wg_load(wg_context* c, int address, int size, int site, wg_value* out):
	if ((size < 1) || (size > __word_size__)): return wg_error(c, WG_INCOMPLETE, address, size, site, 0)
	if (wg_access(c, address, size, WG_READ, site) == 0): return 0
	out.undefined = 0
	out.origin = 0
	for i in range(size):
		wg_page* p = wg_page_find(c, address + i)
		int offset = (address + i) & (WG_PAGE - 1)
		int u = p.undefined[offset] & 255
		out.undefined = out.undefined | (u << (i * 8))
		if (u && (out.origin == 0)): out.origin = p.origins[offset]
	return 1


int wg_store(wg_context* c, int address, int size, int site, wg_value* value):
	if ((size < 1) || (size > __word_size__)): return wg_error(c, WG_INCOMPLETE, address, size, site, 0)
	if (wg_access(c, address, size, WG_WRITE, site) == 0): return 0
	for i in range(size):
		wg_page* p = wg_page_find(c, address + i)
		int offset = (address + i) & (WG_PAGE - 1)
		int u = (value.undefined >> (i * 8)) & 255
		p.undefined[offset] = u
		p.origins[offset] = 0
		if (u): p.origins[offset] = value.origin
	return 1


int wg_use(wg_context* c, wg_value* value, int site):
	if (c.error): return 0
	if (value.undefined): return wg_error(c, WG_UNDEFINED, 0, 0, site, value.origin)
	return 1


# Copy shadow without checking definedness. Validate both whole ranges
# before modifying the destination; overlap follows memmove semantics.
int wg_copy(wg_context* c, int dest, int src, int size, int site):
	if (wg_access(c, src, size, WG_READ, site) == 0): return 0
	if (wg_access(c, dest, size, WG_WRITE, site) == 0): return 0
	int reverse = wg_less(src, dest) && wg_less(dest - src, size)
	for n in range(size):
		int i = n
		if (reverse): i = size - 1 - n
		wg_page* s = wg_page_find(c, src + i)
		wg_page* d = wg_page_find(c, dest + i)
		int si = (src + i) & (WG_PAGE - 1)
		int di = (dest + i) & (WG_PAGE - 1)
		d.undefined[di] = s.undefined[si]
		d.origins[di] = s.origins[si]
	return 1


# Kernel output: call with the actual successful byte count, never the
# requested capacity. A failed syscall (negative count) changes nothing.
int wg_kernel_write(wg_context* c, int address, int count, int site):
	if (c.error): return 0
	if (count <= 0): return 1
	if (wg_access(c, address, count, WG_WRITE, site) == 0): return 0
	for i in range(count):
		wg_page* p = wg_page_find(c, address + i)
		int offset = (address + i) & (WG_PAGE - 1)
		p.undefined[offset] = 0
		p.origins[offset] = 0
	return 1


int wg_kernel_read(wg_context* c, int address, int size, int site):
	if (wg_access(c, address, size, WG_READ, site) == 0): return 0
	for i in range(size):
		wg_page* p = wg_page_find(c, address + i)
		int offset = (address + i) & (WG_PAGE - 1)
		if (p.undefined[offset]): return wg_error(c, WG_UNDEFINED, address + i, size, site, p.origins[offset])
	return 1
