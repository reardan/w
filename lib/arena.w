/*
Budgeted arenas for request-scoped objects (docs/projects/budgets_transport.md,
issue #514 stage W5).

An arena hands out memory from a list of chunks taken from the ordinary
heap (lib/memory.w, so per-thread heaps and W_DEBUG_ALLOC apply to the
chunks), and gives it all back at once:

	arena a
	arena_init(&a, 4096, 65536)          # 4 KiB chunks, 64 KiB budget
	char* p = 0
	if (arena_alloc(&a, n, 8, &p) != ARENA_OK):
		# a.alloc_failures counted it; nothing was allocated
	...
	arena_reset(&a)                      # rewind, keep one chunk
	arena_release(&a)                    # give every chunk back

Contracts:
- Every failure is a status, never an abort: a negative size, a bad
  alignment, size + padding overflowing a word, a request over
  ARENA_MAX_REQUEST, budget exhaustion and a failed heap allocation all
  return without allocating and bump alloc_failures.
- The budget counts backing bytes (chunk headers included), not the
  bytes handed out, because that is the memory the process holds. An
  optional mem_budget shared by several arenas/allocations is charged the
  same bytes.
- Borrowed views: the compiler has no escape analysis, so code that hands
  arena memory to another task or worker calls arena_borrow first and
  arena_release_borrow when that holder is done. arena_reset,
  arena_release and arena_free refuse with ARENA_ERR_BORROWED while any
  borrow is outstanding; allocation stays allowed (it never moves
  existing objects).
- Descriptor versus backing data: arena_reset rewinds and keeps the first
  chunk for reuse (freeing the rest, so an overload burst does not stay
  resident); arena_release frees every backing chunk but leaves the
  descriptor (the arena struct) valid and empty; arena_free releases and
  then frees a descriptor that came from arena_new. A descriptor embedded
  in another struct or on the stack is never passed to arena_free.
- Single owner: an arena and a mem_budget are not internally locked. Use
  one per worker thread (tasks on one scheduler are cooperative, so they
  may share it), or guard it with a wmutex. mem_shared_budget provides
  separate synchronized accounting on Linux x86/x64. Attach it with
  arena_set_thread_budget; it does not synchronize arena mutation.
*/
import lib.lib
import lib.memory
import lib.__arch__.budget_lock


const int ARENA_OK = 0
const int ARENA_ERR_INVALID = 1     # negative size, release without borrow, ...
const int ARENA_ERR_ALIGN = 2       # alignment not a power of two in 1..ARENA_MAX_ALIGN
const int ARENA_ERR_OVERFLOW = 3    # size + padding + header overflows, or > ARENA_MAX_REQUEST
const int ARENA_ERR_BUDGET = 4      # the arena or shared byte budget is exhausted
const int ARENA_ERR_NO_MEMORY = 5   # the heap could not supply a chunk
const int ARENA_ERR_UNSUPPORTED = 7 # shared accounting needs atomic RMW
const int ARENA_ERR_BUSY = 8        # outstanding shared-budget users or bytes
const int ARENA_ERR_CLOSED = 9      # destroyed shared budget
const int ARENA_ERR_BORROWED = 6    # reset/release refused: borrowed views outstanding


const int ARENA_MAX_ALIGN = 4096
# Largest single request, on every target: keeps chunk arithmetic far from
# the word limit and keeps a 32-bit heap from being asked for absurd sizes.
const int ARENA_MAX_REQUEST = 1073741824


char* arena_status_name(int status):
	if (status == ARENA_OK): return c"ok"
	if (status == ARENA_ERR_INVALID): return c"invalid"
	if (status == ARENA_ERR_ALIGN): return c"bad_alignment"
	if (status == ARENA_ERR_OVERFLOW): return c"overflow"
	if (status == ARENA_ERR_BUDGET): return c"budget_exhausted"
	if (status == ARENA_ERR_NO_MEMORY): return c"no_memory"
	if (status == ARENA_ERR_BORROWED): return c"borrowed"
	if (status == ARENA_ERR_UNSUPPORTED): return c"unsupported"
	if (status == ARENA_ERR_BUSY): return c"busy"
	if (status == ARENA_ERR_CLOSED): return c"closed"
	return c"unknown"


