/*
REPL session and eval engine. No prompt or I/O policy lives here:
repl.w is the command-line front end (argument parsing, banner, prompt
loop, auto-indent, :commands, history, echo printing), and repl/scan.w
is the continuation scanner it reads entries with.

repl_init() maps the executable code buffer, installs the recovery jump
buffers, the runtime-fault signal handlers and the per-arch syscall
stubs, preloads the stdlib and the container runtime, and creates the
per-session staging directory. repl_eval() then runs one entry: the
text is staged to its own file, compiled into the buffer as a fresh
anonymous function __repl_N, and called immediately. Declarations --
imports, structs, extern, function definitions and top-level variables
-- define symbols that persist for the whole session; executable
statements become the body of the entry function.

Top-level variable declarations become globals with storage in the code
buffer (jumped over by the entry function), so their values survive
between entries. Redefining a name declares a fresh symbol that shadows
the old one: for variables, code compiled earlier keeps its old binding
and later entries see the new one; for functions, the late-binding
registry additionally repatches every already-compiled call site to the
newest definition (issue #114 -- see the registry section below).

When the entry is a single bare expression, its value and compile-time
type come back in repl_eval's result for the front end to echo; the
optional repl_echo_hook runs inside the fault window (echoing can
dereference a bad pointer too).

A compile error does not end the session: repl_compile_entry checkpoints
the compiler's globals and error() jumps back (repl_setjmp/repl_longjmp),
after which the checkpoint rolls back the failed entry's code and
symbols.

A runtime fault in an executing entry (SIGSEGV/SIGILL/SIGBUS/SIGFPE)
does not exit either: signal handlers (the delivery shims replicated
from debugger/wdbg.w) report the signal, print a stack trace, and
long-jump back into repl_eval; the same checkpoint then rolls the entry
back exactly like a compile error.
*/
import compiler.compiler
import lib.stack_trace
import lib.utf8
import debugger.sigcontext
import structures.json
import structures.json_codec


# Result of one repl_eval() call. status 1: the entry compiled and ran
# to completion. status 0: it failed to compile (the error is already
# reported and the entry rolled back). status 2: a runtime fault rolled
# it back (already reported by the fault handler). value and echo_type
# carry a bare expression's result and its compile-time type for
# echoing; echo_type is -1 when the entry ended with something that
# should not echo.
struct repl_result:
	int status
	int value
	int echo_type


# Optional echo hook: when nonzero, called as hook(value, echo_type)
# after the entry function returns, still inside the fault window --
# echoing can dereference a bad pointer, and a fault while echoing must
# roll the entry back like any other runtime fault. The front end points
# this at its printing routine; embedders can leave it 0 and format
# repl_eval's returned value themselves.
int repl_echo_hook

# Optional pre-entry hook: when nonzero, called as hook() inside
# repl_compile_entry after the entry's anonymous function symbol is
# declared and before the entry's items compile. An embedder uses it to
# declare extra symbols the entry should see -- wdbg (debugger/eval.w)
# binds the stopped frame's locals and arguments here. Symbols the hook
# declares sit below the entry's own declarations in the table, and like
# them they roll back with the entry on a compile error or fault.
int repl_bind_hook

# When nonzero, repl_eval compiles the entry as usual (so its
# declarations persist and repl_result_type reflects its final
# expression) but does not call the compiled entry function: no
# statement in it executes, so a call, an assignment or a print produces
# no side effect. repl.w's :type command sets this to report an
# expression's compile-time type without evaluating it. A skipped
# entry's late-bind patches (#114) are discarded rather than applied,
# matching "patches apply only after the entry compiles AND executes".
int repl_no_run


int repl_counter

# Type of the entry's final bare expression, for echoing; -1 means the
# entry ended with something that should not echo.
int repl_result_type

# The staged entry file's descriptor, so error recovery can close it even
# when the failure happened inside an imported file.
int repl_entry_file


# ---------------------------------------------------------------------------
# Compiling entries.

# Emit a jump over a region that must not execute inline in the entry
# function (module code from imports, function bodies, global storage).
# Returns the position to patch with repl_skip_end.
int repl_skip_start():
	jmp_int32(0)
	return codepos


void repl_skip_end(int pos):
	save_int32(code + pos - 4, codepos - pos)


# ---------------------------------------------------------------------------
# Late binding for redefined functions (issue #114).
#
# Call sites bake their target's address at compile time: sym_get_value
# materializes it as an immediate (the "mov eax, fn; call eax" pattern),
# so redefining f at the prompt would leave every previously compiled
# caller still calling the old f. While an entry (or a loaded file)
# compiles, the compiler's repl_call_site_hook reports every function
# address slot sym_get_value emits, and the registry below records them
# by name. When a function definition at the prompt completes, every
# recorded slot for that name is rewritten in place (be_addr_slot_write,
# the same slot-patching the GOT mechanism for variadic C imports and the
# 'U'-prototype backpatch chains use), so all callers -- however many
# generations of redefinition back they were compiled -- call the latest
# definition. Prototype ('U') sites are registered too: their slots hold
# backpatch-chain links until the first definition resolves them, and no
# patch can run before that, because patching is keyed to a definition of
# that very name completing.
#
# The registry is one flat growable buffer of (name, slot) records,
# checkpointed by count: rolling an entry back truncates it in lockstep
# with codepos, so a failed entry's slots (offsets later code will reuse)
# are never patched. Patches are queued per definition and applied only
# after the whole entry has compiled AND executed: a definition followed
# by a failing item in the same entry, or an entry that compiles but
# faults at runtime, rolls back completely, and the old callers must
# keep their old target in those cases. (The one visible consequence:
# code executed by the very entry that redefines f still reaches the
# previous f; from the next entry on, every caller sees the new one.)
#
# Ordinary compiles never set the hook: nothing is registered and the
# emitted bytes are unchanged (the self-host verify fixpoints prove it).

char* repl_sites /* (name, slot) records, 2 words each */
int repl_sites_count
int repl_sites_capacity

char* repl_sites_pending /* (name, address) patches queued by this entry */
int repl_sites_pending_count
int repl_sites_pending_capacity


