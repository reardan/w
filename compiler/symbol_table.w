/*
table: stack of symbols
symbol format:
string: symbol
char: \0 
char: [DULA]
int: 2: address
int: 6: type
int: 10: symtype
int: 14: size
int: 18: pointer indirection level
int: 22: number of declared parameters (functions), -1 when unknown
int: 26: declared parameter types (up to 10 slots of 4 bytes each)
int: 66: declaration file index (dwarf.w debug_files), -1 when unknown
int: 70: declaration line (1-based)
int: 74: declaration column (1-based)
int: 78: variadic C import: number of fixed parameters, -1 when not variadic
int: 82: GOT slot vaddr for extern imports, 0 otherwise
int: 86: default-value bitmask: bit i set when parameter i has a default
int: 90: default parameter values (up to 10 slots of 4 bytes each)
int: 130: W variadic function: number of fixed parameters, -1 when not variadic
int: 134: 1 for generator functions (declared with the 'generator' marker)
int: 138: 1 for gpu kernels (declared with the 'kernel' marker)
*/
char *table
int table_size
int table_pos
int stack_pos

# Lookup cost counters, printed by 'w --stats'. sym_lookup_steps counts
# symbol records visited, which is the metric that actually matters here:
# it is deterministic for a given input, so it can be compared across
# machines and asserted in a test, where wall time cannot.
# sym_lookup_calls is incremented once per call, so the counting itself
# never shows up in a profile.
int sym_lookup_calls
int sym_lookup_steps

# --- symbol lookup index -------------------------------------------------
# sym_index_offsets[i] is the table offset of the NUL of the i-th live
# record -- exactly the value sym_lookup returns for it. The array exists
# because the records themselves are variable-length and packed forward,
# so the blob cannot be walked backwards; with the offsets to hand,
# sym_lookup can scan newest-first and stop at the first match, which is
# by construction the innermost declaration.
#
# Mirroring the blob is sound because the blob is append-only: table_pos
# is only ever INCREASED by sym_declare below, and every other assignment
# to it restores a previously saved, smaller value --
# grammar/statement.w:226,257, grammar/program.w:193,499,
# grammar/extern_statement.w:140, grammar/generator_decl.w:150,
# grammar/gpu_for.w:195, grammar/kernel_decl.w:249,
# repl/core.w:434,517,618. Records are never moved or reordered, so a
# position is stable for as long as it is live. Scope exit therefore
# needs no cooperation from any of those sites: sym_index_sync() below
# discards the records they truncated, lazily, on the next use.
#
# Entries are 4-byte ints read with load_int/save_int, not an int* --
# W scales int* indexing by __word_size__, which would silently make
# these 8-byte entries on the 64-bit targets.
#
# sym_index_prev[i] is the position of the previous live record with the
# SAME name as record i (-1: none, -2: retracted, see sym_index_unbind),
# and sym_name_index maps a name to the position of the newest live
# record with that name, or -1 once the name has no live record left.
# Together they turn lookup from a scan into a map read: the map finds
# the newest declaration, and the chain is only walked when that one has
# been truncated away by a scope exit.
#
# The chain is what makes truncation cheap. Popping a record hands its
# name's map entry back to its predecessor, which is O(1) because the
# popped record is the newest live record overall and therefore the head
# of its own name's chain.
char* sym_index_offsets
char* sym_index_prev
int sym_index_count
int sym_index_capacity
map[char*, int] sym_name_index


void sym_stats_dump():
	print_int0(c"sym_lookup calls: ", sym_lookup_calls)
	print_int0(c" records visited: ", sym_lookup_steps)
	print_error(c"\x0a")


int symbol_data_size():
	return 142


int next_token(int t):
	return t + symbol_data_size()


int sym_index_offset(int i):
	return load_int(sym_index_offsets + i * 4)


# Records are contiguous, so record i's name begins where record i-1's
# data block ends. sym_declare writes the name at table_pos and leaves
# table_pos at next_token(nul), so the blob has no gaps and this is exact.
int sym_index_name_start(int i):
	if (i == 0):
		return 0
	return next_token(sym_index_offset(i - 1))


# Grow to hold at least n entries. Never shrinks -- that is what makes
# scope truncation free. The oldlen handed to realloc is always exactly
# what this block was last allocated with, which lib/memory_debug.w
# checks and aborts on. Growing from a null pointer at capacity 0 is
# realloc(0, 0, n), the same call the symbol blob itself makes on the
# first sym_declare.
void sym_index_reserve(int n):
	if (n <= sym_index_capacity):
		return
	int x = sym_index_capacity
	if (x == 0):
		x = 1024
	while (x < n):
		x = x << 1
	sym_index_offsets = realloc(sym_index_offsets, sym_index_capacity * 4, x * 4)
	sym_index_prev = realloc(sym_index_prev, sym_index_capacity * 4, x * 4)
	sym_index_capacity = x