# Largest positive int on this target (2^31-1 or 2^63-1).
int arena_int_max():
	return ~(1 << (__word_size__ * 8 - 1))


# a + b, or -1 when the sum would exceed the word's positive range.
# Both operands must be non-negative.
int arena_checked_add(int a, int b):
	if ((a < 0) || (b < 0)): return -1
	if (a > arena_int_max() - b): return -1
	return a + b


int arena_is_power_of_two(int v):
	if (v <= 0): return 0
	return (v & (v - 1)) == 0


/* Shared byte budget. */

struct mem_budget:
	int limit      # bytes that may be reserved at once; <= 0 means unlimited
	int used       # bytes currently reserved
	int peak       # high-water mark of used
	int failures   # reservations refused


void mem_budget_init(mem_budget* b, int limit):
	b.limit = limit
	b.used = 0
	b.peak = 0
	b.failures = 0


# Reserves n bytes. ARENA_OK, ARENA_ERR_INVALID for n < 0, or
# ARENA_ERR_BUDGET (counted in failures) when n does not fit.
int mem_budget_reserve(mem_budget* b, int n):
	if (n < 0): return ARENA_ERR_INVALID
	if (b.limit > 0):
		if (n > b.limit - b.used):
			b.failures = b.failures + 1
			return ARENA_ERR_BUDGET
	else:
		if (arena_checked_add(b.used, n) < 0):
			b.failures = b.failures + 1
			return ARENA_ERR_OVERFLOW
	b.used = b.used + n
	if (b.used > b.peak): b.peak = b.used
	return ARENA_OK


# Returns n previously reserved bytes. Releasing more than is reserved is
# a caller bug; it clamps to zero and reports ARENA_ERR_INVALID.
int mem_budget_release(mem_budget* b, int n):
	if ((n < 0) || (n > b.used)):
		b.used = 0
		return ARENA_ERR_INVALID
	b.used = b.used - n
	return ARENA_OK


# malloc(size) charged to b; 0 (counted in b.failures when the budget
# refused it) on failure. Free with mem_budget_free and the same size.
char* mem_budget_alloc(mem_budget* b, int size):
	if ((size < 0) || (size > ARENA_MAX_REQUEST)):
		b.failures = b.failures + 1
		return 0
	if (mem_budget_reserve(b, size) != ARENA_OK): return 0
	char* p = cast(char*, malloc(size))
	if (p == 0):
		mem_budget_release(b, size)
		b.failures = b.failures + 1
	return p


void mem_budget_free(mem_budget* b, char* p, int size):
	if (p == 0): return
	free(p)
	mem_budget_release(b, size)


/* Concurrent byte accounting. The descriptor must be word-aligned, never
copied, and initialized before publication. Each worker/arena retains a user
before receiving its pointer and drops it after its final call. The owner
must stop new callers before destroy/reinit/free: a reference counter does
not make acquiring a dangling pointer safe. Arena mutation stays single-owner.
All fields are private by contract; use snapshot while workers are live.
*/
struct mem_shared_budget:
	int lock_word
	int active
	int users
	int limit
	int used
	int peak
	int failures
	int release_errors


struct mem_shared_budget_stats:
	int active
	int users
	int limit
	int used
	int peak
	int failures
	int release_errors


# Zero is a zero-byte limit; negative limits are invalid. To request the
# largest possible limit, pass arena_int_max(). No arithmetic may wrap.
int mem_shared_budget_init(mem_shared_budget* b, int limit):
	b.lock_word = 0
	b.active = 0
	b.users = 0
	b.limit = 0
	b.used = 0
	b.peak = 0
	b.failures = 0
	b.release_errors = 0
	if (budget_lock_supported() == 0): return ARENA_ERR_UNSUPPORTED
	if (limit < 0): return ARENA_ERR_INVALID
	b.limit = limit
	b.active = 1
	return ARENA_OK


