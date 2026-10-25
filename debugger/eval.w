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
import compiler.safe_session


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


const int dbg_eval_bound_max = 128
const int dbg_eval_scratch_size = 8192


void dbg_eval_copy(int from, int to, int n):
	char* src = cast(char*, from)
	char* dst = cast(char*, to)
	for i in range(n): dst[i] = src[i]


# Checked programs (#713): run the checker over the selected frame's
# function once per eval, when a visible local has a checked type, so the
# entry may read exactly the checked locals that are definitely initialized
# -- and, for borrows, still live -- at the stop. An outer frame is
# suspended inside a call its statement makes, so it is probed in call
# mode (compiler/safe_session.w): the statement's moves and exclusive loans
# count. Returns 1 when the probe ran, 0 when the frame is not stopped in an
# analyzed function (the caller then hides every checked local).
int dbg_eval_probe(int stop_addr):
	int rel = stop_addr - code_offset
	int checked = 0
	for i in range(debug_local_count):
		if (dbg_local_visible(i, rel) && safe_session_type_checked(dbg_local_type(i), 0)): checked = 1
	if (checked == 0): return 0
	int entry = dbg_find_line(rel)
	if (entry < 0): return 0
	int line = dbg_line_line(entry)
	int function = safe_session_find_function(dbg_function_name(stop_addr), dbg_file_name(dbg_line_file(entry)), line)
	if (function < 0): return 0
	safe_session_probe(function, line, (dbg_fr_sel > 0) && (dbg_fr_sel < dbg_fr_count))
	return 1


# The read-only view spelling of checked type: "ref T*" for owners and
# references, "optref T*" for optional ones, "ref T[]" for inline slices;
# 0 when it has none (lifetime labels, aggregates, unspellable targets).
# Sets *view to the view's type.
char* dbg_eval_view_spelling(int type, int* view):
	int bare = type_unqualified(type)
	int kind = type_get_kind(bare)
	if (type_record(bare).safe_lifetime != 0): return 0
	if ((kind == type_kind_safe_slice) || (kind == type_kind_safe_slicemut)):
		int element = type_record(bare).alias_target
		char* item = safe_session_spell(element)
		if (item == 0): return 0
		*view = type_get_safe_slice(element, 0, 2)
		char* prefixed = strjoin(c"ref ", item)
		char* result = strjoin(prefixed, c"[]")
		free(prefixed)
		free(item)
		return result
	int optional = (kind == type_kind_optref) || (kind == type_kind_optrefmut) || (kind == type_kind_optown)
	if ((((kind < type_kind_own) || (kind > type_kind_refmut)) && (optional == 0)) || (type_get_pointer_level(bare) != 1)): return 0
	char* target = safe_session_spell(type_safe_target(bare))
	if (target == 0): return 0
	char* result = 0
	if (optional):
		*view = type_get_safe(type_safe_target(bare), 6)
		result = strjoin(c"optref ", target)
	else:
		*view = type_get_safe(type_safe_target(bare), 2)
		result = strjoin(c"ref ", target)
	free(target)
	return result


# Present local i to the entry's checker. A checked owner, borrow or slice
# that the probe found usable becomes a read-only shared view; any other
# checked local is hidden with the reason a reference reports. Plain
# locals pass by value when their type can be spelled.
void dbg_eval_present(int i, int probed):
	char* name = dbg_local_name_at(i)
	int type = dbg_local_type(i)
	if (safe_session_type_checked(type, 0) == 0):
		char* spelling = safe_session_spell(type)
		if (spelling != 0): safe_session_view(name, type, spelling)
		return;
	if (probed == 0):
		safe_session_hide(name, c"safe: checked locals are only available in analyzed functions at a debugger stop")
		return;
	int view = -1
	char* spelling = dbg_eval_view_spelling(type, &view)
	if (spelling == 0):
		safe_session_hide(name, c"safe: only checked owners, references, optional references and slices without lifetime labels can be viewed at a debugger stop")
		return;
	# Parameters are unique in their function; locals match by declaration
	# line too, so a shadowed outer declaration is never mistaken for one.
	int line = -1
	if (dbg_local_kind(i) != 'A'):
		int entry = dbg_find_line(dbg_local_decl(i))
		if (entry >= 0): line = dbg_line_line(entry)
	int state = safe_session_probe_state(name, line)
	if (state == 1):
		safe_session_view(name, view, spelling)
		return;
	free(spelling)
	if (state == 2):
		safe_session_hide(name, c"safe: this checked local is lent exclusively to the call this frame is suspended in")
		return;
	safe_session_hide(name, c"safe: this checked local is not definitely initialized and live at this debugger stop")


# Bind every local and argument visible at the stop as a defined global
# object pointing at a scratch copy of its value. Later declarations win
# in sym_lookup, so inner shadowing declarations take precedence over
# outer ones and over real globals, like in the source. Runs as the
# engine's pre-entry hook inside repl_compile_entry, after the entry's
# rollback checkpoint: a failed entry rolls the bindings back with it.
void dbg_eval_bind_locals(int stop_addr, int esp):
	dbg_eval_bound_count = 0
	dbg_frame_compute(stop_addr)
	if (dbg_frame_ok == 0): return;
	if (dbg_eval_scratch == 0):
		dbg_eval_scratch = cast(char*, malloc(dbg_eval_scratch_size))
		dbg_eval_bound_from = cast(char*, malloc(dbg_eval_bound_max * __word_size__))
		dbg_eval_bound_to = cast(char*, malloc(dbg_eval_bound_max * __word_size__))
		dbg_eval_bound_size = cast(char*, malloc(dbg_eval_bound_max * 4))
		dbg_eval_bound_sym = cast(char*, malloc(dbg_eval_bound_max * 4))
	int rel = stop_addr - code_offset
	int probed = 0
	if (safe_check_requested()): probed = dbg_eval_probe(stop_addr)
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
			if ((used + size <= dbg_eval_scratch_size) && (dbg_eval_bound_count < dbg_eval_bound_max)):
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
					if (safe_check_requested()): dbg_eval_present(i, probed)
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
		int name_start = load_int(dbg_eval_bound_sym + b * 4)
		# Retract from the name index first, while the name is still
		# readable, and only corrupt the bytes once the index confirms a
		# live record really starts there -- a rollback may have
		# truncated the binding away and handed those bytes to an
		# unrelated symbol (compiler/symbol_table.w, sym_index_unbind).
		if (sym_index_unbind(name_start)): table[name_start] = 1
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
	if (repl_staged_path != 0): unlink(repl_staged_path)
	if (ok == 0): return 0
	dbg_eval_ok = 1
	return dbg_eval_value


# Evaluate the expression at the stop and print its value.
void dbg_eval(char* expr, int stop_addr, int esp):
	int v = dbg_eval_call(expr, stop_addr, esp)
	if (dbg_eval_ok == 0): return;
	print(c"= ")
	dbg_print_int_value(v)
	put_char(10)