# The top live record must end exactly at table_pos. One comparison,
# always on: it catches a table_pos left off a record boundary, a
# table_pos restored to a LARGER value than the index knows about (which
# would resurrect popped records and make lookups silently miss them),
# and any future append path that bypasses sym_declare.
void sym_index_check():
	if (sym_index_count == 0):
		if (table_pos != 0):
			error(c"symbol index desync: empty index, non-empty table")
		return
	if (next_token(sym_index_offset(sym_index_count - 1)) != table_pos):
		error(c"symbol index desync: top record does not end at table_pos")


# Bring the index back in step with table_pos after a scope truncation.
# Lazy by design: the truncating sites listed above just move table_pos,
# and the next declare or lookup pays for it. Idempotent, so an error()
# longjmp between a truncation and the next sync is harmless.
# Drop the top live record. It is the newest live record overall, so it
# is the head of its own name's chain: handing the head back to its
# predecessor is the whole repair, and no other name can be affected
# because a map entry only ever holds a position of a record carrying
# that name.
#
# prev == -2 marks a record already retracted by sym_index_unbind: it is
# in no chain and no map entry points at it, and -- the reason this test
# is not merely an optimization -- its name bytes in the blob have been
# deliberately corrupted, so reading a name here would repair the wrong
# key and orphan the real one.
void sym_index_pop():
	int p = sym_index_count - 1
	int previous = load_int(sym_index_prev + p * 4)
	if (previous != -2):
		sym_name_index[&table[sym_index_name_start(p)]] = previous
	sym_index_count = p


void sym_index_sync():
	while ((sym_index_count > 0) && (sym_index_offset(sym_index_count - 1) >= table_pos)):
		sym_index_pop()
	sym_index_check()


# Position holding the record whose NUL sits at off, or -1. Offsets are
# strictly increasing, so this is a binary search.
int sym_index_find(int off):
	int lo = 0
	int hi = sym_index_count - 1
	while (lo <= hi):
		int mid = (lo + hi) >> 1
		int v = sym_index_offset(mid)
		if (v == off):
			return mid
		if (v < off):
			lo = mid + 1
		else:
			hi = mid - 1
	return -1


# Retract the record whose name starts at name_start from the name index,
# so later lookups can no longer reach it, while the record itself stays
# in the blob and stays visible to the direct table walkers.
#
# wdbg's expression evaluator retires a scratch binding by overwriting the
# first byte of its name in place (debugger/eval.w): the bindings cannot
# be popped, because persistent definitions the same entry made live above
# them. A name-keyed index would keep resolving those names, so the
# retraction has to be explicit.
#
# Returns 1 when a live record really starts at name_start and the caller
# may go on to corrupt the name, 0 when it does not. The 0 case is real: a
# REPL rollback (repl/core.w) can truncate below a recorded binding, after
# which those bytes belong to a different record or to nothing, and
# corrupting them would damage an unrelated live symbol.
int sym_index_unbind(int name_start):
	sym_index_sync()
	char* name = &table[name_start]
	int p = sym_index_find(name_start + strlen(name))
	if (p < 0):
		return 0
	if (sym_index_name_start(p) != name_start):
		return 0
	int previous = load_int(sym_index_prev + p * 4)
	if (previous == -2):
		return 1
	# Unlink p from its name's chain. It is usually the head -- the
	# bindings are the newest records when the eval starts -- but the
	# entry may have redeclared the same name above them, so the interior
	# case has to work too.
	int head = -1
	if (name in sym_name_index):
		head = sym_name_index[name]
	if (head == p):
		sym_name_index[name] = previous
	else:
		int q = head
		while (q > p):
			int r = load_int(sym_index_prev + q * 4)
			if (r == p):
				save_int(sym_index_prev + q * 4, previous)
				q = -1
			else:
				q = r
	save_int(sym_index_prev + p * 4, -2)
	return 1


void sym_table_info():
	print_error(c"sym_table_info(")
	print_int0(c"table_size: ", table_size)
	print_int0(c", table_pos: ", table_pos)
	print_int0(c", stack_pos: ", stack_pos)
	print_error(c")\x0a")


void sym_info(int symbol):
	print_error(c"sym_info(")
	int t = cast(int, table) + symbol
	print_hex0(c"address: ", load_int(t + 2))
	print_error(c", visibility: ")
	put_error(load_i(t + 1 ,1))
	print_int0(c", type: ", load_int(t + 6))
	print_int0(c", symtype: ", load_int(t + 10))
	print_int0(c", size: ", load_int(t + 14))
	print_int0(c", pointer: ", load_int(t + 18))
	print_error(c")\x0a")