# Called under lock: saturating diagnostics never wrap negative.
void mem_shared_budget_failure(mem_shared_budget* b):
	if (b.failures < arena_int_max()): b.failures = b.failures + 1


int mem_shared_budget_retain(mem_shared_budget* b):
	if (budget_lock_supported() == 0): return ARENA_ERR_UNSUPPORTED
	budget_lock_enter(&b.lock_word)
	int status = ARENA_OK
	if (b.active == 0): status = ARENA_ERR_CLOSED
	else if (b.users == arena_int_max()): status = ARENA_ERR_OVERFLOW
	else: b.users = b.users + 1
	budget_lock_leave(&b.lock_word)
	return status


int mem_shared_budget_drop(mem_shared_budget* b):
	if (budget_lock_supported() == 0): return ARENA_ERR_UNSUPPORTED
	budget_lock_enter(&b.lock_word)
	int status = ARENA_OK
	if (b.users == 0): status = ARENA_ERR_INVALID
	else: b.users = b.users - 1
	budget_lock_leave(&b.lock_word)
	return status


int mem_shared_budget_destroy(mem_shared_budget* b):
	if (budget_lock_supported() == 0): return ARENA_ERR_UNSUPPORTED
	budget_lock_enter(&b.lock_word)
	int status = ARENA_OK
	if (b.users != 0 || b.used != 0): status = ARENA_ERR_BUSY
	else: b.active = 0
	budget_lock_leave(&b.lock_word)
	return status


int mem_shared_budget_snapshot(mem_shared_budget* b, mem_shared_budget_stats* out):
	if (budget_lock_supported() == 0): return ARENA_ERR_UNSUPPORTED
	budget_lock_enter(&b.lock_word)
	out.active = b.active
	out.users = b.users
	out.limit = b.limit
	out.used = b.used
	out.peak = b.peak
	out.failures = b.failures
	out.release_errors = b.release_errors
	budget_lock_leave(&b.lock_word)
	return ARENA_OK


# Every refused reservation/allocation counts once, including invalid sizes.
int mem_shared_budget_reserve(mem_shared_budget* b, int n):
	if (budget_lock_supported() == 0): return ARENA_ERR_UNSUPPORTED
	budget_lock_enter(&b.lock_word)
	int status = ARENA_OK
	if (b.active == 0): status = ARENA_ERR_CLOSED
	else if (n < 0): status = ARENA_ERR_INVALID
	else if (n > arena_int_max() - b.used): status = ARENA_ERR_OVERFLOW
	else if (n > b.limit - b.used): status = ARENA_ERR_BUDGET
	if (status == ARENA_OK):
		b.used = b.used + n
		if (b.used > b.peak): b.peak = b.used
	else: mem_shared_budget_failure(b)
	budget_lock_leave(&b.lock_word)
	return status


# Invalid release preserves every other user's reservation. It never clamps
# the shared balance to zero. Callers must release only bytes they own.
int mem_shared_budget_release(mem_shared_budget* b, int n):
	if (budget_lock_supported() == 0): return ARENA_ERR_UNSUPPORTED
	budget_lock_enter(&b.lock_word)
	int status = ARENA_OK
	if (b.active == 0): status = ARENA_ERR_CLOSED
	else if (n < 0 || n > b.used): status = ARENA_ERR_INVALID
	if (status == ARENA_OK): b.used = b.used - n
	else if (b.release_errors < arena_int_max()): b.release_errors = b.release_errors + 1
	budget_lock_leave(&b.lock_word)
	return status


# Internal rollback of an owned reservation when backing allocation failed.
void mem_shared_budget_alloc_failed(mem_shared_budget* b, int size):
	budget_lock_enter(&b.lock_word)
	b.used = b.used - size
	mem_shared_budget_failure(b)
	budget_lock_leave(&b.lock_word)


