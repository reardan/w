/*
Safe memory access for the debugger, and the target-access seam (#123
phase 2: docs/projects/debugger_attach.md).

Every debuggee memory read/write wdbg's inspection commands (x, st, bt,
watch, print/set, string previews) need goes through the three entry
points at the bottom of this file: dbg_mem_readable, dbg_mem_read (word or
narrower) and dbg_mem_write_word. Each dispatches through a registered
function pointer -- the same convention debugger/disas.w already uses for
instruction bytes (dbg_disas_read_fn) -- so the same call sites work
whether the debuggee lives in this process (direct loads/stores, probed
with mincore so a bad pointer cannot fault wdbg) or in a ptrace-attached
target (PTRACE_PEEKDATA/POKEDATA, where a failed peek is the readability
answer).

dbg_memory_init() installs the in-process triple by default, so every
existing caller keeps today's exact behavior with no seam awareness
needed; debugger/attach.w installs its ptrace-backed triple instead when
an attach session starts. This is a pure access-seam refactor: no new
ptrace semantics, and breakpoint byte-patching (debugger/breakpoints.w)
and expression evaluation's in-process locals binding (debugger/eval.w's
dbg_eval_copy) are deliberately untouched -- they are execution-control
(phase 4) and eval (phase 6) concerns, not memory inspection.
*/
import lib.lib


char* dbg_mincore_vec

# Set by dbg_mem_read/dbg_mem_read_word after every call: 1 on success, 0
# when the target address turned out to be unreadable (only meaningful for
# a ptrace-backed reader; the in-process reader never fails a call that
# followed a successful dbg_mem_readable check).
int dbg_mem_read_ok

# The seam: three function-pointer slots, each holding the address of a
# reader/writer/prober cast back to a callable pointer at the call site
# (debugger/disas.w's dbg_disas_read_fn does the same thing for bytes).
int dbg_mem_readable_fn /* int f(addr, n) -> 1 readable / 0 not */
int dbg_mem_read_fn     /* int f(addr, width) -> value; sets dbg_mem_read_ok */
int dbg_mem_write_fn    /* int f(addr, value) -> 1 ok / 0 failed (word-sized) */


# --- in-process (direct) implementation: today's exact behavior --------

# 1 when n bytes starting at addr sit on mapped pages.
int dbg_mem_readable_local(int addr, int n):
	if (dbg_mincore_vec == 0):
		return 0
	int page = addr - (addr & 4095)
	int length = addr + n - page
	if (length > 16 * 4096):
		return 0
	return sys_mincore(page, length, cast(int, dbg_mincore_vec)) == 0


# Direct load. Callers check dbg_mem_readable first (the established
# pattern throughout debugger/), so this never needs to fail on its own.
int dbg_mem_read_local(int addr, int width):
	dbg_mem_read_ok = 1
	return load_i(cast(char*, addr), width)


int dbg_mem_write_local(int addr, int value):
	save_word(cast(char*, addr), value)
	return 1


# Install the in-process triple. dbg_memory_init() does this by default;
# an attach session installs its own ptrace triple instead (see
# debugger/attach.w's at_mem_readable/at_mem_read).
void dbg_memory_use_local():
	dbg_mem_readable_fn = cast(int, dbg_mem_readable_local)
	dbg_mem_read_fn = cast(int, dbg_mem_read_local)
	dbg_mem_write_fn = cast(int, dbg_mem_write_local)


void dbg_memory_init():
	# One residency byte per probed page; probes span at most 2 pages
	dbg_mincore_vec = malloc(16)
	dbg_memory_use_local()


# --- the seam: every caller (in-process or attach) goes through these --

int dbg_mem_readable(int addr, int n):
	int* fn = cast(int*, dbg_mem_readable_fn)
	return fn(addr, n)


# Read `width` bytes (1, 2, 4 or __word_size__) at addr. Sets
# dbg_mem_read_ok; callers that have not already probed dbg_mem_readable
# should check it.
int dbg_mem_read(int addr, int width):
	int* fn = cast(int*, dbg_mem_read_fn)
	return fn(addr, width)


int dbg_mem_read_word(int addr):
	return dbg_mem_read(addr, __word_size__)


int dbg_mem_write_word(int addr, int value):
	int* fn = cast(int*, dbg_mem_write_fn)
	return fn(addr, value)


# Print a bounded, escaped preview of a C string the debuggee owns, or
# nothing when the pointer is unreadable. Used for char* values.
void dbg_print_string_preview(int addr):
	if (addr == 0):
		return;
	if (dbg_mem_readable(addr, 1) == 0):
		return;
	print(c" \x22")
	int i = 0
	while (i < 64):
		if (dbg_mem_readable(addr + i, 1) == 0):
			print(c"\x22...")
			return;
		int c = dbg_mem_read(addr + i, 1) & 255
		if (c == 0):
			print(c"\x22")
			return;
		if ((c < 32) || (c > 126)):
			print(c"\x22...")
			return;
		put_char(c)
		i = i + 1
	print(c"\x22...")
