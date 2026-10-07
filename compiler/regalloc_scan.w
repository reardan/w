/*
Function-scoped register promotion: the pre-scan and the promotion
decision (docs/projects/register_allocation_pgo.md §2.2, unit R2).

The compiler is single-pass with no tree, so by the time a local is
declared nothing is known about how the rest of the body uses it. This
module looks ahead instead: regalloc_function_scan() runs once per
function body, right before its prologue, reads the body's bytes from
the source fd through lib/lib.w's buffered getchar (NOT the tokenizer:
no token, line, warning or diagnostic state moves, and the fd is seeked
back to where the tokenizer left it), and ranks the body's word-sized
locals by loop-weighted use count. The top k (4 on x64: r12-r15; 2 on
x86: esi/edi) are assigned a callee-saved register; the prologue
(code_generator/arm64.w -> x86.w's regalloc_prologue_emit) pushes those
registers, the epilogue pops them, and regalloc_declare() below hands
the register to the local's symbol record when sym_declare sees its
declaration.

The scanner is a byte-level lexer that agrees with compiler/tokenizer.w
on literal and comment boundaries but keeps no other state. It is
conservative by construction: anything it does not understand makes a
name a non-candidate (or, for whole-function hazards, makes the
function promote nothing), and the emission side is fail-closed
(code_emitter.w's guard, x86.w's slot assertion), so a scan mistake is a
compile-time internal error rather than a miscompile. The rules:

- a candidate is a name with exactly one recognised declaration in the
  body ('T name', 'T* name', 'T[..] name', 'name :=' -- any identifier,
  '*' or ']' before the name counts as a type, which over-counts
  declarations and never under-counts them), that is never address-taken
  ('&name'), subscripted, called, field-accessed or compound-assigned
  ('+=' and friends, '++'/'--'); a 'for' header's loop variable is a
  declaration like any other (R2b: the loop writes it through the
  register path);
- the declared type must be a plain 'int' or a pointer (checked at
  sym_declare: narrow integers, floats, aggregates, strings, containers
  and const-qualified locals never promote);
- uses are weighted 8^depth by 'while'/'for' nesting (indentation-based,
  like the parser's block structure); only names used inside a loop are
  ranked, and a body without a loop is not scanned past the first pass;
- a body containing raw_asm, setjmp/longjmp, yield, gpu/launch/kernel
  constructs, or an f"..." template string promotes nothing; variadic
  functions (the caller decides) and generator bodies (no prologue)
  promote nothing. goto/labels and defer are allowed: promotion is
  function-scoped, so every exit edge and every reparse sees the register.
*/
import lib.lib
import compiler.tokenizer
import compiler.type_table
import compiler.symbol_table


# --- candidate table (per scanned function) -------------------------------
list[char*] rs_names      # cloned identifier text
list[int] rs_decls        # recognised declarations
list[int] rs_uses         # loop-weighted use count
list[int] rs_excluded     # 1 once a hazardous use was seen
list[int] rs_reg          # register assigned by the ranking, 0 none
list[int] rs_taken        # 1 once a declaration took the register
list[int] rs_hash         # rs_hash_str(name), chained through rs_chain
list[int] rs_chain        # next index in the bucket, -1 ends the chain
int[256] rs_buckets       # hash & 255 -> index + 1, 0 empty
int rs_count

# Promoted symbol records of the current function (table offsets), for
# the stack-slot assertion, and whether each one's storage word has been
# pushed yet: a typed declaration is recorded before its initializer
# runs, and until the storage push its slot number is still the depth
# the initializer's own temporaries (a call's parked callee address,
# say) legitimately occupy.
list[int] regalloc_promoted_syms
list[int] regalloc_promoted_live
# ... and their names (cloned): a record offset alone cannot tell a live
# record from a later one written at the same offset after a scope
# exit truncated the table, so liveness is "sym_probe(name) still
# resolves to this offset".
list[char*] regalloc_promoted_names

# --stats: scanned bodies and promoted locals, printed by 'w --stats'
int regalloc_scanned_functions
int regalloc_promoted_locals