void sym_last_info():
	sym_info(table_pos - symbol_data_size())
	

# Returns the table offset of the symbol's data block, or -1 when not found.
# 0 is a valid offset (the first declared symbol), so callers must test for < 0.
# Newest-first scan of the offset index. Superseded by the name index in
# sym_lookup below, but kept as the reference implementation that
# sym_index_selfcheck compares against: it depends on nothing but the
# blob and the offsets, so it is the thing to trust when the two
# disagree.
int sym_index_scan(char *s):
	int i = sym_index_count
	while (i > 0):
		i = i - 1
		int t = sym_index_name_start(i)
		int j = 0
		# Character-identical to the original forward scan, so the
		# matching rule cannot have drifted.
		while ((s[j] == table[t]) && (s[j] != 0)):
			j = j + 1
			t = t + 1

		if (s[j] == table[t]):
			return sym_index_offset(i)

	return -1


# Set by 'w --stats-selfcheck': compute the lookup both ways and abort on
# any disagreement. One self-compile with this on compares every lookup
# against the scan, which is the exhaustive equivalence check the fixpoint
# cannot give for the REPL and debugger paths.
int sym_index_selfcheck


int sym_lookup(char *s):
	sym_index_sync()
	sym_lookup_calls = sym_lookup_calls + 1
	int found = -1
	if (sym_name_index != 0):
		if (s in sym_name_index):
			int p = sym_name_index[s]
			if (p >= 0):
				sym_lookup_steps = sym_lookup_steps + 1
				found = sym_index_offset(p)
	if (sym_index_selfcheck):
		if (found != sym_index_scan(s)):
			error(c"symbol index: name index and scan disagree")
	return found


int sym_address(char *s):
	int t = sym_lookup(s)
	if (t < 0):
		return 0
	return load_int(table + t + 2)


int sym_symtype(char *s):
	int t = sym_lookup(s)
	if (t < 0):
		return 0
	return load_int(table + t + 10)


int sym_type(char *s):
	int t = sym_lookup(s)
	if (t < 0):
		return 0
	return load_int(table + t + 6)


void sym_print_info(char *s):
	sym_info(sym_lookup(s))


# Registered index of the file currently being parsed, or -1 when no source
# file is active (e.g. runtime stubs declared by be_start before compilation).
int decl_file_index():
	if (filename == 0):
		return -1
	return debug_line_file_index()


int sym_decl_file_index(int t):
	return load_int(table + t + 66)


int sym_decl_line(int t):
	return load_int(table + t + 70)


int sym_decl_column(int t):
	return load_int(table + t + 74)


# Raw scope-type byte: 'D' defined global, 'U' undefined global, 'A'
# argument, 'L' local (see sym_get_value). import_warn_transitive
# (grammar/import_statement.w, --imports) uses this to skip locals and
# arguments -- their "declaration file" is not a module-provenance
# question the transitive-import check cares about.
int sym_decl_visibility(int t):
	return table[t + 1]


# Tracks the most recently *known-good* declaration location applied to
# any symbol, whether from sym_declare_global's own bookkeeping or an
# explicit sym_set_decl_location call right after it (e.g. enum values
# recording their own line/column). sym_define_global_at reads these to
# decide what a defining occurrence should move a symbol's location to.
int sym_last_declared_offset
int sym_last_declared_line
int sym_last_declared_column

void sym_set_decl_location(int t, int file_index, int line, int column):
	save_int(table + t + 66, file_index)
	save_int(table + t + 70, line)
	save_int(table + t + 74, column)
	sym_last_declared_offset = t
	sym_last_declared_line = line
	sym_last_declared_column = column


