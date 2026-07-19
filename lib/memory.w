/*
Heap allocator entry points: malloc, free and realloc.

This file is a thin dispatcher, not an allocator: it picks one of the
backend modules below and forwards every call to it. The choice is made
once, on the first allocation call, and cached for the rest of the
process:

  - lib/memory_freelist.w -- the default, production free-list
    allocator (fast, minimal memory overhead).
  - lib/memory_debug.w -- a guard-page allocator that trades speed and
    memory for catching heap bugs (overflow, use-after-free, double
    free, and leaks) as close to the point of the bug as possible.
    Freed blocks stay PROT_NONE in a bounded quarantine, then munmap,
    so long-running tools under W_DEBUG_ALLOC do not OOM.

Debug mode is opt-in: set W_DEBUG_ALLOC to any non-empty value before
the program starts, or call malloc_force_debug_mode() before the first
allocation of the process. Adding another backend later (say a
bounds-checking allocator tuned for one arch) means adding another
module and another branch below -- callers of malloc/free/realloc never
need to change.

This file is part of the container runtime (structures/hash_table.w,
structures/w_list.w) that the compiler auto-imports into every program,
so it must not pull in lib.lib: lib.lib defines _main, and a handful of
minimal fixtures (e.g. tests/hello.w) define their own _main to bypass
the standard runtime entirely, which would conflict. That's why the
W_DEBUG_ALLOC check below reads /proc/self/environ directly through
lib.linux's raw open/read/close instead of going through lib.env (which
needs lib.lib's environ_ptr, set by lib.lib's own _main). /proc doesn't
exist on win64/wasm/arm64_darwin, so auto-detection there is a no-op;
malloc_force_debug_mode() still works everywhere.
*/
# Forward declarations so cyclic imports (memory_debug.w pulls in
# lib.stack_trace for its fatal-error path, which imports lib.memory
# back here; the import registry dedupes the cycle, so without these
# the detour would see calls to free()/realloc() before this file's own
# definitions below are parsed) still resolve. Mirrors lib/lib.w's
# forward declaration of malloc for the same reason.
void* malloc(int size);
int free(void* mem_address);
char* realloc(void* old, int oldlen, int newlen);

import lib.linux
import lib.memory_freelist
import lib.memory_debug


int malloc_mode_determined /* 0 until the first malloc/free/realloc call, or malloc_force_debug_mode() */
int malloc_debug_mode      /* 0 = freelist backend, 1 = debug backend */


# Force debug-mode allocation regardless of W_DEBUG_ALLOC. Must be
# called before the first malloc/free/realloc of the process -- the
# backend choice is fixed on first use and never revisited.
void malloc_force_debug_mode():
	malloc_mode_determined = 1
	malloc_debug_mode = 1


# Best-effort W_DEBUG_ALLOC check: true when some environment entry
# starts with "W_DEBUG_ALLOC=". Reads /proc/self/environ directly (see
# the file header for why) using the freelist backend's own allocator
# for the scratch buffer, never the dispatcher, to keep this out of the
# mode-selection path it is itself deciding.
int malloc_debug_env_check():
	int fd = open(c"/proc/self/environ", 0, 0)
	if (fd < 0):
		return 0
	int cap = 65536
	char* buf = freelist_malloc(cap)
	int n = read(fd, buf, cap - 1)
	close(fd)
	if (n <= 0):
		freelist_free(buf)
		return 0
	char* needle = c"W_DEBUG_ALLOC="
	int needle_len = 14
	int i = 0
	int found = 0
	while ((i < n) && (found == 0)):
		if (i + needle_len <= n):
			int matches = 1
			int j = 0
			while (j < needle_len):
				if (buf[i + j] != needle[j]):
					matches = 0
				j = j + 1
			if (matches):
				found = 1
		while ((i < n) && (buf[i] != 0)):
			i = i + 1
		i = i + 1
	freelist_free(buf)
	return found


void malloc_init_mode():
	if (malloc_mode_determined == 0):
		malloc_mode_determined = 1
		if (malloc_debug_env_check()):
			malloc_debug_mode = 1


void* malloc(int size):
	malloc_init_mode()
	if (malloc_debug_mode):
		return debug_malloc(size)
	return freelist_malloc(size)


int free(void* mem_address):
	malloc_init_mode()
	if (malloc_debug_mode):
		return debug_free(mem_address)
	return freelist_free(mem_address)


char *realloc(void* old, int oldlen, int newlen):
	malloc_init_mode()
	if (malloc_debug_mode):
		return debug_realloc(old, oldlen, newlen)
	return freelist_realloc(old, oldlen, newlen)