# Scanner state
int rs_c              # current byte, -1 at end of file
int rs_mode           # 0: probe (find a loop or a hazard), 1: full
int rs_abort          # a whole-function hazard was seen
int rs_has_loop
int rs_depth          # brace depth
int rs_tabs           # leading tabs of the current line
int rs_line_start     # 1 until the first token of a line is seen
int rs_start_tabs     # tab level of the body's first line, -1 until seen
int rs_same_line      # the body is the rest of the signature line
int rs_done           # the body ended
int rs_prev_kind      # 0 operator, 1 identifier, 2 operand end, 3 '*', 4 ']', 5 unary '&', 6 '.'
int rs_at_start       # the token being read is its line's first
int rs_prev_keyword   # the previous identifier was a keyword
int rs_for_header     # inside 'for ... in'
int rs_ident_size
char* rs_ident        # identifier text buffer
int rs_ident_len
int rs_ident_hash     # rs_hash_str(rs_ident), accumulated while reading
int[64] rs_loop_tabs
int rs_loop_count


void rs_tables_ensure():
	if (rs_names == 0):
		rs_names = new list[char*]
		rs_decls = new list[int]
		rs_uses = new list[int]
		rs_excluded = new list[int]
		rs_reg = new list[int]
		rs_taken = new list[int]
		rs_hash = new list[int]
		rs_chain = new list[int]
		regalloc_promoted_syms = new list[int]
		regalloc_promoted_live = new list[int]
		regalloc_promoted_names = new list[char*]
	if (rs_ident == 0):
		rs_ident_size = 64
		rs_ident = malloc(rs_ident_size)


# Drop the candidate table (names are cloned per function).
void rs_tables_clear():
	if (rs_names == 0): return;
	for i in range(rs_count): free(rs_names[i])
	rs_names.clear()
	rs_decls.clear()
	rs_uses.clear()
	rs_excluded.clear()
	rs_reg.clear()
	rs_taken.clear()
	rs_hash.clear()
	rs_chain.clear()
	if (rs_count > 0):
		for i in range(256): rs_buckets[i] = 0
	rs_count = 0


# Everything the current function's scan and prologue set, back to
# "promote nothing": the epilogue, and every rollback that unwinds a
# function body mid-way (REPL error recovery).
void regalloc_function_end():
	rs_tables_ensure()
	rs_tables_clear()
	regalloc_promoted_syms.clear()
	regalloc_promoted_live.clear()
	for i in range(regalloc_promoted_names.length): free(regalloc_promoted_names[i])
	regalloc_promoted_names.clear()
	regalloc_promoted_count = 0
	regalloc_active = 0
	regalloc_saved_mask = 0
	regalloc_saved_count = 0
	regalloc_pending_mask = 0
	regalloc_function = -1
	reg_lvalue_end = 0


void regalloc_reset():
	rs_tables_ensure()
	regalloc_function_end()


# --- the fail-closed diagnostics -----------------------------------------
# A grammar path emitted while the register lvalue note was current: it
# treated the accumulator as the local's address. Named internal errors,
# since the scan is meant to exclude every such use.
void regalloc_guard_fail():
	reg_lvalue_end = 0
	char* name = c"?"
	if ((reg_lvalue_sym >= 0) && (reg_lvalue_sym < table_pos)): name = sym_record_name(reg_lvalue_sym)
	if (name == 0): name = c"?"
	error3(c"internal error: register-resident local '", name, c"' used by an unhandled path (compile with --no-regs and report this)")


# The slot-addressing grammar helpers (grammar/stack_slot.w's load_slot,
# the for-loop variable stores) are about to read or write the stack
# word recorded as 'slot' in a symbol record (the stack_pos before its
# push): fail when that word belongs to a live promoted local, whose
# value is in a register and whose word is never updated.
void regalloc_slot_assert(int slot):
	if (regalloc_promoted_count == 0): return;
	if (slot < 0): return;
	for i in range(regalloc_promoted_syms.length):
		int t = regalloc_promoted_syms[i]
		if ((t < table_pos) && regalloc_promoted_live[i]):
			if ((load_int(table + t + 146) != 0) && (load_int(table + t + 2) == slot)):
				char* name = regalloc_promoted_names[i]
				if (sym_probe(name) == t):
					error3(c"internal error: stack slot of register-resident local '", name, c"' addressed (compile with --no-regs and report this)")