# Hook target for the compiler's repl_call_site_hook: record one function
# address slot the compiling entry just materialized. The name is cloned;
# the caller may free or reuse its buffer.
void repl_register_call_site(char* name, int slot):
	if (repl_sites_count == repl_sites_capacity):
		int cap = repl_sites_capacity * 2
		if (cap == 0):
			cap = 128
			repl_sites = malloc(cap * 2 * __word_size__)
		else:
			repl_sites = realloc(repl_sites, repl_sites_capacity * 2 * __word_size__, cap * 2 * __word_size__)
		repl_sites_capacity = cap
	char* rec = repl_sites + repl_sites_count * 2 * __word_size__
	save_word(rec, cast(int, strclone(name)))
	save_word(rec + __word_size__, slot)
	repl_sites_count = repl_sites_count + 1


# Queue "rewrite every recorded site for name to address" until the entry
# is known good. Called right after a function definition at the prompt
# completes ('D' symbols only: an undefined prototype's address slot holds
# its backpatch chain, not an entry point).
void repl_queue_late_bind(char* name, int address):
	if (repl_sites_pending_count == repl_sites_pending_capacity):
		int cap = repl_sites_pending_capacity * 2
		if (cap == 0):
			cap = 8
			repl_sites_pending = malloc(cap * 2 * __word_size__)
		else:
			repl_sites_pending = realloc(repl_sites_pending, repl_sites_pending_capacity * 2 * __word_size__, cap * 2 * __word_size__)
		repl_sites_pending_capacity = cap
	char* rec = repl_sites_pending + repl_sites_pending_count * 2 * __word_size__
	save_word(rec, cast(int, strclone(name)))
	save_word(rec + __word_size__, address)
	repl_sites_pending_count = repl_sites_pending_count + 1


# Apply the queued patches: every registered slot whose name matches is
# rewritten to the queued definition's address. Queue order is definition
# order, so with several redefinitions in one entry the last one wins.
# Sites the same entry compiled against the new definition are in the
# registry too; rewriting them stores the address they already hold.
void repl_apply_late_bind():
	int i = 0
	while (i < repl_sites_pending_count):
		char* rec = repl_sites_pending + i * 2 * __word_size__
		char* name = cast(char*, load_word(rec))
		int address = load_word(rec + __word_size__)
		int k = 0
		while (k < repl_sites_count):
			char* site = repl_sites + k * 2 * __word_size__
			if (strcmp(cast(char*, load_word(site)), name) == 0):
				be_addr_slot_write(load_word(site + __word_size__), address)
			k = k + 1
		free(name)
		i = i + 1
	repl_sites_pending_count = 0


# Rollback support: discard the queued patches of a failed entry, and
# truncate the registry back to its checkpointed count.
void repl_discard_late_bind():
	int i = 0
	while (i < repl_sites_pending_count):
		free(cast(char*, load_word(repl_sites_pending + i * 2 * __word_size__)))
		i = i + 1
	repl_sites_pending_count = 0


void repl_sites_truncate(int count):
	while (repl_sites_count > count):
		repl_sites_count = repl_sites_count - 1
		free(cast(char*, load_word(repl_sites + repl_sites_count * 2 * __word_size__)))


# Declare a global symbol for a REPL definition. An undefined symbol (a
# prototype with pending call sites) is reused so its backpatch chain
# resolves; a defined one gets a fresh entry that shadows it, because
# sym_lookup keeps the LAST match. This is Python-style rebinding: later
# entries bind the new definition, and for functions the late-binding
# registry repatches earlier-compiled call sites too (variables keep
# their old storage binding in earlier code).
int repl_declare_global(char* name, int type, int symtype):
	int t = sym_lookup(name)
	if (t >= 0):
		if (table[t + 1] == 'U'):
			save_int(table + t + 6, type)
			save_int(table + t + 10, symtype)
			save_int(table + t + 18, pointer_indirection)
			return t
	sym_declare(name, type, 'U', code_offset, symtype)
	return table_pos - symbol_data_size()


# True when the current token begins a non-expression statement.
int repl_token_is_statement():
	if (peek(c"{")):
		return 1
	if (peek(c":")):
		return 1
	if (peek(c"if")):
		return 1
	if (peek(c"while")):
		return 1
	if (peek(c"for")):
		return 1
	if (peek(c"switch")):
		return 1
	if (peek(c"break")):
		return 1
	if (peek(c"continue")):
		return 1
	if (peek(c"return")):
		return 1
	if (peek(c"debugger")):
		return 1
	if (peek(c"pass")):
		return 1
	if (peek(c"raw_asm")):
		return 1
	if (peek(c"defer")):
		return 1
	# prefix increment/decrement statement (grammar/increment.w)
	if (peek(c"++")):
		return 1
	if (peek(c"--")):
		return 1
	return 0


# 'name := expression' in an entry: a persistent variable whose type is
# inferred from the initializer, mirroring the typed persistent-variable
# path below. The initializer compiles into the entry function first
# (its type is unknown until then); the storage blob is emitted after,
# jumped over like every other REPL definition.
int repl_infer_declaration():
	int c0 = token[0]
	int is_ident = (('a' <= c0) & (c0 <= 'z')) | (('A' <= c0) & (c0 <= 'Z')) | (c0 == '_')
	if (is_ident == 0):
		return 0
	if ((nextc != ':') & (nextc != ' ') & (nextc != 9)):
		return 0
	char* name = strclone(token)
	char* save = generic_reparse_save()
	get_token()
	if (peek(c":=") == 0):
		free(name)
		getchar_seek(file, load_ptr(save + 7 * __word_size__))
		generic_reparse_restore(save)
		return 0
	free(cast(char*, load_ptr(save + 11 * __word_size__)))
	free(save)
	get_token() /* consume ':=' */
	int got = expression()
	got = promote(got)
	int decl_type = inferred_storage_type(got)
	expect_or_newline(c";")
	int global_symbol = repl_declare_global(name, decl_type, 1)
	int gskip = repl_skip_start()
	sym_define_global(global_symbol)
	emit_global_storage(decl_type)
	repl_skip_end(gskip)
	pointer_indirection = 0
	# The value (or struct address) is in eax; fetch the storage address
	# and store through it
	push_eax()
	stack_pos = stack_pos + 1
	sym_get_value(name)
	push_eax()
	stack_pos = stack_pos + 1
	pop_ebx()
	stack_pos = stack_pos - 1
	pop_eax()
	stack_pos = stack_pos - 1
	if (type_num_args(decl_type) > 0):
		assign_store_struct(decl_type)
	else:
		assign_store(decl_type)
	free(name)
	return 1