/*
s: zero terminated string to declare
type: variable type e.g. int, char, etc.
visibility: 'DUAL' Defined global, Undefined global, Argument, Local
value: memory address
symtype: 0:notype, 1:object, 2:func
*/
int pointer_indirection
void sym_declare(char *s, int type, int visibility, int value, int symtype):
	if (verbosity >= 1):
		print2(itoa(line_number))
		print_string0(c": sym_declare('", s)
		print_int0(c"', type=", type)
		print_char0(c", visibility='", visibility)
		print_hex0(c"', value=", value)
		print_int0(c", symtype=", symtype)
		println2(c")")

	# Discard anything a scope exit truncated, and make room, before the
	# blob and the index start moving: after this point nothing between
	# writing the record and recording its offset can allocate or fail.
	sym_index_sync()
	sym_index_reserve(sym_index_count + 1)
	int t = table_pos
	int i = 0
	while (s[i] != 0):
		if (table_size <= next_token(t)):
			int x = next_token(t) << 1
			table = realloc(table, table_size, x)
			table_size = x

		table[t] = s[i]
		i = i + 1
		t = t + 1

	table[t] = 0
	table[t + 1] = visibility
	save_int(table + t + 2, value)
	save_int(table + t + 6, type)
	save_int(table + t + 10, symtype)
	save_int(table + t + 14, 0) /* size: recycled malloc blocks are not zeroed */
	save_int(table + t + 18, pointer_indirection)
	save_int(table + t + 22, -1) /* parameter count unknown until a '(...)' is parsed */
	save_int(table + t + 78, -1) /* not variadic */
	save_int(table + t + 82, 0)  /* no GOT slot */
	save_int(table + t + 86, 0)  /* no parameter defaults */
	save_int(table + t + 130, -1) /* not a W variadic function */
	save_int(table + t + 134, 0)  /* not a generator */
	save_int(table + t + 138, 0)  /* not a gpu kernel */
	# Declaration location: token position of the name being declared
	save_int(table + t + 66, decl_file_index())
	save_int(table + t + 70, diag_token_line)
	save_int(table + t + 74, diag_token_column)
	# t is the record's NUL offset -- exactly what sym_lookup returns for
	# it. Index and table_pos move together.
	int p = sym_index_count
	save_int(sym_index_offsets + p * 4, t)
	# Read the name's current head before overwriting it: under the
	# invariant that is already the newest LIVE record of this name,
	# which is exactly what this record's chain link should be.
	int previous = -1
	if (sym_name_index == 0):
		sym_name_index = new map[char*, int]
	else if (s in sym_name_index):
		previous = sym_name_index[s]
	save_int(sym_index_prev + p * 4, previous)
	sym_name_index[s] = p
	sym_index_count = p + 1
	table_pos = next_token(t)

	# Record where locals and arguments live so the in-process debugger
	# (wdbg) can inspect them by name at runtime
	if ((visibility == 'L') || (visibility == 'A')):
		debug_local_note(s, value, visibility, type)


char *last_global_declaration
int sym_declare_global(char *s, int type, int symtype):
	strcpy(last_global_declaration, s)
	int current_symbol = sym_lookup(s)
	if (current_symbol < 0):
		sym_declare(s, type, 'U', code_offset, symtype)
		current_symbol = table_pos - symbol_data_size()
	else if (sym_decl_file_index(current_symbol) < 0):
		# Forward-referenced symbol (e.g. 'main' pre-declared by be_start):
		# this explicit declaration is the real source location
		sym_set_decl_location(current_symbol, decl_file_index(), diag_token_line, diag_token_column)

	sym_last_declared_offset = current_symbol
	sym_last_declared_line = diag_token_line
	sym_last_declared_column = diag_token_column
	return current_symbol


# Define a global symbol at an explicit virtual address v: patch every
# pending reference (the backpatch chain threaded through the mov-imm / addr
# slots in `code`) to v and mark the symbol defined. v is a code address for
# functions and read-only globals, or a data-segment address for mutable
# globals under the W^X split (Stage 3).
void sym_define_global_at(int current_symbol, int v):
	int i
	int j
	int t = current_symbol
	if (table[t + 1] != 'U'):
		diag_part(c"symbol redefined: '")
		diag_part(last_global_declaration)
		error(c"'")
	# A defining occurrence is more useful than a bare forward declaration
	# for navigation (w symbols --json / windex/wlsp go-to-definition): a
	# prototype like lib.w's 'int main(int argc, int argv);' would
	# otherwise permanently own the symbol's recorded location even after
	# the program's real 'main' is defined. Only apply when this call is
	# reached immediately after THIS symbol's own sym_declare_global (the
	# ordinary declare-then-maybe-define sequence every function/global
	# goes through), so an unrelated declaration parsed in between (or a
	# declaration path that bypasses sym_declare_global) leaves it alone.
	if (sym_last_declared_offset == current_symbol):
		sym_set_decl_location(current_symbol, decl_file_index(), sym_last_declared_line, sym_last_declared_column)
	i = load_int(table + t + 2) - code_offset
	while (i):
		j = be_addr_slot_read(i) - code_offset
		be_addr_slot_write(i, v)
		i = j

	table[t + 1] = 'D'
	save_int(table + t + 2, v)


void sym_define_global(int current_symbol):
	sym_define_global_at(current_symbol, code_offset + codepos)


int number_of_args

# Recorded value of the symbol at table offset t: a code/data virtual
# address on the native targets, a funcref table index for functions on
# wasm. Only meaningful once the symbol is defined (sym_decl_visibility
# reports 'D'); before that the cell holds the backpatch chain head.
int sym_value_at(int t):
	return load_int(table + t + 2)