type mem_shared_alloc_fn = fn(void*, int) -> char*


# Custom backing allocator supports fault injection and allocation domains.
# Caller frees using that same domain, then releases the charged size. Zero
# size allocates/charges one byte. The callback runs outside the budget lock.
int mem_shared_budget_alloc_with(mem_shared_budget* b, int size, char** out, mem_shared_alloc_fn* alloc, void* context):
	*out = 0
	if (budget_lock_supported() == 0): return ARENA_ERR_UNSUPPORTED
	if (size < 0 || size > ARENA_MAX_REQUEST || alloc == 0):
		budget_lock_enter(&b.lock_word)
		mem_shared_budget_failure(b)
		budget_lock_leave(&b.lock_word)
		if (size > ARENA_MAX_REQUEST): return ARENA_ERR_OVERFLOW
		return ARENA_ERR_INVALID
	if (size == 0): size = 1
	int status = mem_shared_budget_reserve(b, size)
	if (status != ARENA_OK): return status
	char* p = alloc(context, size)
	if (p == 0):
		mem_shared_budget_alloc_failed(b, size)
		return ARENA_ERR_NO_MEMORY
	*out = p
	return ARENA_OK


char* mem_shared_budget_heap_alloc(void* context, int size):
	return cast(char*, malloc(size))


int mem_shared_budget_alloc(mem_shared_budget* b, int size, char** out):
	return mem_shared_budget_alloc_with(b, size, out, mem_shared_budget_heap_alloc, 0)


# p and size must match one successful allocation; caller owns p exclusively.
# The budget reference must remain held through this call.
int mem_shared_budget_free(mem_shared_budget* b, char* p, int size):
	if (p == 0): return ARENA_OK
	if (size < 0 || size > ARENA_MAX_REQUEST): return ARENA_ERR_INVALID
	if (size == 0): size = 1
	free(p)
	return mem_shared_budget_release(b, size)


/* Arena. */

# Chunk header; the usable bytes follow it (arena_chunk_data).
struct arena_chunk:
	arena_chunk* next
	int capacity   # usable bytes after the header
	int used       # bytes handed out from this chunk, padding included
	int total      # bytes obtained from malloc (header + capacity)


struct arena:
	arena_chunk* head      # chunk currently allocated from; older chunks follow
	int chunk_size         # default usable bytes per chunk
	int budget             # backing-byte limit; <= 0 means unlimited
	mem_budget* shared     # optional single-owner budget, 0 when none
	mem_shared_budget* thread_budget # optional concurrent accounting; arena still single-owner
	int poison             # 1: arena_reset fills the kept chunk with 0xa5
	int reserved           # backing bytes currently held (headers included)
	int peak_reserved
	int bytes_used         # bytes handed out since the last reset/release
	int peak_used
	int chunks             # chunks currently held
	int allocs             # successful arena_alloc calls (lifetime)
	int alloc_failures     # refused arena_alloc calls (lifetime)
	int resets             # successful arena_reset calls
	int borrows            # outstanding borrowed views


int arena_chunk_header_size():
	# A multiple of 16 on both word sizes, so chunk data starts as aligned
	# as the heap block itself.
	return 4 * __word_size__


char* arena_chunk_data(arena_chunk* c):
	return cast(char*, c) + arena_chunk_header_size()


# Initializes a caller-owned descriptor. chunk_size <= 0 picks 4096;
# budget <= 0 means unlimited. Allocates nothing.
void arena_init(arena* a, int chunk_size, int budget):
	if (chunk_size <= 0): chunk_size = 4096
	if (chunk_size > ARENA_MAX_REQUEST): chunk_size = ARENA_MAX_REQUEST
	a.head = 0
	a.chunk_size = chunk_size
	a.budget = budget
	a.shared = 0
	a.thread_budget = 0
	a.poison = 0
	a.reserved = 0
	a.peak_reserved = 0
	a.bytes_used = 0
	a.peak_used = 0
	a.chunks = 0
	a.allocs = 0
	a.alloc_failures = 0
	a.resets = 0
	a.borrows = 0