# The register of the live promoted local whose storage word is stack
# slot 'slot' (the record's anchor, i.e. for_var - 1 for a loop
# variable), 0 when that word belongs to no promoted local. The for
# loops (grammar/for_statement.w, code_generator/loop_ast.w) address
# their loop variable by slot, not by name, so they ask here before
# writing it.
int regalloc_slot_register(int slot):
	if (regalloc_promoted_count == 0): return 0
	if (slot < 0): return 0
	for i in range(regalloc_promoted_syms.length):
		int t = regalloc_promoted_syms[i]
		if ((t < table_pos) && regalloc_promoted_live[i]):
			if ((load_int(table + t + 146) != 0) && (load_int(table + t + 2) == slot)):
				if (sym_probe(regalloc_promoted_names[i]) == t): return load_int(table + t + 146)
	return 0


# --- the byte lexer ---------------------------------------------------------
# The scanner walks getchar's own 8KB window for the fd directly
# (rs_p..rs_end, lib/lib.w's buffer); getchar() refills it on the slow
# path, with getchar_pos synced first so the refill starts at the right
# byte. rs_sync() re-derives the pointers after every seek or refill.
char* rs_p
char* rs_end

void rs_sync():
	rs_p = 0
	rs_end = 0
	if ((file < 0) || (file >= GETCHAR_MAX_FD)): return;
	char* buffer = cast(char*, getchar_buf_addr[file])
	if (buffer == 0): return;
	rs_p = &buffer[getchar_pos[file]]
	rs_end = &buffer[getchar_limit[file]]

void rs_next():
	if (rs_p < rs_end):
		rs_c = *rs_p & 255
		rs_p = rs_p + 1
		return;
	if (rs_p != 0): getchar_pos[file] = getchar_limit[file]
	rs_c = getchar(file)
	rs_sync()


# Leading whitespace of a new line: count its tabs (the tokenizer's
# tab_level counts every tab before a token; leading ones are the block
# structure).
void rs_newline():
	rs_next()
	rs_tabs = 0
	while ((rs_c == 9) || (rs_c == ' ') || (rs_c == 13)):
		if (rs_c == 9): rs_tabs = rs_tabs + 1
		rs_next()
	rs_line_start = 1
	rs_for_header = 0


void rs_skip_line_comment():
	while ((rs_c != 10) && (rs_c != -1)): rs_next()


void rs_skip_block_comment():
	# rs_c is the '*' after '/'
	rs_next()
	while (rs_c != -1):
		if (rs_c == '*'):
			rs_next()
			if (rs_c == '/'):
				rs_next()
				return;
		else: rs_next()


# A quoted literal; rs_c is the opening quote.
void rs_skip_quoted(int quote):
	rs_next()
	while ((rs_c != quote) && (rs_c != -1)):
		if (rs_c == 92): rs_next()
		if (rs_c != -1): rs_next()
	if (rs_c == quote): rs_next()


void rs_ident_put(int c):
	if (rs_ident_len + 2 > rs_ident_size):
		int x = rs_ident_size << 1
		rs_ident = realloc(rs_ident, rs_ident_size, x)
		rs_ident_size = x
	rs_ident[rs_ident_len] = c
	rs_ident_len = rs_ident_len + 1


void rs_take_ident():
	rs_ident_len = 0
	int h = 0
	while (rs_c != -1):
		int c = rs_c
		if ((('a' <= c) && (c <= 'z')) || (('A' <= c) && (c <= 'Z')) || (('0' <= c) && (c <= '9')) || (c == '_') || ((c >= 128) && is_ident_part_byte(c))):
			rs_ident_put(c)
			h = (h * 31) + c
			rs_next()
		else: break
	rs_ident[rs_ident_len] = 0
	rs_ident_hash = h