# Number of declared parameters for the function symbol at table offset t,
# or -1 when unknown (e.g. asm runtime stubs without a parameter list).
int sym_num_args(int t):
	return load_int(table + t + 22)


# Number of fixed parameters of a variadic C import at table offset t, or
# -1 when the symbol is not variadic.
int sym_variadic_fixed_args(int t):
	return load_int(table + t + 78)


void sym_set_variadic(int t, int fixed_args):
	save_int(table + t + 78, fixed_args)


# Number of fixed parameters of a W variadic function ("T... rest") at
# table offset t, or -1 when the symbol is not a W variadic function.
# Distinct from sym_variadic_fixed_args: that flag marks variadic C
# imports, which use the inline C ABI call path instead of a slice.
int sym_w_variadic_fixed_args(int t):
	return load_int(table + t + 130)


void sym_set_w_variadic(int t, int fixed_args):
	save_int(table + t + 130, fixed_args)


# GOT slot vaddr of an extern import (the dynamic loader stores the
# resolved C function address there), or 0 for ordinary symbols.
int sym_got_vaddr(int t):
	return load_int(table + t + 82)


void sym_set_got_vaddr(int t, int vaddr):
	save_int(table + t + 82, vaddr)


# 1 when the symbol at table offset t is a generator function: calling it
# creates a generator object instead of running the body.
int sym_is_generator(int t):
	return load_int(table + t + 134)


void sym_set_generator(int t):
	save_int(table + t + 134, 1)


# 1 when the symbol at table offset t is a gpu kernel (grammar/kernel_decl.w):
# its body is PTX in the embedded module, its symbol value is 0 (never a
# host code address), and it can only be invoked through 'launch'.
int sym_is_kernel(int t):
	return load_int(table + t + 138)


void sym_set_kernel(int t):
	save_int(table + t + 138, 1)


# Parameter type slots per symbol; arguments past the limit are unchecked.
int sym_max_param_slots():
	return 10


# Parameter defaults: bit i of the mask is set when parameter i (0-based)
# carries a compile-time constant default, stored in the matching value
# slot. Only the first 10 parameters can have defaults (same limit as the
# declared-type slots).
int sym_param_has_default(int t, int i):
	if (i >= sym_max_param_slots()):
		return 0
	return (load_int(table + t + 86) >> i) & 1


int sym_param_default(int t, int i):
	return load_int(table + t + 90 + (i << 2))


void sym_set_param_default(int t, int i, int value):
	save_int(table + t + 86, load_int(table + t + 86) | (1 << i))
	save_int(table + t + 90 + (i << 2), value)


void sym_clear_param_defaults(int t):
	save_int(table + t + 86, 0)


# Declared type of the function's parameter at index i (0-based), or -1
# when unknown: no parameter list was parsed or the slot was not recorded.
int sym_param_type(int t, int i):
	int num_args = load_int(table + t + 22)
	if (num_args < 0):
		return -1
	if (i >= num_args):
		return -1
	if (i >= sym_max_param_slots()):
		return -1
	return load_int(table + t + 26 + (i << 2))


# REPL late binding (issue #114): when nonzero, sym_get_value reports every
# global function address it materializes -- hook(name, slot), slot being
# the buffer offset of the address cell be_addr_slot_write patches. The REPL
# points this at its call-site registry while an entry compiles, so
# redefining a function at the prompt can rewrite every already-compiled
# caller to the newest definition (repl/core.w). Zero for ordinary
# compiles: nothing is recorded and the emitted bytes are unchanged (the
# self-host verify fixpoints prove the flag-off path costs nothing).
int repl_call_site_hook


# Device-mode symbol reference (grammar/kernel_decl.w): compiled after
# this file, reached through the forward-reference chain.
int gpu_sym_get_value(char* s);


int sym_is_name_char(int c):
	if (('a' <= c) && (c <= 'z')):
		return 1
	if (('A' <= c) && (c <= 'Z')):
		return 1
	if (('0' <= c) && (c <= '9')):
		return 1
	return c == '_'