# Heap descriptor; 0 when the descriptor itself cannot be allocated.
# Free it with arena_free.
arena* arena_new(int chunk_size, int budget):
	arena* a = cast(arena*, malloc(sizeof(arena)))
	if (a == 0): return 0
	arena_init(a, chunk_size, budget)
	return a


# Charges every chunk to b as well. Set before the first allocation (or
# after arena_release); returns ARENA_ERR_INVALID while chunks are held.
int arena_set_shared_budget(arena* a, mem_budget* b):
	if (a.chunks != 0): return ARENA_ERR_INVALID
	if (a.thread_budget != 0): return ARENA_ERR_INVALID
	a.shared = b
	return ARENA_OK


# Attach/detach only with no chunks or borrows. The attachment retains one
# budget user even across arena_release; detach explicitly or arena_free.
int arena_set_thread_budget(arena* a, mem_shared_budget* b):
	if (a.chunks != 0 || a.borrows != 0 || a.shared != 0): return ARENA_ERR_INVALID
	if (a.thread_budget == b): return ARENA_OK
	if (b != 0):
		int status = mem_shared_budget_retain(b)
		if (status != ARENA_OK): return status
	if (a.thread_budget != 0): mem_shared_budget_drop(a.thread_budget)
	a.thread_budget = b
	return ARENA_OK


void arena_set_poison(arena* a, int on):
	a.poison = on


int arena_fail(arena* a, int status):
	a.alloc_failures = a.alloc_failures + 1
	return status


void arena_chunk_free(arena* a, arena_chunk* c):
	int total = c.total
	a.reserved = a.reserved - total
	a.chunks = a.chunks - 1
	free(cast(char*, c))
	if (cast(int, a.shared) != 0): mem_budget_release(a.shared, total)
	if (a.thread_budget != 0): mem_shared_budget_release(a.thread_budget, total)


# Takes a chunk with at least need usable bytes, budget permitting, and
# pushes it as the new head.
int arena_grow(arena* a, int need):
	int capacity = a.chunk_size
	if (need > capacity): capacity = need
	int total = arena_checked_add(capacity, arena_chunk_header_size())
	if (total < 0): return ARENA_ERR_OVERFLOW
	if (a.budget > 0):
		if (total > a.budget - a.reserved): return ARENA_ERR_BUDGET
	if (cast(int, a.shared) != 0):
		int shared_status = mem_budget_reserve(a.shared, total)
		if (shared_status != ARENA_OK): return shared_status
	if (a.thread_budget != 0):
		int thread_status = mem_shared_budget_reserve(a.thread_budget, total)
		if (thread_status != ARENA_OK): return thread_status
	arena_chunk* c = cast(arena_chunk*, malloc(total))
	if (c == 0):
		if (cast(int, a.shared) != 0): mem_budget_release(a.shared, total)
		if (a.thread_budget != 0): mem_shared_budget_alloc_failed(a.thread_budget, total)
		return ARENA_ERR_NO_MEMORY
	c.next = a.head
	c.capacity = capacity
	c.used = 0
	c.total = total
	a.head = c
	a.chunks = a.chunks + 1
	a.reserved = a.reserved + total
	if (a.reserved > a.peak_reserved): a.peak_reserved = a.reserved
	return ARENA_OK


# Padding that brings address up to a multiple of align (a power of two).
int arena_padding(char* address, int align):
	return (0 - cast(int, address)) & (align - 1)