# Reserved words that may precede an identifier without being a type.
# Only true keywords belong here: a user type name wrongly listed would
# hide a real declaration, while a keyword missing from the list only
# over-counts declarations (conservative).
int rs_is_keyword(char* s):
	int c0 = s[0]
	if (c0 == 'r'): return strcmp(s, c"return") == 0
	if (c0 == 'y'): return strcmp(s, c"yield") == 0
	if (c0 == 'd'): return (strcmp(s, c"defer") == 0) || (strcmp(s, c"default") == 0) || (strcmp(s, c"debugger") == 0)
	if (c0 == 'g'): return strcmp(s, c"goto") == 0
	if (c0 == 'n'): return strcmp(s, c"new") == 0
	if (c0 == 'i'): return (strcmp(s, c"in") == 0) || (strcmp(s, c"if") == 0) || (strcmp(s, c"import") == 0)
	if (c0 == 'a'): return strcmp(s, c"as") == 0
	if (c0 == 'e'): return (strcmp(s, c"else") == 0) || (strcmp(s, c"elif") == 0)
	if (c0 == 'w'): return strcmp(s, c"while") == 0
	if (c0 == 'f'): return strcmp(s, c"for") == 0
	if (c0 == 's'): return (strcmp(s, c"switch") == 0) || (strcmp(s, c"sizeof") == 0)
	if (c0 == 'c'): return (strcmp(s, c"case") == 0) || (strcmp(s, c"continue") == 0) || (strcmp(s, c"cast") == 0) || (strcmp(s, c"const") == 0)
	if (c0 == 'b'): return strcmp(s, c"break") == 0
	if (c0 == 'p'): return strcmp(s, c"pass") == 0
	if (c0 == 'l'): return strcmp(s, c"launch") == 0
	return 0


# Whole-function hazards (§2.4): any register may be live in an asm
# block, setjmp/longjmp callers keep their locals in memory, generators
# and gpu bodies have their own stacks, and f-strings re-enter the
# tokenizer mid-token.
int rs_is_hazard(char* s):
	int c0 = s[0]
	if (c0 == 'r'): return (strcmp(s, c"raw_asm") == 0) || (strcmp(s, c"repl_setjmp") == 0) || (strcmp(s, c"repl_longjmp") == 0)
	if (c0 == 's'): return strcmp(s, c"setjmp") == 0
	if (c0 == 'l'): return (strcmp(s, c"longjmp") == 0) || (strcmp(s, c"launch") == 0)
	if (c0 == 'y'): return strcmp(s, c"yield") == 0
	if (c0 == 'g'): return strcmp(s, c"gpu") == 0
	if (c0 == 'k'): return strcmp(s, c"kernel") == 0
	return 0


int rs_weight():
	int depth = rs_loop_count
	if (depth > 8): depth = 8
	return 1 << (3 * depth)


# The candidate index: a 256-bucket chained table on a cheap string
# hash. One lookup per identifier in every scanned body makes this the
# scan's hot spot, and a siphash map here costs more than the lexing.
int rs_hash_str(char* s):
	int h = 0
	int i = 0
	while (s[i] != 0):
		h = (h * 31) + (s[i] & 255)
		i = i + 1
	return h


int rs_lookup_hashed(char* name, int h):
	if (rs_count == 0): return -1
	int i = rs_buckets[h & 255] - 1
	while (i >= 0):
		if (rs_hash[i] == h):
			if (strcmp(rs_names[i], name) == 0): return i
		i = rs_chain[i]
	return -1


int rs_lookup(char* name):
	return rs_lookup_hashed(name, rs_hash_str(name))


int rs_intern(char* name, int h):
	int i = rs_lookup_hashed(name, h)
	if (i >= 0): return i
	i = rs_count
	rs_names.push(strclone(name))
	rs_decls.push(0)
	rs_uses.push(0)
	rs_excluded.push(0)
	rs_reg.push(0)
	rs_taken.push(0)
	rs_hash.push(h)
	rs_chain.push(rs_buckets[h & 255] - 1)
	rs_buckets[h & 255] = i + 1
	rs_count = rs_count + 1
	return i


# Skip blanks inside a line (never a newline).
void rs_skip_blanks():
	while ((rs_c == ' ') || (rs_c == 9) || (rs_c == 13)): rs_next()


int rs_is_op_char(int c):
	return (c == '+') || (c == '-') || (c == '*') || (c == '/') || (c == '%') || (c == '^') || (c == '&') || (c == '|') || (c == '<') || (c == '>') || (c == '=') || (c == '!')