# Forward-call hint support: consume the rest of the current input file
# looking for what can only be a top-level definition (or prototype) of
# name -- the name as a whole word followed by '(' (spaces allowed
# between), on a line whose first character is a name character, i.e. at
# column 0. Function bodies are tab-indented, so a later CALL of the
# name can never match; a later 'type name(params)' definition does.
# Text behind a '#' on the line is ignored so a trailing comment cannot
# fake a definition. The scan eats the remaining input, which is fine on
# its only path: sym_not_found_error below, right before error() exits
# the process.
int sym_defined_later_in_file(char* name):
	int c = nextc
	int at_line_start = 1
	int line_can_define = 0
	int line_commented = 0
	int prev_is_name = 0
	int match_i = 0
	while (c != -1):
		if (at_line_start):
			# The scan starts mid-line (right after the failed name), so
			# the first "line" can never define: its true column 0 was
			# consumed long ago. sym_is_name_char is false for every
			# character that can directly follow an identifier token.
			line_can_define = sym_is_name_char(c)
			line_commented = 0
			prev_is_name = 0
			match_i = 0
			at_line_start = 0
		if (c == 10):
			at_line_start = 1
		else if (c == '#'):
			line_commented = 1
		else if (line_can_define && (line_commented == 0)):
			if ((match_i > 0) && (name[match_i] == 0)):
				# Whole name matched; only spaces may separate it from
				# the '(' of a parameter list. Anything else (another
				# name character, '[' of a generic definition, ...)
				# resets the search.
				if (c == '('):
					return 1
				if (c != ' '):
					match_i = 0
			else if ((c == name[match_i]) && ((match_i > 0) || (prev_is_name == 0))):
				match_i = match_i + 1
			else:
				match_i = 0
			prev_is_name = sym_is_name_char(c)
		c = getchar(file)
	return 0


# Shared cannot-find-symbol error for sym_get_value and the device-mode
# lookup (grammar/kernel_decl.w). The single-pass compiler registers a
# function only once its definition (or a C-style prototype,
# grammar/program.w's semicolon-terminated fix-up) has been parsed, so a
# call to a function defined further down the same file used to fail
# with a message indistinguishable from a typo; when the definition is
# visibly later in the file, say so and point at the prototype fix-up
# (docs/projects/ai_tooling.md). The lookahead scan consumes the rest of
# the input file, so it only runs when error() is about to exit the
# process -- under REPL recovery (error() longjmps back to a live
# prompt) the plain message is kept.
void sym_not_found_error(char* s):
	diag_part(c"Cannot find symbol: '")
	diag_part(token)
	if (repl_recovery == 0):
		if (sym_defined_later_in_file(s)):
			diag_part(c"': declared later in this file -- forward-declare it with a prototype ('type ")
			diag_part(s)
			error(c"(params);') before this point")
	error(c"'")


# Emits code leaving the symbol's ADDRESS in eax and returns its type index.
# Functions are the exception: their address is their value, so they return
# the "function" type (4), which promote() leaves untouched.
int sym_get_value(char *s):
	int t
	# Device (PTX) bodies resolve symbols against the GPU-side stack and
	# reject everything host-only (globals, function calls).
	if (target_isa == 3):
		return gpu_sym_get_value(s)
	if ((t = sym_lookup(s)) < 0):
		sym_not_found_error(s)
	# A kernel's body lives in the PTX module, not at a host address:
	# referencing its name as a value can only be a miscall.
	if (sym_is_kernel(t)):
		error(c"kernels cannot be called; use 'launch'")
	char scope_type = table[t + 1]
	int type = load_int(table + t + 6)
	int symtype = load_int(table + t + 10)

	# Only the GLOBAL branches consume the address slot: 'D' materializes
	# the symbol's address for the caller to use, 'U' additionally threads
	# its backpatch chain through the slot's cell. A local or argument
	# ('L'/'A') overwrites the accumulator with be_lea_acc_wstack below
	# without ever reading it, so emitting the slot on those paths was a
	# pure dead store -- 8.3% of the compiler's own emitted bytes on x86,
	# 7.2% on x64, 10.7% on arm64 (an adrp+add pair, 8 bytes) and 7.0% on
	# wasm (issue #110, docs/projects/optimization.md 1.1, implemented as
	# its 6.1 option 1: a conditional here, not a peephole pass).
	#
	# No data-flow analysis is needed, because the slot's every reader is
	# already reached only on the 'D'/'U' paths and addresses it as
	# codepos-4 with nothing emitted in between: the 'U' chain link below,
	# the REPL late-binding hook, be_code_ptr_sign (arm64 pac=full) and
	# wasm_call_target_note. Nothing indexes backwards past the removed
	# instruction on the 'L'/'A' path, and no already-emitted byte is
	# rewritten -- fewer bytes are emitted instead, so every codepos
	# bookmark (REPL rollback, wdbg line table) stays self-consistent.
	if ((scope_type == 'D') || (scope_type == 'U')):
		be_addr_slot_emit() /* mov $n,%eax (x86) / adrp+add pair (arm64) */
		be_addr_slot_write(codepos - 4, load_int(table + t + 2))

	int k = 0
	if (verbosity >= 2):
		print_error(s)
		print_error(c": ")
		sym_info(t)

	/* defined global */
	if (scope_type == 'D') {
		# Nothing needed since it directly uses the address from above
	}

	/* undefined global: link this site into the backpatch chain */
	else if (scope_type == 'U'):
		save_int(table + t + 2, codepos + code_offset - 4)

	/* local variable */
	else if (scope_type == 'L'):
		k = (stack_pos - load_int(table + t + 2) - 1) << word_size_log2

	/* argument */
	else if (scope_type == 'A'):
		k = (stack_pos + number_of_args - load_int(table + t + 2) + 1) << word_size_log2

	else:
		diag_part(c"Error getting symbol value for '")
		diag_part(s)
		diag_part(c"', table[t + 1]='")
		char* visibility = malloc(2)
		visibility[0] = table[t + 1]
		visibility[1] = 0
		diag_part(visibility)
		free(visibility)
		error(c"'")

	if ((scope_type == 'L') || (scope_type == 'A')):
		# Aggregates occupy several stack words; point at the lowest address
		# (last pushed word) so positive offsets stay inside the object.
		int words = type_stack_words(type)
		if (words > 1):
			k = k - ((words - 1) << word_size_log2)
		# lea (n)(%esp),%eax on x86; add x0,x28,#k on arm64
		be_lea_acc_wstack(k)

	if (symtype == 2):
		if ((scope_type == 'D') || (scope_type == 'U')):
			# REPL late binding: report the address cell just emitted
			# (still at codepos-4: the D/U paths emit nothing after
			# be_addr_slot_emit) so a later redefinition of this name
			# can repatch it. No-op outside the REPL (hook is 0).
			if (repl_call_site_hook != 0):
				repl_call_site_hook(s, codepos - 4)
			# pac=full: the address just materialized is now a value —
			# sign it (paciza; call_eax authenticates with blraaz).
			# Emitted here, after the 'U' backpatch-chain bookkeeping
			# above, so the chain's codepos-4 cell stays the add
			# instruction of the slot, not this extra word.
			be_code_ptr_sign()
			# wasm direct-call optimization: a DEFINED function's value is
			# its final table index (no chain threads through the slot just
			# emitted), so note it — an immediately following push or call
			# can then lower the call site to a direct `call`
			# (code_generator/wasm.w).
			if (target_isa == 2):
				if (scope_type == 'D'):
					wasm_call_target_note(load_int(table + t + 2))
			return 4 /* function */

	return type