# Compile one top-level item of the entry: a declaration (import, struct,
# extern, function, persistent variable) or an executable statement.
void repl_entry_item(int entry_symbol):
	repl_result_type = -1

	# Pure declarations: none of this executes now, but imports and extern
	# shims emit code, so the entry function jumps over the region
	if (peek(c"import") | peek(c"type") | peek(c"struct") | peek(c"union") | peek(c"enum") | peek(c"c_lib") | peek(c"extern")):
		int skip = repl_skip_start()
		if (import_statement()) {}
		else if (type_alias_declaration()) {}
		else if (struct_declaration()) {}
		else if (union_declaration()) {}
		else if (enum_declaration()) {}
		else if (extern_statement()) {}
		repl_skip_end(skip)
		current_function_symbol = entry_symbol
		number_of_args = 0
		return;

	# Generic function definitions ('T twice[T](T a):'): captured into
	# the generics registry (no code emitted) and skipped. Each entry is
	# staged in its own file, so the recorded span stays re-parseable
	# from later entries.
	if (generic_declaration_scan_repl()):
		current_function_symbol = entry_symbol
		number_of_args = 0
		return;

	# type-name ...: a function definition or a persistent variable
	if (peek(c"const") | (peek(c"map") & (nextc == '[')) | (peek(c"set") & (nextc == '[')) | (peek(c"list") & (nextc == '[')) | (type_lookup(token) >= 0) | generic_type_starts_here()):
		int decl_type = type_name()
		if (token[0] == 0):
			error(c"identifier expected after type name")
		char* decl_name = strclone(token)
		get_token()

		# function definition, e.g. "int add(int a, int b):"
		if (peek(c"(")):
			int function_symbol = repl_declare_global(decl_name, decl_type, 2)
			get_token() /* consume the '(' */
			int fskip = repl_skip_start()
			function_definition(function_symbol)
			repl_skip_end(fskip)
			# Late binding (#114): once this entry compiles and runs to
			# completion, rewrite every call site compiled against an
			# older definition of this name to the address just defined.
			# Only 'D' symbols: a bare prototype ("int f(int);") stays
			# 'U' and its address slot holds the backpatch chain.
			if (table[function_symbol + 1] == 'D'):
				repl_queue_late_bind(decl_name, load_int(table + function_symbol + 2))
			current_function_symbol = entry_symbol
			number_of_args = 0
			enclosing_tab_level = 0
			free(decl_name)
			return;

		# persistent variable: storage lives in the code buffer (jumped
		# over); the initializer runs inside the entry function
		int global_symbol = repl_declare_global(decl_name, decl_type, 1)
		int gskip = repl_skip_start()
		sym_define_global(global_symbol)
		emit_global_storage(decl_type)
		repl_skip_end(gskip)
		pointer_indirection = 0

		if (accept(c"=")):
			# compile "name = expression" into the entry function
			sym_get_value(decl_name) /* address into eax */
			push_eax()
			stack_pos = stack_pos + 1
			int value_type = expression()
			value_type = promote(value_type)
			# Conversions the compiler's variable_declaration also
			# performs (var boxing, cstr-to-string, float widths)
			coerce(decl_type, value_type)
			pop_ebx()
			if (types_compatible_with_expression(decl_type, value_type) == 0):
				warn_type_mismatch(c"initialization", decl_type, value_type)
			assign_store(decl_type)
			stack_pos = stack_pos - 1
		expect_or_newline(c";")
		free(decl_name)
		return;

	# 'name := expression': a persistent variable with an inferred type
	if (repl_infer_declaration()):
		return;

	# control flow and other non-expression statements
	if (repl_token_is_statement()):
		int statement_table_pos = table_pos
		enclosing_tab_level = 0
		statement()
		table_pos = statement_table_pos /* drop statement-local symbols */
		return;

	# bare expression: keep its value for echoing (unless it assigns)
	expression_is_assignment = 0
	last_call_return_type = -1
	last_call_end = -1
	# A REPL entry is statement position, so a trailing 'x++'/'x--'
	# reads as the increment statement (grammar/increment.w), exactly
	# like statement()'s expression fallback
	increment_statement_context = 1
	int result_type = expression()
	promote(result_type)
	expect_or_newline(c";")
	repl_result_type = type_real(result_type)
	# When the expression ends in a call, the callee's declared return
	# type drives the echo: void stays silent, char* prints as a string
	if ((result_type == 3) & (last_call_end == codepos)):
		if (last_call_return_type >= 0):
			repl_result_type = last_call_return_type
	if (expression_is_assignment):
		repl_result_type = -1


# ---------------------------------------------------------------------------
# Entry rollback: a checkpoint of everything a failed entry could leave
# half-updated, taken before each entry compiles. It is restored when
# error() long-jumps out of a failing compile, and again when a runtime
# fault long-jumps out of the entry's execution (repl_fault below), which
# discards the faulted entry's definitions exactly like a compile error.

int repl_saved_codepos
int repl_saved_table_pos
int repl_saved_stack_pos
int repl_saved_loop_depth
int repl_saved_loop_break_chain
int repl_saved_loop_continue_chain
int repl_saved_loop_stack_pos
int repl_saved_switch_depth
int repl_saved_switch_break_chain
int repl_saved_switch_stack_pos
int repl_saved_break_in_switch
int repl_saved_defer_count
int repl_saved_for_cleanup_count
int repl_saved_number_of_args
int repl_saved_type_count
int repl_saved_imported_count
int repl_saved_alias_base
int repl_saved_alias_count
int repl_saved_plain_base
int repl_saved_plain_count
int repl_saved_function_symbol
int repl_saved_sites_count


void repl_checkpoint():
	repl_saved_codepos = codepos
	repl_saved_table_pos = table_pos
	repl_saved_stack_pos = stack_pos
	repl_saved_loop_depth = loop_depth
	repl_saved_loop_break_chain = loop_break_chain
	repl_saved_loop_continue_chain = loop_continue_chain
	repl_saved_loop_stack_pos = loop_stack_pos
	repl_saved_switch_depth = switch_depth
	repl_saved_switch_break_chain = switch_break_chain
	repl_saved_switch_stack_pos = switch_stack_pos
	repl_saved_break_in_switch = break_in_switch
	repl_saved_defer_count = defer_count()
	repl_saved_for_cleanup_count = for_cleanup_count()
	repl_saved_number_of_args = number_of_args
	repl_saved_type_count = type_count()
	repl_saved_imported_count = imported_count
	repl_saved_alias_base = import_alias_base
	repl_saved_alias_count = import_alias_count
	repl_saved_plain_base = import_plain_base
	repl_saved_plain_count = import_plain_count
	repl_saved_function_symbol = current_function_symbol
	repl_saved_sites_count = repl_sites_count