# An operator run after an identifier (the identifier's index is i, -1
# when it is not tracked): classify the run as a compound assignment or
# increment (both exclude the name: R2 promotes plain '=' only), a plain
# '=' write, or an ordinary operator. The run is consumed.
void rs_after_ident_operator(int i, int type_context):
	int n = 0
	int first = rs_c
	int second = 0
	int last = 0
	while (rs_is_op_char(rs_c)):
		if (n == 1): second = rs_c
		last = rs_c
		n = n + 1
		rs_next()
	int use = 1
	if (n == 1):
		if (first == '='):
			# plain assignment, or a declaration with an initializer
			if (type_context): use = 0
			else: use = 2
		else: use = 1
	else:
		if (((first == '+') && (second == '+') && (n == 2)) || ((first == '-') && (second == '-') && (n == 2))): use = 3
		else if ((first == '=') && (second != '=')):
			# 'x =-1', 'x =*p': an assignment whose right side starts
			# with a unary operator
			if (type_context): use = 0
			else: use = 2
		else if (last == '='):
			# '==', '<=', '>=', '!=' compare; every other '...=' run assigns
			if ((n == 2) && ((first == '=') || (first == '<') || (first == '>') || (first == '!'))): use = 1
			else: use = 3
	if (i >= 0):
		if (use == 0): rs_decls[i] = rs_decls[i] + 1
		else if (use == 3): rs_excluded[i] = 1
		else: rs_uses[i] = rs_uses[i] + rs_weight()
	# '&' alone after an operand is the binary operator
	rs_prev_kind = 0
	if ((n == 1) && (first == '*')): rs_prev_kind = 3


# An identifier (not a field name) has been read into rs_ident.
void rs_identifier():
	char* name = rs_ident
	int type_context = (rs_prev_kind == 3) || (rs_prev_kind == 4) || ((rs_prev_kind == 1) && (rs_prev_keyword == 0))
	int address_taken = rs_prev_kind == 5
	int keyword = rs_is_keyword(name)
	if (rs_is_hazard(name)):
		rs_abort = 1
		return;
	if (keyword):
		if (rs_at_start):
			if ((strcmp(name, c"while") == 0) || (strcmp(name, c"for") == 0)):
				rs_has_loop = 1
				if (rs_loop_count < 64):
					rs_loop_tabs[rs_loop_count] = rs_tabs
					rs_loop_count = rs_loop_count + 1
				if (name[0] == 'f'): rs_for_header = 1
		if (strcmp(name, c"in") == 0): rs_for_header = 0
		rs_prev_kind = 1
		rs_prev_keyword = 1
		return;
	# A string prefix: c"..." / s"..." are literals, f"..." re-enters
	# the tokenizer for its embedded expressions
	if ((rs_ident_len == 1) && (rs_c == '"')):
		if (name[0] == 'f'): rs_abort = 1
		else: rs_skip_quoted('"')
		rs_prev_kind = 2
		return;
	int i = -1
	if (rs_mode == 1):
		i = rs_intern(name, rs_ident_hash)
		if (address_taken): rs_excluded[i] = 1
	rs_prev_kind = 1
	rs_prev_keyword = 0
	rs_skip_blanks()
	int c = rs_c
	if (rs_for_header):
		# 'for [T] name[, [T] name] in': every identifier of the header
		# is a declaration (the type names over-count, conservatively);
		# the loop stores the variable itself through the register path
		# (R2b), so it stays a candidate.
		if (i >= 0): rs_decls[i] = rs_decls[i] + 1
		return;
	if ((c == '(') || (c == '[') || (c == '.')):
		if (i >= 0): rs_excluded[i] = 1
		return;
	if (c == ':'):
		rs_next()
		rs_prev_kind = 0
		if (rs_c == '='):
			rs_next()
			if (i >= 0): rs_decls[i] = rs_decls[i] + 1
		return;
	if (rs_is_op_char(c)):
		rs_after_ident_operator(i, type_context)
		return;
	# end of line, ',', ')', ']', ';', '}' ...: a read, or 'T name' alone
	if (i >= 0):
		if (type_context && ((c == 10) || (c == ';') || (c == -1) || (c == '#'))): rs_decls[i] = rs_decls[i] + 1
		else: rs_uses[i] = rs_uses[i] + rs_weight()


# One token at the start of a line: pop the loops the line left, and end
# the body when the line is outdented past the body's first line.
void rs_line_token():
	rs_line_start = 0
	if (rs_same_line): return;
	if (rs_start_tabs < 0):
		rs_start_tabs = rs_tabs
		return;
	if (rs_depth == 0):
		if (rs_tabs < rs_start_tabs):
			rs_done = 1
			return;
	while ((rs_loop_count > 0) && (rs_loop_tabs[rs_loop_count - 1] >= rs_tabs)):
		rs_loop_count = rs_loop_count - 1