void sym_define_declare_global_function(char* name):
	sym_define_global(sym_declare_global(name, 4, 2))


# Asm runtime stubs have no parsed parameter list, so their calls are
# normally unchecked (parameter count -1). A stub that loads a fixed
# number of caller stack slots (syscall, syscall7) records that arity
# here so a call with the wrong argument count is rejected at compile
# time instead of silently reading garbage slots. Only the count is
# known: the parameter type slots are cleared to -1 (unknown), so the
# argument types stay unchecked.
void sym_define_declare_global_function_arity(char* name, int num_args):
	int t = sym_declare_global(name, 4, 2)
	sym_define_global(t)
	save_int(table + t + 22, num_args)
	int slots = num_args
	if (slots > sym_max_param_slots()):
		slots = sym_max_param_slots()
	int i = 0
	while (i < slots):
		save_int(table + t + 26 + (i << 2), -1)
		i = i + 1


# 1 when the symbol at table offset t is an asm runtime stub: stubs are
# declared with the 'function' pseudo-type (4) as their value type, while
# ordinary functions record their declared return type there.
int sym_is_asm_stub(int t):
	return load_int(table + t + 6) == 4


void print_symbol_table(int t):
	print_error(c"printing symbol table since ")
	print_error(itoa(t))
	print_error(c":\x0a")
	int symbol = 0
	while (t <= table_pos - 1):
		char* sym = table + t
		t = t + strlen(table + t)

		print_error(itoa(symbol))
		print_error(c": ")
		print_error(sym)

		print_error(c" type(")
		put_error(table[t + 6] + '0')
		print_error(c") visibility(")
		put_error(table[t + 1])
		print_error(c") address(")
		print_error(hex(load_int(table + t + 2)))
		print_error(c") symtype(")
		put_error(table[t + 10] + '0')
		print_int0(c") size (", load_int(table + t + 14))
		print_int0(c") pointer (", load_int(table + t + 18))
		print_error(c")\x0a")

		t = next_token(t)
		symbol = symbol + 1


int emit_string_table():
	if (verbosity >= 1):
		print_error(c"dumping string table\x0a")
	int t = 0
	int n = 0
	int count = 0
	emit_int8(0) /* index 0 must be the empty string */
	while (t <= table_pos - 1):
		char* sym = table + t
		n = strlen(table + t)
		t = t + n
		emit(n + 1, sym)
		t = next_token(t)
		count = count + 1

	return count