void repl_rollback():
	codepos = repl_saved_codepos
	table_pos = repl_saved_table_pos
	stack_pos = repl_saved_stack_pos
	loop_depth = repl_saved_loop_depth
	loop_break_chain = repl_saved_loop_break_chain
	loop_continue_chain = repl_saved_loop_continue_chain
	loop_stack_pos = repl_saved_loop_stack_pos
	switch_depth = repl_saved_switch_depth
	switch_break_chain = repl_saved_switch_break_chain
	switch_stack_pos = repl_saved_switch_stack_pos
	break_in_switch = repl_saved_break_in_switch
	defer_truncate(repl_saved_defer_count)
	for_cleanup_truncate(repl_saved_for_cleanup_count)
	number_of_args = repl_saved_number_of_args
	type_table_truncate(repl_saved_type_count)
	imported_count = repl_saved_imported_count
	import_alias_base = repl_saved_alias_base
	import_alias_count = repl_saved_alias_count
	import_plain_base = repl_saved_plain_base
	import_plain_count = repl_saved_plain_count
	current_function_symbol = repl_saved_function_symbol
	# Late binding (#114): the failed entry's queued patches must never
	# apply (its definitions just rolled back), and its registered call
	# sites sit at code offsets later entries will reuse
	repl_discard_late_bind()
	repl_sites_truncate(repl_saved_sites_count)
	pointer_indirection = 0
	# error() can jump out from inside a condition or cast() operand;
	# clear the parse-context flags so later entries warn correctly
	condition_context = 0
	cast_context = 0
	diag_clear()


# ---------------------------------------------------------------------------
# :reset support. repl.w calls repl_genesis_checkpoint() once, after
# repl_init() and any startup file load finish and before the prompt loop
# starts, snapshotting the same fields repl_checkpoint/repl_rollback track
# per entry. repl_reset_to_genesis() (repl.w's :reset) then rolls the
# whole session back to that snapshot the same way a failed entry rolls
# back to its pre-entry one -- just spanning every entry (and any :load)
# since startup instead of one.

int repl_genesis_codepos
int repl_genesis_table_pos
int repl_genesis_stack_pos
int repl_genesis_loop_depth
int repl_genesis_loop_break_chain
int repl_genesis_loop_continue_chain
int repl_genesis_loop_stack_pos
int repl_genesis_switch_depth
int repl_genesis_switch_break_chain
int repl_genesis_switch_stack_pos
int repl_genesis_break_in_switch
int repl_genesis_defer_count
int repl_genesis_for_cleanup_count
int repl_genesis_number_of_args
int repl_genesis_type_count
int repl_genesis_imported_count
int repl_genesis_alias_base
int repl_genesis_alias_count
int repl_genesis_plain_base
int repl_genesis_plain_count
int repl_genesis_sites_count
int repl_genesis_taken


void repl_genesis_checkpoint():
	repl_genesis_codepos = codepos
	repl_genesis_table_pos = table_pos
	repl_genesis_stack_pos = stack_pos
	repl_genesis_loop_depth = loop_depth
	repl_genesis_loop_break_chain = loop_break_chain
	repl_genesis_loop_continue_chain = loop_continue_chain
	repl_genesis_loop_stack_pos = loop_stack_pos
	repl_genesis_switch_depth = switch_depth
	repl_genesis_switch_break_chain = switch_break_chain
	repl_genesis_switch_stack_pos = switch_stack_pos
	repl_genesis_break_in_switch = break_in_switch
	repl_genesis_defer_count = defer_count()
	repl_genesis_for_cleanup_count = for_cleanup_count()
	repl_genesis_number_of_args = number_of_args
	repl_genesis_type_count = type_count()
	repl_genesis_imported_count = imported_count
	repl_genesis_alias_base = import_alias_base
	repl_genesis_alias_count = import_alias_count
	repl_genesis_plain_base = import_plain_base
	repl_genesis_plain_count = import_plain_count
	repl_genesis_sites_count = repl_sites_count
	repl_genesis_taken = 1


# Roll every declaration, import and late-bind site added since the
# genesis checkpoint back out, exactly like repl_rollback does for a
# single failed entry. Returns 0 when repl_genesis_checkpoint() was never
# called (nothing to reset to). Only safe between entries: no entry may
# be mid-compile or mid-execution.
int repl_reset_to_genesis():
	if (repl_genesis_taken == 0):
		return 0
	codepos = repl_genesis_codepos
	table_pos = repl_genesis_table_pos
	stack_pos = repl_genesis_stack_pos
	loop_depth = repl_genesis_loop_depth
	loop_break_chain = repl_genesis_loop_break_chain
	loop_continue_chain = repl_genesis_loop_continue_chain
	loop_stack_pos = repl_genesis_loop_stack_pos
	switch_depth = repl_genesis_switch_depth
	switch_break_chain = repl_genesis_switch_break_chain
	switch_stack_pos = repl_genesis_switch_stack_pos
	break_in_switch = repl_genesis_break_in_switch
	defer_truncate(repl_genesis_defer_count)
	for_cleanup_truncate(repl_genesis_for_cleanup_count)
	number_of_args = repl_genesis_number_of_args
	type_table_truncate(repl_genesis_type_count)
	imported_count = repl_genesis_imported_count
	import_alias_base = repl_genesis_alias_base
	import_alias_count = repl_genesis_alias_count
	import_plain_base = repl_genesis_plain_base
	import_plain_count = repl_genesis_plain_count
	repl_sites_truncate(repl_genesis_sites_count)
	pointer_indirection = 0
	condition_context = 0
	cast_context = 0
	diag_clear()
	return 1