# Scan the body from the byte after the current token ('{' or ':'),
# which rs_c holds. mode 0 stops at the first loop keyword or hazard.
void rs_scan_body(int brace_body):
	rs_abort = 0
	rs_has_loop = 0
	rs_depth = 0
	if (brace_body): rs_depth = 1
	rs_tabs = 0
	rs_line_start = 0
	rs_start_tabs = -1
	rs_same_line = 0
	rs_done = 0
	rs_prev_kind = 0
	rs_prev_keyword = 0
	rs_for_header = 0
	rs_loop_count = 0
	int first = 1
	while ((rs_done == 0) && (rs_abort == 0) && (rs_c != -1)):
		if ((rs_mode == 0) && rs_has_loop): return;
		if (rs_c == 10):
			if (rs_same_line && (rs_depth == 0)): return;
			rs_newline()
			rs_prev_kind = 0
			continue
		if ((rs_c == ' ') || (rs_c == 9) || (rs_c == 13)):
			rs_next()
			continue
		if (rs_c == '#'):
			rs_skip_line_comment()
			continue
		if (rs_c == '/'):
			rs_next()
			if (rs_c == '*'):
				rs_skip_block_comment()
				continue
			# a '/' operator (also '/=': an identifier before it already
			# consumed the run, so this one follows a non-identifier)
			rs_prev_kind = 0
			continue
		# a token starts here
		if (first):
			first = 0
			# ':' with the body on the same line: one statement to EOL
			if ((brace_body == 0) && (rs_line_start == 0)): rs_same_line = 1
		rs_at_start = rs_line_start
		if (rs_line_start): rs_line_token()
		if (rs_done): return;
		int c = rs_c
		if ((('a' <= c) && (c <= 'z')) || (('A' <= c) && (c <= 'Z')) || (c == '_') || ((c >= 128) && is_ident_start_byte(c))):
			# a field name after '.' is not a variable
			int field = rs_prev_kind == 6
			rs_take_ident()
			if (field): rs_prev_kind = 2
			else: rs_identifier()
			continue
		if (('0' <= c) && (c <= '9')):
			while ((rs_c != -1) && (is_ident_part_byte(rs_c) || (rs_c == '.'))): rs_next()
			rs_prev_kind = 2
			continue
		if ((c == '"') || (c == 39)):
			rs_skip_quoted(c)
			rs_prev_kind = 2
			continue
		if (c == '{'):
			rs_depth = rs_depth + 1
			rs_next()
			rs_prev_kind = 0
			continue
		if (c == '}'):
			rs_depth = rs_depth - 1
			rs_next()
			rs_prev_kind = 2
			if (brace_body && (rs_depth == 0)): rs_done = 1
			continue
		if (c == ')'):
			rs_next()
			rs_prev_kind = 2
			continue
		if (c == ']'):
			rs_next()
			rs_prev_kind = 4
			continue
		if (c == '.'):
			rs_next()
			rs_prev_kind = 6
			continue
		if (rs_is_op_char(c)):
			int n = 0
			int firstc = c
			int before = rs_prev_kind
			while (rs_is_op_char(rs_c)):
				n = n + 1
				rs_next()
			rs_prev_kind = 0
			if ((n == 1) && (firstc == '&')):
				# '&' not after an operand: address-of
				if (before != 2): rs_prev_kind = 5
				# '&(' parenthesised address-of: cannot tell the name
				rs_skip_blanks()
				if ((rs_prev_kind == 5) && (rs_c == '(')): rs_abort = 1
			else if ((n == 1) && (firstc == '*')):
				# 'T* name' after a type; '*p' at an operator is a deref
				if ((before == 1) || (before == 3)): rs_prev_kind = 3
			continue
		# '(' '[' ',' ';' ':' '?' '@' and anything else
		rs_next()
		rs_prev_kind = 0