# Allocates size bytes aligned to align (a power of two, at most
# ARENA_MAX_ALIGN) and stores the address in *out (0 on failure). size 0
# yields a valid, distinct one-byte allocation. The memory is not zeroed.
int arena_alloc(arena* a, int size, int align, char** out):
	*out = 0
	if (size < 0): return arena_fail(a, ARENA_ERR_INVALID)
	if ((arena_is_power_of_two(align) == 0) || (align > ARENA_MAX_ALIGN)):
		return arena_fail(a, ARENA_ERR_ALIGN)
	if (size > ARENA_MAX_REQUEST): return arena_fail(a, ARENA_ERR_OVERFLOW)
	if (size == 0): size = 1
	arena_chunk* c = a.head
	int pad = 0
	int fits = 0
	if (cast(int, c) != 0):
		pad = arena_padding(arena_chunk_data(c) + c.used, align)
		int need_here = arena_checked_add(pad, size)
		if ((need_here >= 0) && (need_here <= c.capacity - c.used)): fits = 1
	if (fits == 0):
		# A fresh chunk's data is at least word aligned, so align - 1
		# extra bytes always cover the padding.
		int need = arena_checked_add(size, align - 1)
		if (need < 0): return arena_fail(a, ARENA_ERR_OVERFLOW)
		int grow_status = arena_grow(a, need)
		if (grow_status != ARENA_OK): return arena_fail(a, grow_status)
		c = a.head
		pad = arena_padding(arena_chunk_data(c), align)
	char* p = arena_chunk_data(c) + c.used + pad
	c.used = c.used + pad + size
	a.bytes_used = a.bytes_used + pad + size
	if (a.bytes_used > a.peak_used): a.peak_used = a.bytes_used
	a.allocs = a.allocs + 1
	*out = p
	return ARENA_OK


# Word-aligned allocation returning the address, or 0 on any failure
# (the reason is not kept; use arena_alloc when it matters).
char* arena_alloc_or_null(arena* a, int size):
	char* p = 0
	arena_alloc(a, size, __word_size__, &p)
	return p


# Records a borrowed view: something outside the owner (another task, a
# worker, an in-flight I/O operation) holds pointers into the arena.
void arena_borrow(arena* a):
	a.borrows = a.borrows + 1


# Ends one borrow. ARENA_ERR_INVALID when none is outstanding.
int arena_release_borrow(arena* a):
	if (a.borrows <= 0): return ARENA_ERR_INVALID
	a.borrows = a.borrows - 1
	return ARENA_OK


# Rewinds the arena: every pointer it handed out becomes invalid. Keeps
# one default-size chunk for reuse and frees every other chunk (oversized
# ones included), so the memory held after a reset never depends on the
# largest burst seen. Refused with ARENA_ERR_BORROWED while borrows are
# out.
int arena_reset(arena* a):
	if (a.borrows > 0): return ARENA_ERR_BORROWED
	arena_chunk* keep = 0
	arena_chunk* c = a.head
	while (cast(int, c) != 0):
		arena_chunk* next = c.next
		if ((cast(int, keep) == 0) && (c.capacity == a.chunk_size)): keep = c
		else: arena_chunk_free(a, c)
		c = next
	if (cast(int, keep) != 0): keep.next = 0
	a.head = keep
	if (cast(int, keep) != 0):
		if (a.poison):
			char* data = arena_chunk_data(keep)
			for i in range(keep.capacity): data[i] = 0xa5
		keep.used = 0
	a.bytes_used = 0
	a.resets = a.resets + 1
	return ARENA_OK


# Frees every backing chunk. The descriptor stays valid (empty, counters
# kept) and may allocate again. Refused while borrows are out.
int arena_release(arena* a):
	if (a.borrows > 0): return ARENA_ERR_BORROWED
	while (cast(int, a.head) != 0):
		arena_chunk* c = a.head
		a.head = c.next
		arena_chunk_free(a, c)
	a.bytes_used = 0
	return ARENA_OK


# Releases the backing chunks and frees a descriptor from arena_new.
# Refused (nothing freed) while borrows are out.
int arena_free(arena* a):
	if (cast(int, a) == 0): return ARENA_OK
	int status = arena_release(a)
	if (status != ARENA_OK): return status
	if (a.thread_budget != 0): mem_shared_budget_drop(a.thread_budget)
	free(cast(char*, a))
	return ARENA_OK