# Compile the staged entry file. Returns the address of the entry's
# anonymous function, or 0 when the entry failed to compile.
int repl_compile_entry(char* path):
	# Checkpoint everything a failed compile could leave half-updated
	repl_checkpoint()

	repl_recovery = 1
	# Late binding (#114): register the function-address slots this entry
	# emits, so a redefinition can repatch them later. Armed only while
	# the engine compiles; the echo path's descriptor building stays out.
	repl_call_site_hook = cast(int, repl_register_call_site)
	if (repl_setjmp(repl_jump_buffer)):
		# error() jumped back: roll back the failed entry and skip execution
		repl_recovery = 0
		repl_call_site_hook = 0
		repl_rollback()
		# The failure may have happened inside an imported file
		if (file != repl_entry_file):
			close(file)
		close(repl_entry_file)
		return 0

	filename = path
	file = open(path, 0, 511)
	asserts(c"could not reopen entry buffer", file >= 0)
	getchar_reset(file)
	repl_entry_file = file
	line_number = 0
	column_number = 0
	tab_level = 0
	byte_offset = 0
	nextc = get_character()
	get_token()

	char* name = cstr(f"__repl_{repl_counter}")
	repl_counter = repl_counter + 1

	int entry_symbol = sym_declare_global(name, 1, 2)
	sym_define_global(entry_symbol)
	int entry_start = codepos
	current_function_symbol = entry_symbol
	number_of_args = 0
	defer_reset()
	repl_result_type = -1
	if (repl_bind_hook != 0):
		repl_bind_hook()

	while (token[0] != 0):
		repl_entry_item(entry_symbol)

	# The entry function's implicit end is a function exit: run any
	# deferred statements registered by this entry (LIFO)
	defer_emit_all()
	defer_reset()
	be_pop(stack_pos)
	stack_pos = 0
	ret()
	# Record the entry function's code length (like function_definition
	# does) so address-to-function queries (wdbg's dbg_function_at) can
	# attribute a stop inside the entry to it
	save_int(table + entry_symbol + 14, codepos - entry_start)
	# On-demand runtimes for to_json/from_json and f"..." template
	# strings: the modules' functions land after the entry's ret, so
	# they are never in the execution path. Generic instantiations
	# requested by this entry compile here too.
	generic_finish_instantiations()
	json_codec_finish_import()
	template_string_finish_import()
	prelude_finish_import()
	var_finish_import()
	generic_finish_instantiations()
	close(file)
	repl_recovery = 0
	repl_call_site_hook = 0

	int address = sym_address(name)
	free(name)
	return address


# ---------------------------------------------------------------------------
# Runtime fault recovery.
#
# A fault (SIGSEGV/SIGILL/SIGBUS/SIGFPE) inside an executing entry must
# not kill the session. The signal delivery shims replicate
# debugger/wdbg.w's (kept separate so wdbg stays untouched):
#
# i386: a non-SA_SIGINFO handler is called with the classic frame
# [restorer][sig][sigcontext...] on the stack, so &sig + 4 is the
# sigcontext, and the kernel's vdso trampoline performs sigreturn when
# the handler returns. repl_fault_entry computes the context and
# forwards to the two-argument handler.
#
# x86-64: the kernel always builds an rt frame and calls the handler
# with sig in rdi and the ucontext pointer in rdx, and rt_sigaction
# requires an SA_RESTORER trampoline. Neither matches a W function, so
# tiny runtime thunks in an executable page convert the register
# convention into a W stack call of repl_fault(sig, ucontext + 40) -
# the sigcontext is the uc_mcontext field at offset 40 - and a shared
# restorer performs rt_sigreturn.
#
# The handlers are installed once at startup but only recover while
# repl_fault_active is set, i.e. during entry execution: the recovery
# long-jumps back into repl_eval without ever calling sigreturn, so
# every handler is installed with SA_NODEFER (the kernel then never adds
# the signal to the blocked mask, and the abandoned signal frame cannot
# leave it blocked for a later faulting entry). A fault anywhere else
# (entry compilation, the REPL's own code, a loaded file's main) restores
# the signal's default disposition and returns, re-executing the faulting
# instruction, so the process dies exactly as it did before the handlers
# existed.

# Nonzero only while a compiled entry is executing; the buffer holds
# repl_eval's repl_setjmp checkpoint the fault handler jumps to.
int repl_fault_active
int repl_fault_jump_buffer

int repl_fault_thunk_page
int repl_fault_thunk_pos
int repl_fault_restorer

# Scratch struct sigaction, preallocated so the fault handler itself
# never calls malloc when restoring a default disposition.
int* repl_fault_act


void repl_fault_thunk_emit(int n, char* bytes):
	char* p = cast(char*, repl_fault_thunk_page + repl_fault_thunk_pos)
	int i = 0
	while (i < n):
		p[i] = bytes[i]
		i = i + 1
	repl_fault_thunk_pos = repl_fault_thunk_pos + n


void repl_fault_thunk_init():
	if (repl_fault_thunk_page != 0):
		return;
	repl_fault_thunk_page = mmap(0, 4096, 7, 34) /* RWX, PRIVATE|ANONYMOUS */
	asserts(c"mmap of signal thunk page failed", (repl_fault_thunk_page > 0) | (repl_fault_thunk_page < -4095))
	repl_fault_restorer = repl_fault_thunk_page
	/* mov eax,15 ; syscall  (rt_sigreturn) */
	repl_fault_thunk_emit(7, c"\xb8\x0f\x00\x00\x00\x0f\x05")


# Emit an x64 thunk calling handler(sig, &uc_mcontext) with the W stack
# convention (first argument at the highest address). The handler
# address fits an imm32: the repl image loads in the low 2GB.
int repl_fault_emit_handler_thunk(int handler):
	int addr = repl_fault_thunk_page + repl_fault_thunk_pos
	/* push rdi ; lea rax,[rdx+40] ; push rax ; mov eax,imm32 */
	repl_fault_thunk_emit(7, c"\x57\x48\x8d\x42\x28\x50\xb8")
	save_int32(cast(char*, repl_fault_thunk_page + repl_fault_thunk_pos), handler)
	repl_fault_thunk_pos = repl_fault_thunk_pos + 4
	/* call rax ; add rsp,16 ; ret  (returns into the restorer) */
	repl_fault_thunk_emit(7, c"\xff\xd0\x48\x83\xc4\x10\xc3")
	return addr


# struct sigaction: on i386 {handler, flags, restorer, mask[2]} with
# 4-byte fields, no SA_SIGINFO/SA_RESTORER (the vdso trampoline does
# sigreturn); on x86-64 {handler, flags, restorer, mask} with 8-byte
# fields, SA_SIGINFO (4) | SA_RESTORER (0x04000000) and the thunks.
void repl_fault_install(int signum, int handler, int flags):
	if (repl_fault_act == 0):
		repl_fault_act = malloc(5 * __word_size__)
	int* act = repl_fault_act
	if (__word_size__ == 8):
		repl_fault_thunk_init()
		act[0] = repl_fault_emit_handler_thunk(handler)
		act[1] = flags | 4 | 0x04000000
		act[2] = repl_fault_restorer
		act[3] = 0
	else:
		act[0] = handler
		act[1] = flags
		act[2] = 0
		act[3] = 0
		act[4] = 0
	int err = rt_sigaction(signum, act, 0)
	asserts(c"rt_sigaction failed", err == 0)


