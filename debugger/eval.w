/*
Expression evaluation at a breakpoint, on the shared REPL engine
(repl/core.w).

The whole compiler is already in this process, and the debuggee's code
buffer, symbol table and type table are all live -- the same in-process
model the REPL runs on. dbg_eval() wraps the expression as the entry
"return <expr>" and hands it to repl_eval(), which stages it in the
session's staging directory, compiles it as a fresh anonymous function
appended to the code buffer, calls it, and rolls it back cleanly (via
the shared repl_setjmp recovery hook and checkpoint) when it fails to
compile or faults at runtime, instead of killing wdbg. dbg_eval_entry()
exposes the full engine to the 'repl' command in wdbg's loop: multi-line
entries, persistent helper definitions and imports work at a stop, with
the same declaration persistence as the REPL prompt.

Locals and arguments visible at the stop are bound as temporary symbols
so expressions like "x + y * 2" or "add(x, 1)" work on locals too. The
generated code addresses symbols with 32-bit immediates, and on x64 the
debuggee's stack sits above 4GB, so each local's value is copied into a
low-memory scratch slot that the symbol points at; after the entry runs
the slots are copied back, so assignments to locals stick. The binding
runs as the engine's pre-entry hook (repl_bind_hook), so the symbols
exist while the entry compiles; afterwards they are retracted from
lookup (dbg_eval_unbind) -- they cannot be truncated away, because a
persistent definition made by the same entry lives above them in the
table. The binding record is saved and restored around each eval, so a
nested eval (a breakpoint hit inside code an eval is executing) keeps
its own.
*/
import debugger.breakpoints
import repl.core


int dbg_eval_ok /* set by dbg_eval_call: 0 = the expression failed to compile (or faulted) */

# Result of the last successful dbg_eval_entry: the value of the entry's
# final bare expression (or the entry function's return value) and its
# compile-time type for echoing, -1 when nothing should echo.
int dbg_eval_value
int dbg_eval_echo_type

# Stop context for the pre-entry binding hook.
int dbg_eval_stop_addr
int dbg_eval_esp

# Scratch copies of the bound locals (low memory) and the copy-back
# list: runtime address, scratch address, byte size, plus each binding's
# symbol-table name offset for dbg_eval_unbind. Allocated fresh per eval
# (dbg_eval_entry) so nested evals keep their own record.
char* dbg_eval_scratch
char* dbg_eval_bound_from
char* dbg_eval_bound_to
char* dbg_eval_bound_size
char* dbg_eval_bound_sym
int dbg_eval_bound_count


int dbg_eval_bound_max():
	return 128


int dbg_eval_scratch_size():
	return 8192


void dbg_eval_copy(int from, int to, int n):
	char* src = cast(char*, from)
	char* dst = cast(char*, to)
	int i = 0
	while (i < n):
		dst[i] = src[i]
		i = i + 1


# Bind every local and argument visible at the stop as a defined global
# object pointing at a scratch copy of its value. Later declarations win
# in sym_lookup, so inner shadowing declarations take precedence over
# outer ones and over real globals, like in the source. Runs as the
# engine's pre-entry hook inside repl_compile_entry, after the entry's
# rollback checkpoint: a failed entry rolls the bindings back with it.
void dbg_eval_bind_locals(int stop_addr, int esp):
	dbg_eval_bound_count = 0
	dbg_frame_compute(stop_addr)
	if (dbg_frame_ok == 0):
		return;
	if (dbg_eval_scratch == 0):
		dbg_eval_scratch = malloc(dbg_eval_scratch_size())
		dbg_eval_bound_from = malloc(dbg_eval_bound_max() * __word_size__)
		dbg_eval_bound_to = malloc(dbg_eval_bound_max() * __word_size__)
		dbg_eval_bound_size = malloc(dbg_eval_bound_max() * 4)
		dbg_eval_bound_sym = malloc(dbg_eval_bound_max() * 4)
	int rel = stop_addr - code_offset
	int saved_indirection = pointer_indirection
	int used = 0
	int i = 0
	while (i < debug_local_count):
		if (dbg_local_visible(i, rel)):
			int type = dbg_local_type(i)
			int size = __word_size__
			if ((type_get_pointer_level(type) == 0) & (type_num_args(type) > 0)):
				# struct value: whole object, rounded up to words
				size = (type_get_size(type) + __word_size__ - 1) / __word_size__ * __word_size__
			int addr = dbg_local_runtime_addr(i, esp)
			if ((used + size <= dbg_eval_scratch_size()) & (dbg_eval_bound_count < dbg_eval_bound_max())):
				if (dbg_mem_readable(addr, size)):
					int slot = cast(int, dbg_eval_scratch) + used
					dbg_eval_copy(addr, slot, size)
					int b = dbg_eval_bound_count
					save_word(dbg_eval_bound_from + b * __word_size__, addr)
					save_word(dbg_eval_bound_to + b * __word_size__, slot)
					save_int(dbg_eval_bound_size + b * 4, size)
					save_int(dbg_eval_bound_sym + b * 4, table_pos)
					dbg_eval_bound_count = b + 1
					used = used + size
					pointer_indirection = type_get_pointer_level(type)
					sym_declare(dbg_local_name_at(i), type, 'D', slot, 1)
		i = i + 1
	pointer_indirection = saved_indirection