int emit_symbol_table():
	if (verbosity >= 1):
		print_error(c"dumping symbol table\x0a")
	int t = 0
	int n = 0
	int symbol = 1 /* string table starts with a null byte */
	int count = 1
	elf_emit_sym_table_entry(0, 0, 0, 0, 0, 0) /* mandatory null symbol */
	while (t <= table_pos - 1):
		char* sym = table + t
		n = strlen(table + t)
		t = t + n

		int visibility = table[t + 1]
		int binding = 1  /* global by default */
		if (visibility != 'D'):
			binding = 0
		int symtype = table[t + 10]
		int address = load_int(table + t + 2)
		int size = load_int(table + t + 14)
		elf_emit_sym_table_entry(symbol, address, size, binding, symtype, 1) /* shndx 1 = .text */

		t = next_token(t)
		symbol = symbol + n + 1
		count = count + 1

	return count


void emit_section_name(char* s, int header_addr, int strings_addr):
	save_int(code + header_addr, codepos - strings_addr)
	emit_string(s)


# Set a section header's file offset and size, and zero the symtab-oriented
# defaults that only apply to .symtab.
void section_set_range(int header, int addr, int length):
	elf_section_set_offset(header, addr)
	elf_section_set_size(header, length)
	elf_section_set_link(header, 0)
	elf_section_set_entsize(header, 0)


void emit_debugging_symbols(int word_size):
	int text_end = codepos

	# Store start of section header
	int header_addr = codepos

	# Save section header address + number of sections
	# Section order: null, text, debug_info, debug_abbrev, debug_line, strings, symtab
	elf_save_section_info(word_size, header_addr, 7, 5)

	# Mandatory null section 0
	emit_zeros(elf_section_header_length())

	# .text covers the whole loaded image (headers + code + data)
	int text_section_header = codepos
	elf_emit_section_header(1)
	elf_section_set_flags(text_section_header, 6) /* alloc + exec */
	elf_section_set_addr(text_section_header, code_offset)
	elf_section_set_offset(text_section_header, 0)
	elf_section_set_size(text_section_header, text_end)
	elf_section_set_link(text_section_header, 0)
	elf_section_set_entsize(text_section_header, 0)

	# Emit debug info section header
	int debug_info_section_header = codepos
	elf_emit_section_header(1)

	int debug_abbrev_section_header = codepos
	elf_emit_section_header(1)

	int debug_line_section_header = codepos
	elf_emit_section_header(1)

	# Emit string section header
	int string_section_header = codepos
	elf_emit_section_header(3)

	# Emit symbol section header
	int symbol_section_header = codepos
	elf_emit_section_header(2)

	# Emit strings
	int strings_addr = codepos
	int string_count = emit_string_table()

	# Emit section header name strings
	emit_section_name(c"strings", string_section_header, strings_addr)
	emit_section_name(c".symtab", symbol_section_header, strings_addr)
	emit_section_name(c".text", text_section_header, strings_addr)
	emit_section_name(c".debug_info", debug_info_section_header, strings_addr)
	emit_section_name(c".debug_abbrev", debug_abbrev_section_header, strings_addr)
	emit_section_name(c".debug_line", debug_line_section_header, strings_addr)

	# Store string strings_addr + length
	int length = codepos - strings_addr
	elf_section_set_addr(string_section_header, strings_addr)
	elf_section_set_offset(string_section_header, strings_addr)
	elf_section_set_size(string_section_header, length)
	elf_section_set_link(string_section_header, 0)
	elf_section_set_info(string_section_header, 0)
	elf_section_set_entsize(string_section_header, 0)

	# Emit symbols
	int sym_table_addr = codepos
	int symbol_count = emit_symbol_table()
	int sym_table_length = codepos - sym_table_addr
	elf_section_set_addr(symbol_section_header, sym_table_addr)
	elf_section_set_offset(symbol_section_header, sym_table_addr)
	elf_section_set_size(symbol_section_header, sym_table_length)
	elf_section_set_link(symbol_section_header, 5) /* link: the strings section */
	elf_section_set_info(symbol_section_header, 0) /* info: no leading locals */

	# Emit the DWARF payloads
	int debug_info_addr = codepos
	debug_info_emit(text_end)
	section_set_range(debug_info_section_header, debug_info_addr, codepos - debug_info_addr)

	int debug_abbrev_addr = codepos
	debug_abbrev_emit()
	section_set_range(debug_abbrev_section_header, debug_abbrev_addr, codepos - debug_abbrev_addr)

	int debug_line_addr = codepos
	debug_line_emit()
	section_set_range(debug_line_section_header, debug_line_addr, codepos - debug_line_addr)

	emit_int8(0) /* placeholder so reader doesn't read beyond the end of the file */