# Restore a signal's default disposition. Returning from the handler
# then re-executes the faulting instruction, which kills the process
# with the same signal (and exit status) as an unhandled fault.
void repl_fault_restore_default(int signum):
	int* act = repl_fault_act
	act[0] = 0 /* SIG_DFL */
	act[1] = 0
	act[2] = 0
	act[3] = 0
	act[4] = 0
	rt_sigaction(signum, act, 0)


# Symbolized stack trace of the fault, written to stderr. This mirrors
# print_stack_trace (lib/stack_trace.w) but scans from the FAULT
# context's stack pointer instead of the handler's own: everything
# below the fault - the kernel's signal frame, the handler frames, and
# the stale return addresses the entry's just-finished compile left
# deeper in the stack - stays out of the trace. Frames inside the entry
# buffer itself carry no image symbols and are skipped by the scanner;
# calls the entry made into repl-image functions (and the prompt loop's
# main) still symbolize. Silent no-op when the image has no symbols.
void repl_fault_trace(int context):
	if (st_state == 0):
		st_init(cast(int, repl_fault_install))
	char* pcs = malloc(64 * __word_size__)
	int n = st_scan(ctx_esp(context), pcs, 64, 0)
	if (n == 0):
		free(pcs)
		return;
	st_write_cstr(c"stack trace (most recent call first):\n")
	int k = 0
	while (k < n):
		int addr = load_word(pcs + k * __word_size__)
		st_write_cstr(c"  at ")
		int e = st_func_entry(addr)
		if (e != 0):
			st_write_cstr(cast(char*, st_entry_name(e)))
		else:
			st_write_hex(addr)
		if (st_line_lookup(addr)):
			st_write_cstr(c" (")
			int fname = st_file_name(st_file_found)
			if (fname != 0):
				st_write_cstr(cast(char*, fname))
				st_write_cstr(c":")
			st_write_dec(st_line_found)
			st_write_cstr(c")")
		st_write_cstr(c"\n")
		k = k + 1
	free(pcs)


# Fault handler: report the signal, print a stack trace, and long-jump
# back into repl_eval, which rolls the entry back like a compile
# error. Clearing repl_fault_active first means a fault inside this
# handler (or anywhere outside an entry) takes the die-as-before path.
void repl_fault(int sig, int context):
	if (repl_fault_active == 0):
		repl_fault_restore_default(sig)
		return;
	repl_fault_active = 0
	print(c"runtime fault: ")
	if (sig == 11):
		print(c"SIGSEGV")
	else if (sig == 4):
		print(c"SIGILL")
	else if (sig == 7):
		print(c"SIGBUS")
	else if (sig == 8):
		print(c"SIGFPE")
	else:
		print(c"signal ")
		char* digits = itoa(sig)
		print(digits)
		free(digits)
	print(c" at eip=")
	char* h = hex_word(ctx_eip(context))
	print(h)
	free(h)
	if (sig == 11):
		print(c" fault address=")
		char* fa = hex_word(ctx_reg(context, sigcontext_cr2()))
		print(fa)
		free(fa)
	put_char(10)
	repl_fault_trace(context)
	println(c"entry rolled back")
	repl_longjmp(repl_fault_jump_buffer, 1)


void repl_fault_entry(int sig):
	repl_fault(sig, &sig + 4)


# Install the fault handlers once at startup. On x86 the kernel calls
# the 1-argument entry wrapper; on x64 the thunks call the 2-argument
# handler directly. SA_NODEFER (0x40000000) on every one: recovery
# long-jumps out of the handler without sigreturn.
void repl_fault_install_handlers():
	int handler = cast(int, repl_fault_entry)
	if (__word_size__ == 8):
		handler = cast(int, repl_fault)
	repl_fault_install(4, handler, 1073741824) /* SIGILL */
	repl_fault_install(7, handler, 1073741824) /* SIGBUS */
	repl_fault_install(8, handler, 1073741824) /* SIGFPE */
	repl_fault_install(11, handler, 1073741824) /* SIGSEGV */


# ---------------------------------------------------------------------------
# Nested evaluation. A 'debugger' statement inside an executing entry
# traps into a command loop (wdbg's), and expressions evaluated there run
# through repl_eval again while the outer repl_eval is still in flight.
# Everything the outer call still needs after it resumes -- its rollback
# checkpoint, its fault window (the jump buffer contents and the active
# flag) and its pending echo type -- lives in globals a nested call would
# clobber, so repl_eval saves them on entry and restores them on every
# exit. The same applies to wdbg evaluating a breakpoint hit inside code
# an earlier eval is already executing.

int repl_nest_size():
	return 27 * __word_size__


char* repl_nest_save():
	char* s = malloc(repl_nest_size())
	save_word(s + 0 * __word_size__, repl_saved_codepos)
	save_word(s + 1 * __word_size__, repl_saved_table_pos)
	save_word(s + 2 * __word_size__, repl_saved_stack_pos)
	save_word(s + 3 * __word_size__, repl_saved_loop_depth)
	save_word(s + 4 * __word_size__, repl_saved_loop_break_chain)
	save_word(s + 5 * __word_size__, repl_saved_loop_continue_chain)
	save_word(s + 6 * __word_size__, repl_saved_loop_stack_pos)
	save_word(s + 7 * __word_size__, repl_saved_switch_depth)
	save_word(s + 8 * __word_size__, repl_saved_switch_break_chain)
	save_word(s + 9 * __word_size__, repl_saved_switch_stack_pos)
	save_word(s + 10 * __word_size__, repl_saved_break_in_switch)
	save_word(s + 11 * __word_size__, repl_saved_defer_count)
	save_word(s + 12 * __word_size__, repl_saved_for_cleanup_count)
	save_word(s + 13 * __word_size__, repl_saved_number_of_args)
	save_word(s + 14 * __word_size__, repl_saved_type_count)
	save_word(s + 15 * __word_size__, repl_saved_imported_count)
	save_word(s + 16 * __word_size__, repl_saved_alias_base)
	save_word(s + 17 * __word_size__, repl_saved_alias_count)
	save_word(s + 18 * __word_size__, repl_saved_plain_base)
	save_word(s + 19 * __word_size__, repl_saved_plain_count)
	save_word(s + 20 * __word_size__, repl_saved_function_symbol)
	save_word(s + 21 * __word_size__, repl_fault_active)
	save_word(s + 22 * __word_size__, repl_result_type)
	save_word(s + 23 * __word_size__, repl_entry_file)
	int i = 0
	while (i < 3):
		save_word(s + (24 + i) * __word_size__, load_word(cast(char*, repl_fault_jump_buffer) + i * __word_size__))
		i = i + 1
	return s