# Rank the candidates and assign registers; returns the mask to push.
int rs_assign_registers():
	int budget = 2
	int first_reg = 6   # esi, edi
	if (word_size == 8):
		budget = 4
		first_reg = 12  # r12-r15
	int mask = 0
	int assigned = 0
	while (assigned < budget):
		int best = -1
		int best_uses = 7   # at least one use inside a loop (weight 8)
		for i in range(rs_count):
			if ((rs_reg[i] == 0) && (rs_decls[i] == 1) && (rs_excluded[i] == 0)):
				if (rs_uses[i] > best_uses):
					best = i
					best_uses = rs_uses[i]
		if (best < 0): return mask
		int r = first_reg + assigned
		rs_reg[best] = r
		mask = mask | (1 << r)
		assigned = assigned + 1
	return mask


# Called by function_definition (grammar/program.w) with the current
# token at the body's '{' or ':', right before the prologue. symbol is
# the function's record; variadic functions promote nothing.
void regalloc_function_scan(int symbol, int is_variadic):
	rs_tables_ensure()
	regalloc_function_end()
	if (regalloc_disabled): return;
	if ((target_isa != 0) || (target_os != 0)): return;
	if (is_variadic): return;
	if (file < 0): return;
	if (token[0] == 0): return;
	int brace_body = token[0] == '{'
	if ((brace_body == 0) && (token[0] != ':')): return;
	# The byte after the current token is the tokenizer's lookahead
	# nextc (file offset byte_offset - 1); the scan starts from it and
	# reads on from byte_offset, the fd's position.
	int body_offset = byte_offset
	getchar_seek(file, body_offset)
	rs_sync()
	rs_c = nextc
	rs_mode = 0
	rs_scan_body(brace_body)
	int mask = 0
	if (rs_has_loop && (rs_abort == 0)):
		getchar_seek(file, body_offset)
		rs_sync()
		rs_c = nextc
		rs_mode = 1
		rs_scan_body(brace_body)
		regalloc_scanned_functions = regalloc_scanned_functions + 1
		if (rs_abort == 0): mask = rs_assign_registers()
	getchar_seek(file, byte_offset)
	if (mask == 0):
		rs_tables_clear()
		return;
	regalloc_pending_mask = mask
	regalloc_function = symbol


# Is a declared type one a register can hold: the word-sized 'int', or
# a pointer (not an array, not const).
int regalloc_type_ok(int type):
	if (type_is_const(type)): return 0
	if (type_is_array(type)): return 0
	if (type_get_pointer_level(type) > 0): return 1
	if (type_stack_words(type) != 1): return 0
	if (type_get_size(type) != word_size): return 0
	return type_canonical(type) == type_lookup(c"int")


# sym_declare's hook for a new local 'name' (record t, declared type):
# returns the register it lives in, 0 for the stack. The candidate's
# register goes to its first declaration in the function; anything the
# scan did not see as that one declaration (a shadow in a sibling
# block, a loop variable) keeps the stack.
int regalloc_declare(int t, char* name, int type):
	if (regalloc_active == 0): return 0
	if (target_isa != 0): return 0
	int i = rs_lookup(name)
	if (i < 0): return 0
	if ((rs_reg[i] == 0) || rs_taken[i]): return 0
	if (regalloc_type_ok(type) == 0): return 0
	rs_taken[i] = 1
	save_int(table + t + 146, rs_reg[i])
	regalloc_promoted_syms.push(t)
	regalloc_promoted_live.push(0)
	regalloc_promoted_names.push(strclone(name))
	regalloc_promoted_count = regalloc_promoted_count + 1
	regalloc_promoted_locals = regalloc_promoted_locals + 1
	return rs_reg[i]


# The register a declared local lives in, 0 for the stack.
int regalloc_sym_register(int t):
	if (t < 0): return 0
	return load_int(table + t + 146)


# A declaration's storage has just been pushed with the initial value in
# the accumulator: a promoted local also gets it in its register.
void regalloc_store_declared(int t):
	int reg = regalloc_sym_register(t)
	if (reg == 0): return;
	mov_reg_eax(reg)
	for i in range(regalloc_promoted_syms.length):
		if (regalloc_promoted_syms[i] == t): regalloc_promoted_live[i] = 1


void regalloc_stats_dump():
	print_int0(c"regalloc: bodies scanned: ", regalloc_scanned_functions)
	print_int0(c" locals promoted: ", regalloc_promoted_locals)
	print_error(c"\x0a")