# The engine's pre-entry hook: bind the locals of the recorded stop.
void dbg_eval_bind_hook():
	dbg_eval_bind_locals(dbg_eval_stop_addr, dbg_eval_esp)


# Copy possibly-assigned scratch values back into the stack slots.
void dbg_eval_writeback():
	int b = 0
	while (b < dbg_eval_bound_count):
		int from = load_word(dbg_eval_bound_to + b * __word_size__)
		int to = load_word(dbg_eval_bound_from + b * __word_size__)
		dbg_eval_copy(from, to, load_int(dbg_eval_bound_size + b * 4))
		b = b + 1


# Retract the scratch bindings from symbol lookup once the entry has run:
# each binding's stored name gets a leading byte no identifier can start
# with, so later lookups never match it, while the entry keeps its length
# for the table walk. The bindings cannot be popped off the table --
# persistent definitions the same entry made live above them.
void dbg_eval_unbind():
	int b = 0
	while (b < dbg_eval_bound_count):
		table[load_int(dbg_eval_bound_sym + b * 4)] = 1
		b = b + 1


# Evaluate one full REPL entry at the stop described by stop_addr/esp:
# the locals bind around it, declarations persist for the rest of the
# session, and assigned locals write back on success. Returns 1 when the
# entry compiled and ran to completion (dbg_eval_value/dbg_eval_echo_type
# then hold the result), 0 when it failed to compile or faulted (already
# reported and rolled back by the engine, bindings included).
int dbg_eval_entry(char* entry_text, int stop_addr, int esp):
	# Give this eval its own binding record and stop context; a nested
	# eval (a breakpoint hit inside code this entry executes) saves ours
	# here on its own stack and restores it before we use them again.
	char* outer_scratch = dbg_eval_scratch
	char* outer_from = dbg_eval_bound_from
	char* outer_to = dbg_eval_bound_to
	char* outer_size = dbg_eval_bound_size
	char* outer_sym = dbg_eval_bound_sym
	int outer_count = dbg_eval_bound_count
	int outer_stop = dbg_eval_stop_addr
	int outer_esp = dbg_eval_esp
	int outer_hook = repl_bind_hook
	dbg_eval_scratch = 0
	dbg_eval_bound_count = 0
	dbg_eval_stop_addr = stop_addr
	dbg_eval_esp = esp
	repl_bind_hook = cast(int, dbg_eval_bind_hook)

	repl_result r = repl_eval(entry_text)

	int ok = 0
	if (r.status == 1):
		dbg_eval_writeback()
		dbg_eval_unbind()
		dbg_eval_value = r.value
		dbg_eval_echo_type = r.echo_type
		ok = 1

	repl_bind_hook = outer_hook
	if (dbg_eval_scratch != 0):
		free(dbg_eval_scratch)
		free(dbg_eval_bound_from)
		free(dbg_eval_bound_to)
		free(dbg_eval_bound_size)
		free(dbg_eval_bound_sym)
	dbg_eval_scratch = outer_scratch
	dbg_eval_bound_from = outer_from
	dbg_eval_bound_to = outer_to
	dbg_eval_bound_size = outer_size
	dbg_eval_bound_sym = outer_sym
	dbg_eval_bound_count = outer_count
	dbg_eval_stop_addr = outer_stop
	dbg_eval_esp = outer_esp
	return ok


# Non-printing evaluation for conditions and logpoints. Sets dbg_eval_ok
# to 0 (a compile error already reported its own diagnostic) or 1; the
# return value is only meaningful when dbg_eval_ok is 1, so callers must
# check it before trusting a 0 result as "condition false" rather than
# "condition failed to compile".
int dbg_eval_call(char* expr, int stop_addr, int esp):
	dbg_eval_ok = 0
	char* entry_text = strjoin(c"return ", expr)
	int ok = dbg_eval_entry(entry_text, stop_addr, esp)
	free(entry_text)
	# A staged "return <expr>" entry cannot define a generic, so no later
	# entry re-parses its file; remove it now instead of at repl_cleanup.
	# Conditions and logpoints evaluate on every hit, and a long run would
	# otherwise flood the staging directory with one file per hit. (The
	# 'repl' command's entries go through dbg_eval_entry directly and
	# keep their files, like entries at the REPL prompt.)
	if (repl_staged_path != 0):
		unlink(repl_staged_path)
	if (ok == 0):
		return 0
	dbg_eval_ok = 1
	return dbg_eval_value


# Evaluate the expression at the stop and print its value.
void dbg_eval(char* expr, int stop_addr, int esp):
	int v = dbg_eval_call(expr, stop_addr, esp)
	if (dbg_eval_ok == 0):
		return;
	print(c"= ")
	dbg_print_int_value(v)
	put_char(10)