void repl_nest_restore(char* s):
	repl_saved_codepos = load_word(s + 0 * __word_size__)
	repl_saved_table_pos = load_word(s + 1 * __word_size__)
	repl_saved_stack_pos = load_word(s + 2 * __word_size__)
	repl_saved_loop_depth = load_word(s + 3 * __word_size__)
	repl_saved_loop_break_chain = load_word(s + 4 * __word_size__)
	repl_saved_loop_continue_chain = load_word(s + 5 * __word_size__)
	repl_saved_loop_stack_pos = load_word(s + 6 * __word_size__)
	repl_saved_switch_depth = load_word(s + 7 * __word_size__)
	repl_saved_switch_break_chain = load_word(s + 8 * __word_size__)
	repl_saved_switch_stack_pos = load_word(s + 9 * __word_size__)
	repl_saved_break_in_switch = load_word(s + 10 * __word_size__)
	repl_saved_defer_count = load_word(s + 11 * __word_size__)
	repl_saved_for_cleanup_count = load_word(s + 12 * __word_size__)
	repl_saved_number_of_args = load_word(s + 13 * __word_size__)
	repl_saved_type_count = load_word(s + 14 * __word_size__)
	repl_saved_imported_count = load_word(s + 15 * __word_size__)
	repl_saved_alias_base = load_word(s + 16 * __word_size__)
	repl_saved_alias_count = load_word(s + 17 * __word_size__)
	repl_saved_plain_base = load_word(s + 18 * __word_size__)
	repl_saved_plain_count = load_word(s + 19 * __word_size__)
	repl_saved_function_symbol = load_word(s + 20 * __word_size__)
	repl_fault_active = load_word(s + 21 * __word_size__)
	repl_result_type = load_word(s + 22 * __word_size__)
	repl_entry_file = load_word(s + 23 * __word_size__)
	int i = 0
	while (i < 3):
		save_word(cast(char*, repl_fault_jump_buffer) + i * __word_size__, load_word(s + (24 + i) * __word_size__))
		i = i + 1
	free(s)


# ---------------------------------------------------------------------------
# Rendering struct echoes.

# Render a struct value as JSON for echoing (D3), reusing the compiler's
# to_json codec (grammar/json_builtin.w, structures/json_codec.w) instead
# of re-deriving the supported-field-type rules here. json_codec_descriptor
# can call error() for a field type the codec does not support (a float
# field, say); that longjmps back to the checkpoint just below through the
# same repl_setjmp hook repl_compile_entry uses, so a struct the codec
# can't encode falls back to a plain address instead of corrupting
# anything (the entry that produced the value already ran and persisted
# by the time this is called). Returns a malloc'd string, or 0 when the
# codec could not encode this type.
char* repl_echo_json(int type, int value):
	int saved_codepos = codepos
	char* saved_filename = filename
	int saved_line = line_number
	filename = c"<repl echo>"
	line_number = 0
	repl_recovery = 1
	if (repl_setjmp(repl_jump_buffer)):
		repl_recovery = 0
		codepos = saved_codepos
		filename = saved_filename
		line_number = saved_line
		return 0
	int desc = json_codec_descriptor(type)
	json_value* encoded = __w_json_encode(desc, cast(char*, value))
	repl_recovery = 0
	filename = saved_filename
	line_number = saved_line
	return json_stringify(encoded)


# ---------------------------------------------------------------------------
# Staging directory (D6): one per session, so concurrent REPL processes
# never collide and every staged entry file has a single well-known home.

# The session's staging directory (created by repl_init, pid-tagged),
# the number of entries staged so far, and the most recently staged
# entry's path. Only the path string is freed when the next entry
# replaces it: the files themselves stay until repl_cleanup(), because
# generic definitions record (file, offset) spans that later entries
# re-parse on instantiation.
char* repl_staging_dir
int repl_staged_count
char* repl_staged_path


# Path for staged entry n inside the session's staging directory
# ("<dir>/entry_<n>.w"). Shared by entry creation and session cleanup so
# the naming rule lives in one place.
char* repl_entry_path(char* dir, int n):
	return cstr(f"{dir}/entry_{n}.w")


# Remove every staged entry file this session created, then the staging
# directory itself. Only safe once the session is ending (:quit/EOF):
# generic instantiation re-parses recorded (file, offset) spans from
# these files, so they must survive until then.
void repl_remove_staging(char* dir, int file_count):
	int i = 0
	while (i < file_count):
		char* path = repl_entry_path(dir, i)
		unlink(path)
		free(path)
		i = i + 1
	rmdir(dir)


# ---------------------------------------------------------------------------
# Session lifecycle.

# The eval engine's own state: the recovery jump buffers error() and the
# fault handlers long-jump through, and the per-session staging directory
# entries compile from. repl_init() calls this as part of the full
# session setup; an embedder that already owns its code buffer and signal
# handlers (wdbg) calls just this before its first repl_eval().
void repl_engine_init():
	if (repl_jump_buffer == 0):
		repl_jump_buffer = cast(int, malloc(3 * __word_size__))
	repl_error_jump = cast(int, repl_longjmp)
	if (repl_fault_jump_buffer == 0):
		repl_fault_jump_buffer = cast(int, malloc(3 * __word_size__))


# Create the session's staging directory on first use, so a session that
# never evaluates anything (a wdbg run without a p/repl command, say)
# leaves nothing in /tmp. Every entry gets its own staging file inside
# the one per-session directory; it is pid-tagged so two REPL processes
# running concurrently (e.g. repl_test and repl_test_x64 under a
# parallel test runner) never collide.
void repl_stage_init():
	if (repl_staging_dir != 0):
		return;
	repl_staging_dir = cstr(f"/tmp/w_repl_{getpid()}")
	mkdir(repl_staging_dir, 511)


