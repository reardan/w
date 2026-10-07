/*
Function-scoped register promotion: the pre-scan and the promotion
decision (docs/projects/register_allocation_pgo.md §2.2, unit R2).

The compiler is single-pass with no tree, so by the time a local is
declared nothing is known about how the rest of the body uses it. This
module looks ahead instead: regalloc_function_scan() runs once per
function body, right before its prologue, reads the body's bytes from
its own image of the source file (NOT through the tokenizer, and
without moving getchar's window: no token, line, warning, diagnostic
or buffer state moves, and the fd stays where getchar left it), and ranks
the body's word-sized
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
  body ('T name', 'T* name', 'T[..] name', 'name :=' -- any identifier
  or ']' before the name counts as a type, as does '*' after an
  identifier that may itself start a type (a line's first token, or one
  after '(' ',' '[' '{' ';' ':' or a keyword; 'x = i * m' is a product),
  which over-counts declarations and never under-counts them), that is
  never address-taken
  ('&name'), subscripted, called or field-accessed (compound assignment
  and '++'/'--' are reads and writes of the register since R3,
  grammar/increment.w); a 'for' header's loop variable is a
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

void rs_lp_reset();
void rl_reset();
int rl_find_slot(int slot);
int rl_declare_pending(int t, char* name, int type);

# Loop-owned registers (R3, the section at the end of this file): the
# entries of every open loop, innermost last.
list[int] rl_sym        # symbol record offset (-1: a hidden slot)
list[int] rl_reg        # the register
list[int] rl_slot       # the record's slot value (local, hidden) or argument index
list[int] rl_kind       # 'L' local declared before the loop, 'A' argument, 'B' declared inside, 'H' hidden slot
list[int] rl_live       # storage pushed ('B'), else 1 from the start
list[char*] rl_name     # cloned, for the liveness probe
list[int] rl_mark       # rl_* length at each loop_enter
list[int] rl_pending    # candidate indices awaiting their declaration
list[int] rl_pending_mark
list[int] rl_eligible   # per open loop: 1 when it may own registers
int rl_free_mask        # registers no open loop owns
int regalloc_loop_depth # open loops (every loop_enter, active or not)
# --stats
int regalloc_loop_regs
int regalloc_loops_owned


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
int rs_type_pos       # a type may begin at the next token ('(' ',' '[' '{' ';' ':' or a keyword precede it)
int rs_ident_type_pos # the identifier being read was at such a position (or its line's first)
int rs_prev_keyword   # the previous identifier was a keyword
int rs_for_header     # inside 'for ... in'
int rs_ident_size
char* rs_ident        # identifier text buffer
int rs_ident_len
int rs_ident_hash     # rs_hash_str(rs_ident), accumulated while reading
int[64] rs_loop_tabs
int rs_loop_count

# --- loop facts (R3, §2.3): one record per 'while'/'for' keyword of the
# body in source order, keyed by the keyword's file offset, which
# grammar/while_statement.w's loop_enter looks up (loop_stmt_offset).
# Only the full scan (mode 1) records them.
list[int] rs_lp_offset     # keyword file offset
list[int] rs_lp_flags      # bit 0: a call inside; bit 1: '/', '%' or a shift inside
list[int] rs_lp_cands      # rs_lp_stride candidate indices, best first, -1 pads
const int rs_lp_stride = 10
const int rs_lp_has_call = 1
const int rs_lp_has_divshift = 2
# The open loops' records and use-count snapshots (parallel to
# rs_loop_tabs); the delta against the snapshot at the loop's end ranks
# the loop's own candidates.
int[64] rs_lp_open         # record index of each open loop
int[64] rs_lp_snap         # malloc'ed copy of rs_uses at the loop start
int[64] rs_lp_snap_len
int rs_lp_depth            # open loops with a record (mode 1)
int rs_lp_overflow         # more than 64 nested loops: no loop facts
int rs_has_goto            # 'goto' or a label: loops own no registers
int rs_has_defer           # 'defer': same (every return is an exit edge)
int rs_tok_off             # file offset of the token being read
int rs_expect_range        # 'in' of a for header seen: 'range' or a container

# Byte classes, built once from compiler/tokenizer.w's predicates so the
# lexer below agrees with it: bit 1 an identifier may start here (a-z,
# A-Z, '_', a UTF-8 lead byte), bit 2 may continue here (those and the
# digits), bit 4 an operator character, bit 8 a blank inside a line
# (space, tab, CR), bit 16 a byte the line probe stops at (newline,
# NUL, '#', a quote, '/', a brace), bit 32 a line's end (newline, NUL).
# rs_class[-1] is a valid entry (end of input: only the end bits), so
# the byte loops test one class bit per byte and nothing else.
const int rs_cl_start = 1
const int rs_cl_part = 2
const int rs_cl_op = 4
const int rs_cl_blank = 8
const int rs_cl_stop = 16
const int rs_cl_eol = 32
char* rs_class

# The reserved words the scanner acts on and the whole-function hazards,
# in a 64-slot open-addressed table on the identifier hash rs_take_ident
# accumulates: one probe per identifier instead of a strcmp per
# candidate word (rs_is_keyword and rs_is_hazard were a tenth of the
# scan). Only true keywords carry rs_kw_keyword: a user type name wrongly
# listed would hide a real declaration, while a keyword missing from the
# list only over-counts declarations (conservative).
const int rs_kw_keyword = 1
const int rs_kw_hazard = 2
const int rs_kw_slots = 64
int[64] rs_kw_hash
int[64] rs_kw_kind
int[64] rs_kw_id
int[64] rs_kw_text         # char* as int; 0: empty slot
# the ids rs_identifier compares
const int rs_id_defer = 1
const int rs_id_goto = 2
const int rs_id_new = 3
const int rs_id_in = 4
const int rs_id_while = 5
const int rs_id_for = 6
const int rs_id_range = 7   # not a keyword: the for header's 'range' call



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
		rs_lp_offset = new list[int]
		rs_lp_flags = new list[int]
		rs_lp_cands = new list[int]
	if (rs_ident == 0):
		rs_ident_size = 64
		rs_ident = cast(char*, malloc(rs_ident_size))


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
	rs_lp_reset()


# Drop the loop facts, including the snapshots of a scan that ended
# with loops still open (an abort).
void rs_lp_reset():
	while (rs_lp_depth > 0):
		rs_lp_depth = rs_lp_depth - 1
		free(cast(char*, rs_lp_snap[rs_lp_depth]))
	rs_lp_offset.clear()
	rs_lp_flags.clear()
	rs_lp_cands.clear()
	rs_lp_overflow = 0
	rs_has_goto = 0
	rs_has_defer = 0


# Mark a fact on the innermost open loop (parents inherit it when the
# loop closes).
void rs_lp_mark(int flag):
	if (rs_lp_depth == 0): return;
	int k = rs_lp_open[rs_lp_depth - 1]
	rs_lp_flags[k] = rs_lp_flags[k] | flag


# A loop keyword (mode 1): open its record and snapshot the use counts.
void rs_lp_open_loop():
	if (rs_lp_depth >= 64):
		rs_lp_overflow = 1
		return;
	int k = rs_lp_offset.length
	rs_lp_offset.push(rs_tok_off)
	rs_lp_flags.push(0)
	for i in range(rs_lp_stride): rs_lp_cands.push(-1)
	int* snap = cast(int*, malloc((rs_count + 1) * __word_size__))
	for i in range(rs_count): snap[i] = rs_uses[i]
	rs_lp_open[rs_lp_depth] = k
	rs_lp_snap[rs_lp_depth] = cast(int, snap)
	rs_lp_snap_len[rs_lp_depth] = rs_count
	rs_lp_depth = rs_lp_depth + 1


# The innermost open loop ended: rank the names it used (by the use
# count gained since its start) into its candidate slots, best first,
# and pass its hazards up to the enclosing loop.
void rs_lp_close_loop():
	if (rs_lp_depth == 0): return;
	rs_lp_depth = rs_lp_depth - 1
	int k = rs_lp_open[rs_lp_depth]
	int* snap = cast(int*, rs_lp_snap[rs_lp_depth])
	int snap_len = rs_lp_snap_len[rs_lp_depth]
	int base = k * rs_lp_stride
	for i in range(rs_count):
		int before = 0
		if (i < snap_len): before = snap[i]
		int d = rs_uses[i] - before
		if ((d <= 0) || rs_excluded[i] || (rs_decls[i] > 1)): continue
		# insertion into the sorted slots: the delta is recomputed for
		# the slot's occupant (its snapshot entry is still valid here)
		int j = 0
		while (j < rs_lp_stride):
			int c = rs_lp_cands[base + j]
			if (c < 0): break
			int cb = 0
			if (c < snap_len): cb = snap[c]
			if (rs_uses[c] - cb < d): break
			j = j + 1
		if (j >= rs_lp_stride): continue
		int m = rs_lp_stride - 1
		while (m > j):
			rs_lp_cands[base + m] = rs_lp_cands[base + m - 1]
			m = m - 1
		rs_lp_cands[base + j] = i
	free(cast(char*, snap))
	if (rs_lp_depth > 0):
		int parent = rs_lp_open[rs_lp_depth - 1]
		rs_lp_flags[parent] = rs_lp_flags[parent] | rs_lp_flags[k]


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
	regalloc_loops_ok = 0
	reg_lvalue_end = 0
	rl_reset()


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
	if (slot < 0): return;
	int li = rl_find_slot(slot)
	if (li >= 0): error3(c"internal error: stack slot of register-resident local '", rl_name[li], c"' addressed (compile with --no-regs and report this)")
	if (regalloc_promoted_count == 0): return;
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
	if (slot < 0): return 0
	int li = rl_find_slot(slot)
	if (li >= 0): return rl_reg[li]
	if (regalloc_promoted_count == 0): return 0
	for i in range(regalloc_promoted_syms.length):
		int t = regalloc_promoted_syms[i]
		if ((t < table_pos) && regalloc_promoted_live[i]):
			if ((load_int(table + t + 146) != 0) && (load_int(table + t + 2) == slot)):
				if (sym_probe(regalloc_promoted_names[i]) == t): return load_int(table + t + 146)
	return 0


# --- the byte lexer ---------------------------------------------------------
# Where the scanner's bytes come from: an image of the whole source file,
# read once per fd binding (lib/lib.w's getchar_generation: a recycled
# fd number or a replaced window is a new binding) by seeking to 0,
# reading to the end and seeking back -- four system calls per file
# instead of a save/seek/read/restore quartet per scanned body, which on
# the 32-bit compiler under a 64-bit kernel cost more than the lexing
# did (docs §11). The image is a snapshot of bytes the compiler already
# treats as immutable (every reparse path reopens the path and seeks to
# a recorded offset); neither it nor the window serving moves getchar's
# bookkeeping, which also keeps the retained-AST preflight
# (grammar/ast_expression.w inspects the window) seeing exactly what it
# would have seen without the scan. The image serves every byte it
# holds, so a body is one run with no boundary before the end of the
# file (the byte loops below and the line probe count on that); bytes
# past it come from getchar's window (under --ast-emit-retained a
# generic instantiation's source exists ONLY there -- code_generator/
# retained_emit.w serves the retained bytes through a /dev/null fd
# whose window is pre-filled, so its image is empty). A byte in neither
# ends the scan when the fd was imaged (end of file) and aborts it when
# it could not be (a pipe): a truncated body could hide an
# address-taking use.
char* rs_img          # the fd's bytes from file offset 0, rs_img_len of them
int rs_img_len
int rs_img_cap
int rs_img_bound      # rs_img_fd/rs_img_gen are set
int rs_img_fd         # the fd imaged, and its generation at the time
int rs_img_gen
int rs_img_ok         # 1: the whole file was read (possibly empty)
# The run being served: rs_p walks rs_run_base..rs_end, and rs_run_base
# is file offset rs_run_off (the window or the image).
char* rs_p
char* rs_end
char* rs_run_base
int rs_run_off

# Image the current fd, once per binding of the fd number to a stream.
void rs_image_bind():
	if (rs_img_bound && (rs_img_fd == file) && (rs_img_gen == getchar_generation[file])): return;
	rs_img_bound = 1
	rs_img_fd = file
	rs_img_gen = getchar_generation[file]
	rs_img_len = 0
	rs_img_ok = 0
	int saved = seek(file, 0, 1)
	if (saved < 0): return;
	if (seek(file, 0, 0) < 0): return;
	if (rs_img == 0):
		rs_img_cap = 1 << 18
		rs_img = cast(char*, malloc(rs_img_cap))
	# a short read is the end of a regular file (pipes were refused
	# above); one byte of room stays for the probe's NUL sentinel
	int n = 1
	int want = 1
	while (n == want):
		if (rs_img_len + 1 >= rs_img_cap):
			int x = rs_img_cap << 1
			rs_img = realloc(rs_img, rs_img_cap, x)
			rs_img_cap = x
		want = rs_img_cap - rs_img_len - 1
		n = read(file, &rs_img[rs_img_len], want)
		if (n > 0): rs_img_len = rs_img_len + n
	seek(file, saved, 0)
	if (n >= 0): rs_img_ok = 1
	else: rs_img_len = 0
	rs_img[rs_img_len] = 0

# Start serving at file offset offset (the first rs_next reads it).
void rs_begin(int offset):
	rs_image_bind()
	rs_p = 0
	rs_end = 0
	rs_run_base = 0
	rs_run_off = offset

# Serve the run that holds file offset off, starting there.
void rs_serve(char* base, int limit, int off, int run_start):
	rs_run_base = base + (off - run_start)
	rs_run_off = off
	rs_p = rs_run_base
	rs_end = base + limit

# The run is exhausted: find the next byte's offset in the window, in
# the image, or nowhere.
void rs_refill():
	int off = rs_run_off
	if (rs_run_base != 0): off = rs_run_off + (cast(int, rs_p) - cast(int, rs_run_base))
	rs_p = 0
	rs_end = 0
	if ((off >= 0) && (off < rs_img_len)):
		rs_serve(rs_img, rs_img_len, off, 0)
		return;
	int window_start = getchar_kernel_pos[file] - getchar_limit[file]
	if ((off >= window_start) && (off < getchar_kernel_pos[file])):
		rs_serve(cast(char*, getchar_buf_addr[file]), getchar_limit[file], off, window_start)
		return;
	if (rs_img_ok == 0): rs_abort = 1

void rs_next():
	if (rs_p < rs_end):
		rs_c = *rs_p & 255
		rs_p = rs_p + 1
		return;
	rs_refill()
	if (rs_p < rs_end):
		rs_c = *rs_p & 255
		rs_p = rs_p + 1
		return;
	rs_c = -1


# P2: the profile's class, span hash and loop weights read this byte
# source (compiler/regalloc_profile.w; docs §3.4).
import compiler.regalloc_profile


# Leading whitespace of a new line: count its tabs (the tokenizer's
# tab_level counts every tab before a token; leading ones are the block
# structure).
# The loops below that run once per byte walk the run in locals (the
# scan's own promotion puts them in registers) and go through rs_next
# only when the run ends.
void rs_newline():
	rs_next()
	int tabs = 0
	int c = rs_c
	char* p = rs_p
	char* end = rs_end
	while (rs_class[c] & rs_cl_blank):
		if (c == 9): tabs = tabs + 1
		if (p < end):
			c = *p & 255
			p = p + 1
		else:
			rs_p = p
			rs_next()
			c = rs_c
			p = rs_p
			end = rs_end
	rs_p = p
	rs_c = c
	rs_tabs = tabs
	rs_line_start = 1
	rs_for_header = 0
	rs_expect_range = 0


void rs_skip_line_comment():
	int c = rs_c
	char* p = rs_p
	char* end = rs_end
	while ((c != 10) && (c != -1)):
		# (a NUL in the file is not a line end here, as in the tokenizer)
		if (p < end):
			c = *p & 255
			p = p + 1
		else:
			rs_p = p
			rs_next()
			c = rs_c
			p = rs_p
			end = rs_end
	rs_p = p
	rs_c = c


void rs_skip_block_comment():
	# rs_c is the '*' after '/'
	rs_next()
	int c = rs_c
	char* p = rs_p
	char* end = rs_end
	int star = 0
	while (c != -1):
		if (star && (c == '/')):
			star = 2
			break
		star = c == '*'
		if (p < end):
			c = *p & 255
			p = p + 1
		else:
			rs_p = p
			rs_next()
			c = rs_c
			p = rs_p
			end = rs_end
	rs_p = p
	rs_c = c
	if (star == 2): rs_next()


# A quoted literal; rs_c is the opening quote.
void rs_skip_quoted(int quote):
	rs_next()
	int c = rs_c
	char* p = rs_p
	char* end = rs_end
	int escaped = 0
	while (c != -1):
		if (escaped): escaped = 0
		elif (c == quote): break
		elif (c == 92): escaped = 1
		if (p < end):
			c = *p & 255
			p = p + 1
		else:
			rs_p = p
			rs_next()
			c = rs_c
			p = rs_p
			end = rs_end
	rs_p = p
	rs_c = c
	if (c == quote): rs_next()


void rs_ident_put(int c):
	if (rs_ident_len + 2 > rs_ident_size):
		int x = rs_ident_size << 1
		rs_ident = realloc(rs_ident, rs_ident_size, x)
		rs_ident_size = x
	rs_ident[rs_ident_len] = c
	rs_ident_len = rs_ident_len + 1


void rs_take_ident_slow():
	int n = 0
	int h = 0
	int c = rs_c
	char* p = rs_p
	char* end = rs_end
	char* out = rs_ident
	while (rs_class[c] & rs_cl_part):
		if (n + 2 > rs_ident_size):
			rs_ident_len = n
			rs_ident_put(c)
			n = rs_ident_len
			out = rs_ident
		else:
			out[n] = c
			n = n + 1
		h = (h * 31) + c
		if (p < end):
			c = *p & 255
			p = p + 1
		else:
			rs_p = p
			rs_next()
			c = rs_c
			p = rs_p
			end = rs_end
	rs_p = p
	rs_c = c
	out[n] = 0
	rs_ident_len = n
	rs_ident_hash = h


# The run holds the whole identifier (rs_p is past its first byte, rs_c)
# unless it ends inside it, which only the end of the file or a window
# can do: then the general path.
void rs_take_ident():
	int h = rs_c
	char* p = rs_p
	char* end = rs_end
	int c = -1
	while (p < end):
		c = *p & 255
		if ((rs_class[c] & rs_cl_part) == 0): break
		h = (h * 31) + c
		p = p + 1
		c = -1
	if (c < 0):
		rs_take_ident_slow()
		return;
	int n = cast(int, p) - cast(int, rs_p) + 1
	while (n + 2 > rs_ident_size):
		int x = rs_ident_size << 1
		rs_ident = realloc(rs_ident, rs_ident_size, x)
		rs_ident_size = x
	char* out = rs_ident
	out[0] = rs_c
	char* src = rs_p
	int i = 1
	while (i < n):
		out[i] = src[i - 1]
		i = i + 1
	out[n] = 0
	rs_ident_len = n
	rs_ident_hash = h
	rs_p = p + 1
	rs_c = c


int rs_weight():
	if (rs_profile_weighted): return rs_profile_weight()   # P2: the profile's counts
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


void rs_kw_add(char* text, int kind, int id):
	int h = rs_hash_str(text)
	int i = h & (rs_kw_slots - 1)
	while (rs_kw_text[i] != 0): i = (i + 1) & (rs_kw_slots - 1)
	rs_kw_hash[i] = h
	rs_kw_kind[i] = kind
	rs_kw_id[i] = id
	rs_kw_text[i] = cast(int, text)


# The slot of the word, or -1.
int rs_kw_lookup(char* name, int h):
	int i = h & (rs_kw_slots - 1)
	while (rs_kw_text[i] != 0):
		if ((rs_kw_hash[i] == h) && (strcmp(cast(char*, rs_kw_text[i]), name) == 0)): return i
		i = (i + 1) & (rs_kw_slots - 1)
	return -1


void rs_class_ensure():
	if (rs_class != 0): return;
	char* table = cast(char*, malloc(258))
	rs_class = &table[1]
	rs_class[-1] = rs_cl_stop | rs_cl_eol
	for c in range(256):
		int f = 0
		if ((('a' <= c) && (c <= 'z')) || (('A' <= c) && (c <= 'Z')) || (c == '_') || ((c >= 128) && is_ident_start_byte(c))): f = rs_cl_start | rs_cl_part
		elif (('0' <= c) && (c <= '9')): f = rs_cl_part
		if ((c == '+') || (c == '-') || (c == '*') || (c == '/') || (c == '%') || (c == '^') || (c == '&') || (c == '|') || (c == '<') || (c == '>') || (c == '=') || (c == '!')): f = f | rs_cl_op
		if ((c == ' ') || (c == 9) || (c == 13)): f = f | rs_cl_blank
		if ((c == 10) || (c == 0)): f = f | rs_cl_stop | rs_cl_eol
		if ((c == '#') || (c == '"') || (c == 39) || (c == '/') || (c == '{') || (c == '}')): f = f | rs_cl_stop
		rs_class[c] = f
	rs_kw_add(c"return", rs_kw_keyword, 0)
	rs_kw_add(c"yield", rs_kw_keyword | rs_kw_hazard, 0)
	rs_kw_add(c"defer", rs_kw_keyword, rs_id_defer)
	rs_kw_add(c"default", rs_kw_keyword, 0)
	rs_kw_add(c"debugger", rs_kw_keyword, 0)
	rs_kw_add(c"goto", rs_kw_keyword, rs_id_goto)
	rs_kw_add(c"new", rs_kw_keyword, rs_id_new)
	rs_kw_add(c"in", rs_kw_keyword, rs_id_in)
	rs_kw_add(c"if", rs_kw_keyword, 0)
	rs_kw_add(c"import", rs_kw_keyword, 0)
	rs_kw_add(c"as", rs_kw_keyword, 0)
	rs_kw_add(c"else", rs_kw_keyword, 0)
	rs_kw_add(c"elif", rs_kw_keyword, 0)
	rs_kw_add(c"while", rs_kw_keyword, rs_id_while)
	rs_kw_add(c"for", rs_kw_keyword, rs_id_for)
	rs_kw_add(c"switch", rs_kw_keyword, 0)
	rs_kw_add(c"sizeof", rs_kw_keyword, 0)
	rs_kw_add(c"case", rs_kw_keyword, 0)
	rs_kw_add(c"continue", rs_kw_keyword, 0)
	rs_kw_add(c"cast", rs_kw_keyword, 0)
	rs_kw_add(c"const", rs_kw_keyword, 0)
	rs_kw_add(c"break", rs_kw_keyword, 0)
	rs_kw_add(c"pass", rs_kw_keyword, 0)
	rs_kw_add(c"launch", rs_kw_keyword | rs_kw_hazard, 0)
	# whole-function hazards (§2.4): any register may be live in an asm
	# block, setjmp/longjmp callers keep their locals in memory,
	# generators and gpu bodies have their own stacks
	rs_kw_add(c"raw_asm", rs_kw_hazard, 0)
	rs_kw_add(c"repl_setjmp", rs_kw_hazard, 0)
	rs_kw_add(c"repl_longjmp", rs_kw_hazard, 0)
	rs_kw_add(c"setjmp", rs_kw_hazard, 0)
	rs_kw_add(c"longjmp", rs_kw_hazard, 0)
	rs_kw_add(c"gpu", rs_kw_hazard, 0)
	rs_kw_add(c"kernel", rs_kw_hazard, 0)
	rs_kw_add(c"range", 0, rs_id_range)


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
	int c = rs_c
	char* p = rs_p
	char* end = rs_end
	while (rs_class[c] & rs_cl_blank):
		if (p < end):
			c = *p & 255
			p = p + 1
		else:
			rs_p = p
			rs_next()
			c = rs_c
			p = rs_p
			end = rs_end
	rs_p = p
	rs_c = c


int rs_is_op_char(int c):
	return rs_class[c] & rs_cl_op


# An operator run after an identifier (the identifier's index is i, -1
# when it is not tracked): classify the run as a compound assignment or
# increment (both read and write the name), a plain
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
	if ((first == '/') || (first == '%') || ((n >= 2) && (first == second) && ((first == '<') || (first == '>')))): rs_lp_mark(rs_lp_has_divshift)
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
	# A compound assignment or '++'/'--' (use 3) reads and writes the
	# name: two uses (R3: grammar/increment.w emits 'op R,X' in place)
	if (i >= 0):
		if (use == 0): rs_decls[i] = rs_decls[i] + 1
		else if (use == 3): rs_uses[i] = rs_uses[i] + (rs_weight() << 1)
		else: rs_uses[i] = rs_uses[i] + rs_weight()
	# '&' alone after an operand is the binary operator
	rs_prev_kind = 0
	# 'T* name' only where a statement, parameter, cast or generic
	# argument may begin; 'a * b' mid-expression is the product (the
	# distinction keeps 'x = i * m' from counting m as a declaration)
	if ((n == 1) && (first == '*') && (rs_ident_type_pos || type_context)): rs_prev_kind = 3


# An identifier (not a field name) has been read into rs_ident.
void rs_identifier():
	char* name = rs_ident
	int type_context = (rs_prev_kind == 3) || (rs_prev_kind == 4) || ((rs_prev_kind == 1) && (rs_prev_keyword == 0))
	int address_taken = rs_prev_kind == 5
	int kw = rs_kw_lookup(name, rs_ident_hash)
	int kind = 0
	int id = 0
	if (kw >= 0):
		kind = rs_kw_kind[kw]
		id = rs_kw_id[kw]
	if (kind & rs_kw_hazard):
		rs_abort = 1
		return;
	if (kind & rs_kw_keyword):
		if (rs_at_start):
			if ((id == rs_id_while) || (id == rs_id_for)):
				rs_has_loop = 1
				# the keyword's file offset (R3 keys the loop's facts by
				# it): rs_c is the byte after the identifier
				rs_tok_off = -1
				if (rs_p != 0): rs_tok_off = rs_run_off + (cast(int, rs_p) - cast(int, rs_run_base)) - 1 - rs_ident_len
				if (rs_loop_count < 64):
					rs_loop_tabs[rs_loop_count] = rs_tabs
					rs_loop_count = rs_loop_count + 1
					if (rs_mode == 1): rs_lp_open_loop()
				elif (rs_mode == 1): rs_lp_overflow = 1
				rs_profile_loop_note()   # P2: this head's weight from the profile
				if (id == rs_id_for): rs_for_header = 1
		if (id == rs_id_in):
			# the for header's 'in': 'range' or a container (hidden
			# iterator calls); elsewhere a container membership test
			if (rs_for_header): rs_expect_range = 1
			else: rs_lp_mark(rs_lp_has_call)
			rs_for_header = 0
		elif (id == rs_id_new): rs_lp_mark(rs_lp_has_call)
		elif (id == rs_id_goto): rs_has_goto = 1
		elif (id == rs_id_defer): rs_has_defer = 1
		rs_prev_kind = 1
		rs_prev_keyword = 1
		rs_type_pos = 1
		return;
	if (rs_expect_range):
		rs_expect_range = 0
		if (id == rs_id_range):
			rs_prev_kind = 1
			rs_prev_keyword = 1
			return;
		rs_lp_mark(rs_lp_has_call)
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
		if (c == '('): rs_lp_mark(rs_lp_has_call)
		return;
	if (c == ':'):
		rs_next()
		rs_prev_kind = 0
		rs_type_pos = 1
		if (rs_c == '='):
			rs_next()
			if (i >= 0): rs_decls[i] = rs_decls[i] + 1
		elif (rs_at_start && (type_context == 0)): rs_has_goto = 1   # 'name:' is a label
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
		if (rs_mode == 1): rs_lp_close_loop()


# Whether a 'while'/'for' opens a line of a ':' body, decided line by
# line on the image, where mode 0 of rs_scan_body decides the same thing
# by lexing every token (and most bodies have no loop, so this is most
# of the scan's work): 0 no, 1 yes, 2 the body has something the line
# view cannot follow -- a token on the signature line, a brace, a '/'
# opening a line or followed by '*', a literal running past its line, a
# NUL, or bytes a window serves -- and rs_scan_body must look. The
# answer is never a guess: a body without a loop promotes nothing and
# must not pay a full pass, one with a loop must get the pass, and the
# scan's output must not depend on which path decided. rs_c is the byte
# after the ':'; the image's NUL sentinel ends the line loops.
int rs_probe_lines():
	if (rs_p == 0): rs_refill()
	if ((rs_run_base == 0) || (rs_end != &rs_img[rs_img_len])): return 2
	int c = rs_c
	char* p = rs_p
	char* end = rs_end
	# the rest of the signature line: blanks and a comment; anything
	# else is a same-line body
	while (rs_class[c] & rs_cl_blank):
		c = *p & 255
		p = p + 1
	if (c == '#'):
		while ((rs_class[c] & rs_cl_eol) == 0):
			c = *p & 255
			p = p + 1
	if (c != 10): return 2
	int start_tabs = -1
	while (c == 10):
		c = *p & 255
		p = p + 1
		int tabs = 0
		while (rs_class[c] & rs_cl_blank):
			if (c == 9): tabs = tabs + 1
			c = *p & 255
			p = p + 1
		if (c == 10): continue
		if (c == '#'):
			while ((rs_class[c] & rs_cl_eol) == 0):
				c = *p & 255
				p = p + 1
			continue
		if (c == 0):
			if (p > end): return 0   # the sentinel: end of file
			return 2
		if (c == '/'): return 2   # a block comment is not a token
		# a token opens the line (rs_line_token)
		if (start_tabs < 0): start_tabs = tabs
		elif (tabs < start_tabs): return 0
		if (c == 'w'):
			if ((p[0] == 'h') && (p[1] == 'i') && (p[2] == 'l') && (p[3] == 'e') && ((rs_class[p[4] & 255] & rs_cl_part) == 0)): return 1
		elif (c == 'f'):
			if ((p[0] == 'o') && (p[1] == 'r') && ((rs_class[p[2] & 255] & rs_cl_part) == 0)): return 1
		# the rest of the line
		while (c != 10):
			while ((rs_class[c] & rs_cl_stop) == 0):
				c = *p & 255
				p = p + 1
			if (c == 10): break
			if (c == 0):
				if (p > end): return 0   # the sentinel: end of file
				return 2
			if (c == '#'):
				while ((rs_class[c] & rs_cl_eol) == 0):
					c = *p & 255
					p = p + 1
				break
			if ((c == '"') || (c == 39)):
				int quote = c
				c = *p & 255
				p = p + 1
				while (c != quote):
					if (c == 92):
						c = *p & 255
						p = p + 1
					if (rs_class[c] & rs_cl_eol): return 2
					c = *p & 255
					p = p + 1
				c = *p & 255
				p = p + 1
				continue
			if (c == '/'):
				c = *p & 255
				p = p + 1
				if (c == '*'): return 2
				continue
			return 2   # '{', '}', a NUL
	return 0


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
	rs_expect_range = 0
	rs_type_pos = 0
	rs_loop_count = 0
	int first = 1
	while ((rs_done == 0) && (rs_abort == 0) && (rs_c != -1)):
		if ((rs_mode == 0) && rs_has_loop): return;
		if (rs_c == 10):
			if (rs_same_line && (rs_depth == 0)): return;
			rs_newline()
			rs_prev_kind = 0
			continue
		int cl = rs_class[rs_c]
		if (cl & rs_cl_blank):
			rs_skip_blanks()
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
			rs_lp_mark(rs_lp_has_divshift)
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
		if (cl & rs_cl_start):
			# a field name after '.' is not a variable; a method call or a
			# container field indexed/called is a hidden call
			int field = rs_prev_kind == 6
			rs_ident_type_pos = rs_at_start || rs_type_pos
			rs_type_pos = 0
			rs_take_ident()
			if (field):
				rs_prev_kind = 2
				rs_skip_blanks()
				if ((rs_c == '(') || (rs_c == '[')): rs_lp_mark(rs_lp_has_call)
			else: rs_identifier()
			continue
		rs_type_pos = 0
		if (('0' <= c) && (c <= '9')):
			while ((rs_c != -1) && ((rs_class[rs_c] & rs_cl_part) || (rs_c == '.'))): rs_next()
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
			rs_type_pos = 1
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
			int secondc = 0
			while (rs_is_op_char(rs_c)):
				if (n == 1): secondc = rs_c
				n = n + 1
				rs_next()
			rs_prev_kind = 0
			if ((firstc == '%') || ((n >= 2) && (firstc == secondc) && ((firstc == '<') || (firstc == '>')))): rs_lp_mark(rs_lp_has_divshift)
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
		# '(' '[' ',' ';' ':' '?' '@' and anything else; '(' right after
		# an operand ('f(x)(y)', 'table[i](x)') is a call
		if ((c == '(') && ((rs_prev_kind == 2) || (rs_prev_kind == 4))): rs_lp_mark(rs_lp_has_call)
		if ((c == '(') && rs_expect_range):
			rs_expect_range = 0
			rs_lp_mark(rs_lp_has_call)
		if ((c == '(') || (c == '[') || (c == ',') || (c == ';') || (c == ':')): rs_type_pos = 1
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
	rs_class_ensure()
	regalloc_function_end()
	# P2 (compiler/regalloc_profile.w): the profile's class for this
	# function, computed here even when nothing below runs (the loop
	# alignment reads it). cold: the scan is skipped; hot: no probe,
	# straight to the full pass; unknown: the heuristic below.
	int profile_class = 0
	if ((file >= 0) && (file < GETCHAR_MAX_FD)): profile_class = rs_profile_begin(symbol)
	else: profile_use_function_prepare(symbol, sym_record_name(symbol))
	if (regalloc_disabled): return;
	if ((target_isa != 0) || (target_os != 0)): return;
	if (is_variadic): return;
	if ((file < 0) || (file >= GETCHAR_MAX_FD)): return;
	if (token[0] == 0): return;
	int brace_body = token[0] == '{'
	if ((brace_body == 0) && (token[0] != ':')): return;
	# The byte after the current token is the tokenizer's lookahead
	# nextc (file offset byte_offset - 1); the scan starts from it and
	# reads on from byte_offset, the fd's position.
	if (profile_class == 1): return;   # P2: cold
	int body_offset = byte_offset
	rs_begin(body_offset)
	rs_c = nextc
	rs_mode = 0
	if (profile_class == 2): rs_mode = 1   # P2: hot
	int probe = 2
	if ((rs_mode == 0) && (brace_body == 0)): probe = rs_probe_lines()
	if (probe == 2):
		rs_profile_pass_begin()   # P2
		rs_scan_body(brace_body)
	else:
		rs_abort = 0
		rs_has_loop = probe
	int mask = 0
	if ((rs_mode == 0) && rs_has_loop && (rs_abort == 0)):
		rs_begin(body_offset)
		rs_c = nextc
		rs_mode = 1
		rs_profile_pass_begin()   # P2
		rs_scan_body(brace_body)
	while (rs_lp_depth > 0): rs_lp_close_loop()
	if ((rs_mode == 1) && (rs_abort == 0)):
		regalloc_scanned_functions = regalloc_scanned_functions + 1
		mask = rs_assign_registers()
		if (mask == 0): rs_profile_fruitless = rs_profile_fruitless + 1   # P2: --stats
	# Loops own caller-saved registers (R3) only when no jump can leave a
	# loop body other than through its exit region: no goto/labels, no
	# defer (every return would be an exit edge), and the scan saw every
	# loop.
	int loops = 0
	if ((rs_abort == 0) && (rs_lp_offset.length > 0) && (rs_has_goto == 0) && (rs_has_defer == 0) && (rs_lp_overflow == 0)): loops = 1
	if ((mask == 0) && (loops == 0)):
		rs_tables_clear()
		return;
	regalloc_pending_mask = mask
	regalloc_function = symbol
	regalloc_loops_ok = loops


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
	if ((rs_reg[i] == 0) || rs_taken[i]): return rl_declare_pending(t, name, type)
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
	if (rl_sym != 0):
		for i in range(rl_sym.length):
			if (rl_sym[i] == t): rl_live[i] = 1


# --- loop-scoped registers (R3, §2.3) ------------------------------------
# In a loop the scan found call-free, locals the function-scoped ranking
# left on the stack (and the function's arguments, and the range loop's
# hidden end/step slots) live in caller-saved registers for the loop's
# extent: x64 rsi rdi r8-r11. The loop head (loop_enter in
# grammar/while_statement.w) loads each from its home, the exit region's
# end (loop_leave) writes it back and clears the symbol's register field,
# so code after the loop reads the stack word again. Homes are addressed
# from the frame pointer ('[ebp-W*(slot-1)]' for a local, '[ebp+W*(nargs-
# slot+2)]' for an argument), which no push or pop moves. A local
# declared inside the loop ('B') takes its register at its declaration
# (regalloc_declare) and is dead when the loop ends. Every call the loop
# body emits after all (a hidden call the scan did not see: a container
# op, an operator overload, a bounds trap) spills the live loop registers
# to their homes before it and reloads them after it (regalloc_call_spill
# / _reload, called by call_eax and the inline FFI path), so a scan miss
# costs instructions, never correctness. Functions with goto/labels or
# defer own no loop registers (regalloc_loops_ok, the scan).
void rl_ensure():
	if (rl_sym != 0): return;
	rl_sym = new list[int]
	rl_reg = new list[int]
	rl_slot = new list[int]
	rl_kind = new list[int]
	rl_live = new list[int]
	rl_name = new list[char*]
	rl_mark = new list[int]
	rl_pending = new list[int]
	rl_pending_mark = new list[int]
	rl_eligible = new list[int]


# Back to "no loop owns anything" (function end, REPL rollback).
void rl_reset():
	rl_ensure()
	for i in range(rl_name.length): free(rl_name[i])
	rl_sym.clear()
	rl_reg.clear()
	rl_slot.clear()
	rl_kind.clear()
	rl_live.clear()
	rl_name.clear()
	rl_mark.clear()
	rl_pending.clear()
	rl_pending_mark.clear()
	rl_eligible.clear()
	rl_free_mask = 0
	regalloc_loop_depth = 0


# The caller-saved registers a loop may own on this target: x64 only
# (x86's ecx/edx are the shift count and the division/multiply high
# half, R4 territory).
int rl_target_mask():
	if (target_isa != 0): return 0
	if (target_os != 0): return 0
	if (word_size != 8): return 0
	return (1 << 6) | (1 << 7) | (1 << 8) | (1 << 9) | (1 << 10) | (1 << 11)


int rl_take_register():
	int r = 0
	while (r < 16):
		if (rl_free_mask & (1 << r)):
			rl_free_mask = rl_free_mask & ~(1 << r)
			return r
		r = r + 1
	return 0


# The frame-pointer displacement of an entry's home.
int rl_home_disp(int i):
	int kind = rl_kind[i]
	if (kind == 'A'): return (number_of_args - rl_slot[i] + 2) << word_size_log2
	return 0 - (rl_slot[i] << word_size_log2)


# Is entry i's storage there to read or write: a 'B' local only once its
# declaration pushed it and while its scope lasts ('L'/'A' outlive the
# loop by construction, a hidden slot lasts exactly the loop).
int rl_entry_live(int i):
	if (rl_live[i] == 0): return 0
	int kind = rl_kind[i]
	if ((kind == 'L') || (kind == 'A') || (kind == 'B')):
		int t = rl_sym[i]
		if (t >= table_pos): return 0
		if (sym_probe(rl_name[i]) != t): return 0
	return 1


void rl_add(int t, int reg, int slot, int kind, char* name, int live):
	rl_sym.push(t)
	rl_reg.push(reg)
	rl_slot.push(slot)
	rl_kind.push(kind)
	rl_live.push(live)
	rl_name.push(strclone(name))
	regalloc_loop_regs = regalloc_loop_regs + 1


# A loop statement begins, before its loop region: offset is the file
# offset of its keyword (grammar/statement.w's loop_stmt_offset). Loads
# the loop's candidates into free caller-saved registers.
void regalloc_loop_enter(int offset):
	rl_ensure()
	rl_mark.push(rl_sym.length)
	rl_pending_mark.push(rl_pending.length)
	rl_eligible.push(0)
	regalloc_loop_depth = regalloc_loop_depth + 1
	if ((regalloc_active == 0) || (regalloc_loops_ok == 0)): return;
	if (rl_target_mask() == 0): return;
	int k = -1
	for j in range(rs_lp_offset.length):
		if (rs_lp_offset[j] == offset): k = j
	if (k < 0): return;
	int flags = rs_lp_flags[k]
	if (flags & rs_lp_has_call): return;
	if (regalloc_loop_depth == 1): rl_free_mask = rl_target_mask()
	int last_open = rl_eligible.length - 1
	rl_eligible[last_open] = 1
	regalloc_loops_owned = regalloc_loops_owned + 1
	int base = k * rs_lp_stride
	for j in range(rs_lp_stride):
		if (rl_free_mask == 0): return;
		int i = rs_lp_cands[base + j]
		if (i < 0): return;
		if (rs_excluded[i] || (rs_reg[i] != 0) || (rs_decls[i] > 1)): continue
		char* name = rs_names[i]
		int t = sym_probe(name)
		if (t < 0):
			if (rs_decls[i] == 1): rl_pending.push(i)
			continue
		int scope = table[t + 1]
		if (scope == 'L'):
			if (rs_decls[i] != 1): continue
		elif (scope == 'A'):
			if (rs_decls[i] != 0): continue
		else:
			# a global of that name; the body's declaration comes later
			if (rs_decls[i] == 1): rl_pending.push(i)
			continue
		if (load_int(table + t + 146) != 0): continue
		if (regalloc_type_ok(load_int(table + t + 6)) == 0): continue
		int reg = rl_take_register()
		if (reg == 0): return;
		save_int(table + t + 146, reg)
		rl_add(t, reg, load_int(table + t + 2), scope, name, 1)
		mov_reg_ebp_disp(reg, rl_home_disp(rl_sym.length - 1))


# A range loop's hidden end or step word (its slot, as the for statement
# numbers it): a free register of the innermost loop, loaded here, or 0.
int regalloc_loop_hidden(int slot):
	if (rl_eligible == 0): return 0
	if (rl_eligible.length == 0): return 0
	if (rl_eligible[rl_eligible.length - 1] == 0): return 0
	int reg = rl_take_register()
	if (reg == 0): return 0
	rl_add(-1, reg, slot - 1, 'H', c"", 1)
	mov_reg_ebp_disp(reg, rl_home_disp(rl_sym.length - 1))
	return reg


# The register holding the hidden slot, 0 when it is on the stack.
int regalloc_hidden_register(int slot):
	if (rl_sym == 0): return 0
	for i in range(rl_sym.length):
		if ((rl_kind[i] == 'H') && (rl_slot[i] == slot - 1)): return rl_reg[i]
	return 0


# The loop's exit region has ended (every exit edge lands here): write
# the loop's registers back to their homes and give them up.
void regalloc_loop_leave():
	rl_ensure()
	if (rl_mark.length == 0): return;
	regalloc_loop_depth = regalloc_loop_depth - 1
	int mark = rl_mark[rl_mark.length - 1]
	int i = rl_sym.length
	while (i > mark):
		i = i - 1
		int kind = rl_kind[i]
		int t = rl_sym[i]
		if (rl_entry_live(i)):
			if (kind != 'H'): mov_ebp_disp_reg(rl_reg[i], rl_home_disp(i))
			if (t >= 0): save_int(table + t + 146, 0)
		rl_free_mask = rl_free_mask | (1 << rl_reg[i])
		free(rl_name[i])
	while (rl_sym.length > mark):
		rl_sym.pop()
		rl_reg.pop()
		rl_slot.pop()
		rl_kind.pop()
		rl_live.pop()
		rl_name.pop()
	int pmark = rl_pending_mark[rl_pending_mark.length - 1]
	while (rl_pending.length > pmark): rl_pending.pop()
	rl_mark.pop()
	rl_pending_mark.pop()
	rl_eligible.pop()
	if (regalloc_loop_depth == 0): rl_free_mask = 0


# regalloc_declare's second source: a candidate some open loop listed
# whose declaration is being parsed now (class 'B'). Returns the
# register or 0.
int rl_declare_pending(int t, char* name, int type):
	if (rl_pending == 0): return 0
	int k = rl_pending.length
	while (k > 0):
		k = k - 1
		int i = rl_pending[k]
		if (i < 0): continue
		if (strcmp(rs_names[i], name) != 0): continue
		rl_pending[k] = -1
		if (rl_eligible[rl_eligible.length - 1] == 0): return 0
		if (regalloc_type_ok(type) == 0): return 0
		int reg = rl_take_register()
		if (reg == 0): return 0
		rl_add(t, reg, load_int(table + t + 2), 'B', name, 0)
		return reg
	return 0


# A call is about to be emitted inside a loop that owns registers: park
# them in their homes, and fetch them back afterwards.
void regalloc_call_spill():
	if (rl_sym == 0): return;
	for i in range(rl_sym.length):
		if (rl_entry_live(i) && (rl_kind[i] != 'H')): mov_ebp_disp_reg(rl_reg[i], rl_home_disp(i))

void regalloc_call_reload():
	if (rl_sym == 0): return;
	for i in range(rl_sym.length):
		if (rl_entry_live(i)): mov_reg_ebp_disp(rl_reg[i], rl_home_disp(i))


# The loop entry whose storage word is stack slot 'slot' (see
# regalloc_slot_register), -1 when none.
int rl_find_slot(int slot):
	if (rl_sym == 0): return -1
	for i in range(rl_sym.length):
		int kind = rl_kind[i]
		if (((kind == 'L') || (kind == 'B')) && (rl_slot[i] == slot) && rl_entry_live(i)): return i
	return -1


void regalloc_stats_dump():
	print_int0(c"regalloc: bodies scanned: ", regalloc_scanned_functions)
	print_int0(c" locals promoted: ", regalloc_promoted_locals)
	print_int0(c" loops owning registers: ", regalloc_loops_owned)
	print_int0(c" loop registers: ", regalloc_loop_regs)
	print_error(c"\x0a")
	rs_profile_stats_dump()   # P2