# Initialize the session: the compiler configured for in-process
# compilation, the executable buffer the compiled entries run from, the
# recovery jump buffers and fault handlers, the runtime stubs and
# preloaded library modules, and the per-session staging directory.
void repl_init():
	verbosity = -1
	# The in-process model runs compiled entries directly, so the target
	# architecture is the one this binary was compiled for.
	word_size = __word_size__
	word_size_log2 = 2
	if (word_size == 8):
		word_size_log2 = 3
	push_basic_types()
	pointer_indirection = 0
	last_identifier = malloc(8000)
	last_global_declaration = malloc(8000)

	# Executable buffer the compiled entries run from. code_offset makes
	# every embedded address point into this mapping, so no relocation is
	# needed. The codegen embeds addresses as 32-bit immediates, so on
	# x64 the buffer must sit in the low 2GB: MAP_32BIT (0x40).
	int buffer_size = 8388608
	int mmap_flags = 34 /* PRIVATE|ANONYMOUS */
	if (word_size == 8):
		mmap_flags = 34 + 64
	int buffer = mmap(0, buffer_size, 7, mmap_flags) /* RWX */
	asserts(c"mmap of code buffer failed", (buffer > 0) | (buffer < -4095))
	code = buffer + 0
	code_size = buffer_size
	codepos = 0
	code_offset = buffer

	# Recoverable compile errors and staging directory (repl_engine_init),
	# plus recoverable runtime faults: a fault inside an executing entry
	# long-jumps back into repl_eval. repl_fault_active gates the
	# handlers, so faults anywhere else still kill the process as before.
	repl_engine_init()
	repl_fault_install_handlers()

	# Runtime support: syscall stubs first, then the library itself.
	# import_module (not compile_save) registers the modules, so a loaded
	# file importing lib.lib is not compiled a second time.
	if (word_size == 8):
		define_asm_functions_x64()
	else:
		define_asm_functions()
	# The container runtime next, exactly like link_impl and wdbg_main:
	# built-in list/map/set lower to __w_list_*/__w_hash_* helper calls,
	# so the first 'new list[T]' at the prompt dies in sym_get_value
	# (with a misleading message naming the lookahead token) unless the
	# helpers are preloaded here too. This runs once at startup, before
	# any entry's repl_setjmp checkpoint exists, so per-entry rollback
	# in repl_compile_entry never touches it.
	import_module(c"structures.hash_table")
	import_module(c"structures.w_list")
	import_module(c"lib.lib")
	import_module(c"lib.assert")


# Compile a source file into the session buffer and resolve the deferred
# runtimes it may have used (print builtin, f-strings, json codec, var):
# the call sites go through backpatch chains until the modules are
# imported. When run_main is nonzero its main() runs, shifted so the
# target sees itself as argv[0]; main must be 'D'efined, because an
# undefined prototype's address slot holds its backpatch chain, not an
# entry point. Returns 1 when main ran, 0 otherwise. Afterwards every
# function and global from the file is live for later entries.
int repl_load_file(char* path, int run_main, int argc, int argv):
	# Late binding (#114): register the file's call sites too, so
	# redefining one of its functions at the prompt retargets the file's
	# own callers (the python -i workflow). A compile error here exits
	# the process (no entry checkpoint exists yet), so no rollback pairing
	# is needed.
	repl_call_site_hook = cast(int, repl_register_call_site)
	compile_input_file(path)
	generic_finish_instantiations()
	json_codec_finish_import()
	template_string_finish_import()
	prelude_finish_import()
	var_finish_import()
	generic_finish_instantiations()
	repl_call_site_hook = 0
	if (run_main == 0):
		return 0
	int main_symbol = sym_lookup(c"main")
	if (main_symbol >= 0):
		if (table[main_symbol + 1] == 'D'):
			int target_main = load_int(table + main_symbol + 2)
			target_main(argc - 1, argv + __word_size__)
			return 1
	return 0


# Stage, compile and run one entry. entry_text is the entry's source
# without a trailing newline (one is appended for the tokenizer). The
# tokenizer reads from a file, so the text is staged in the session's
# staging directory first; the entry then compiles as a fresh anonymous
# function and runs. The fault window covers the entry's execution and
# the echo of its result (echoing can dereference a bad pointer too).
# On a fault the handler long-jumps back here and the entry rolls back
# exactly like a compile error; the staged file is already closed, so
# only the compiler state restores.
repl_result repl_eval(char* entry_text):
	repl_result r
	r.status = 0
	r.value = 0
	r.echo_type = -1

	# Save the state an enclosing in-flight repl_eval still needs (see
	# repl_nest_save): this call may be running from a 'debugger' stop's
	# command loop in the middle of another entry's execution.
	char* nest = repl_nest_save()

	repl_stage_init()
	if (repl_staged_path != 0):
		free(repl_staged_path)
	repl_staged_path = repl_entry_path(repl_staging_dir, repl_staged_count)
	repl_staged_count = repl_staged_count + 1
	int out = create_file(repl_staged_path, 511)
	asserts(c"could not create entry buffer", out >= 0)
	write(out, entry_text, strlen(entry_text))
	write(out, c"\x0a", 1)
	close(out)

	int address = repl_compile_entry(repl_staged_path)
	if (address == 0):
		repl_nest_restore(nest)
		return r /* compile error: reported and rolled back already */

	if (repl_no_run):
		repl_discard_late_bind()
		r.value = 0
		r.echo_type = repl_result_type
		r.status = 1
		repl_nest_restore(nest)
		return r

	repl_fault_active = 1
	if (repl_setjmp(repl_fault_jump_buffer)):
		repl_rollback()
		r.status = 2
		repl_nest_restore(nest)
		return r
	r.value = address()
	r.echo_type = repl_result_type
	if (repl_echo_hook != 0):
		repl_echo_hook(r.value, repl_result_type)
	repl_fault_active = 0
	# Late binding (#114): the entry compiled and ran to completion, so
	# its function definitions are permanent -- rewrite every older call
	# site of each (re)defined name to the new address. A fault above
	# skips this: repl_rollback discarded the queue with the definitions.
	repl_apply_late_bind()
	r.status = 1
	repl_nest_restore(nest)
	return r


# End the session: remove the staged entry files and the staging
# directory. Only safe once no more entries will compile -- generic
# instantiation re-parses recorded spans from the staged files. A no-op
# when nothing was ever staged (the directory is created lazily).
void repl_cleanup():
	if (repl_staging_dir == 0):
		return;
	repl_remove_staging(repl_staging_dir, repl_staged_count)
