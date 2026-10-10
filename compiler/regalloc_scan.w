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
  never address-taken ('&name') or called ('name(') (compound
  assignment and '++'/'--' are reads and writes of the register since
  R3, grammar/increment.w); a 'for' header's loop variable is a
  declaration like any other (R2b: the loop writes it through the
  register path);
- a subscript ('name[i]') and a field access ('name.f') are reads of
  the name (A1, docs/projects/codegen_gap_plan.md §2.1): the address
  they form is the element's or the field's, through the pointer's
  value, never the variable's, so '&name[i]' and '&name.f' are reads
  too. grammar/postfix_expr.w's '[' adds the register to the scaled
  index in place of the parked copy the stack path needs, which is why
  a subscript weighs two reads in the ranking and why a name written
  inside a subscript whose base it is ('a[a = q]') is excluded: the
  fold would read the new value. Only a subscript whose index has more
  than one token counts as a use (two, for the slot load and the parked
  copy the fold removes), kept apart in rs_base: a one-token index and
  a field read cost the same on the stack as through a register until
  A2's addressing forms, so they earn no register. Scalars rank first,
  bases take the registers they leave. A struct value's 'name.f' and an
  array's 'name[i]' address frame storage; those names are excluded by
  their declared type ('T[..] name' is never a register, and a type
  name the type table already knows as unpromotable -- a struct, a
  narrow integer, a float -- excludes its declaration), and
  regalloc_type_ok at sym_declare is the final word;
- the declared type must be a plain 'int', a pointer or (A8,
  docs/projects/codegen_gap_plan.md §2.7) an 'int32'/'uint32' (checked
  at sym_declare: the other narrow integers, floats, aggregates,
  strings, containers and const-qualified locals never promote). On
  x64 a 32-bit integer's register holds the value as the memory path's
  load would promote it -- zero-extended for uint32, sign-extended for
  int32 -- and every write to it is a 32-bit form (x86.w's
  regalloc_reg_kind and the writers that consult it), so wrap-around
  matches the stack word bit for bit and every reader stays word-sized;
- on x64 a function argument ranks like a local (A1): a name the body
  never declares whose record is a word-sized parameter of this
  function (sym_probe at ranking time, regalloc_type_ok on its type)
  takes a callee-saved register too, loaded from its stack word right
  after the prologue's pushes (regalloc_prologue_args); nothing reads
  the word again, and the register is dead at every return, so no
  write-back. Scalars rank first; bases and arguments take the
  registers they leave (rs_assign_registers), and x86's two stay with
  the scalars (rs_args_rank);
- uses are weighted 8^depth by 'while'/'for' nesting (indentation-based,
  like the parser's block structure); on x86 only names used inside a
  loop are ranked, and a body without a loop is not scanned past the
  first pass. On x64 (unit O2) every body is scanned whole: a leaf body
  keeps the names with the most register gain in caller-saved registers
  for its whole extent (the function region, rs_fn_rank), and a name a
  loop does not rank -- or any name of a loop-free body -- takes a
  callee-saved register when its gain pays for the push and pop
  (rs_assign_registers' third round). A field access 'name.f' counts as
  a use of the name there: through a register it is one '[R+disp]'
  operand;
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
import compiler.inline_table

void rs_lp_reset();
void rl_reset();
int rs_run_assigns(int n, int first, int second, int last);
int regalloc_type_ok(int type);
int rl_find_slot(int slot);
int rl_declare_pending(int t, char* name, int type);
int rl_target_mask();
int rs_gain(int i);
int rs_fn_target_ok();
int rl_take_register();
int rl_home_disp(int i);
void rl_ensure();
void rl_add(int t, int reg, int slot, int kind, char* name, int live);
# compiler/ivopt.w (unit O7), imported after the grammar
int ivopt_scan_loop(int start, int end, int tabs);
void ivopt_reset();
void ivopt_active_reset();
void ivopt_loop_enter(int offset);
void ivopt_loop_leave();
void ivopt_call_reload();
int ivopt_covers(char* name);
int rs_cur_offset();
void rs_iv_discount();
int rs_lookup(char* name);
int ivopt_inside_names();
char* ivopt_inside_name(int i);
int ivopt_inside_base(int i);
int ivopt_inside_index(int i);
void ivopt_stats_dump();

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
# O2: the function region (rl_fn_region_enter) is open below every loop,
# the rl_pending entries below rl_fn_pending_end are its locals, and
# rl_fn_reserved of the free registers are kept for those not declared yet
int rl_fn_region
int rl_fn_pending_end
int rl_fn_reserved
int regalloc_fn_regs    # --stats
# --stats
int regalloc_loop_regs
int regalloc_loops_owned


# --- candidate table (per scanned function) -------------------------------
list[char*] rs_names      # cloned identifier text
list[int] rs_decls        # recognised declarations
list[int] rs_uses         # loop-weighted use count: scalar reads and writes, plus rs_base
list[int] rs_base         # loop-weighted subscripts with a multi-token index ('a[i * n + k]')
list[int] rs_lv           # A9: loop-weighted uses a register shortens on x86 (writes, bases, indices, compare left sides)
list[int] rs_field        # O2: loop-weighted field accesses 'name.f' (not a method call): a register base folds them
list[int] rs_peek         # O2: loop-weighted 'x = x op ...' writes (half of their rs_lv is gain)
list[int] rs_fnreg        # O2: 1 when the function region (rl_fn_*) holds the name
list[int] rs_excluded     # 1 once a hazardous use was seen
list[int] rs_reg          # register assigned by the ranking, 0 none
list[int] rs_taken        # 1 once a declaration took the register
list[int] rs_argsym       # -2 unprobed, -1 not a promotable argument, else the parameter's record
list[int] rs_hash         # rs_hash_str(name), chained through rs_chain
list[int] rs_chain        # next index in the bucket, -1 ends the chain
int[256] rs_buckets       # hash & 255 -> index + 1, 0 empty
int rs_count
# O2: the function region's candidates (rl_fn_region_enter), best first,
# whether a loop of the body makes a real call (one outside the loops
# only spills the region around itself, regalloc_call_spill), and the
# candidate whose '.' the next field name follows (rs_field)
list[int] rs_fn_cands
int rs_fn_has_call
# O5: a call the inliner will not take (a leaf it takes needs no
# homes: a region spill there is a touch, and no entry is published)
int rs_fn_real_call
int rs_field_owner

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
# Arguments the ranking gave a register (record offsets and registers),
# loaded by regalloc_prologue_args right after the prologue's pushes.
list[int] regalloc_arg_syms
list[int] regalloc_arg_regs

# --stats: scanned bodies and promoted locals, printed by 'w --stats'
int regalloc_scanned_functions
int regalloc_promoted_locals
int regalloc_promoted_args

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

# --- register arguments (O5; the section at the end of this file) ---
# A function's register entry lives in its symbol record: the entry's
# address at +154 (0: none) and its parameters' registers at +158, 4 bits
# each, parameter 0 lowest (compiler/symbol_table.w's sym_declare).
int rg_symbol      # the scanned function's record
int rg_asm_body    # function_definition: the body opens with an asm block
int rg_shaped      # the region ranked every parameter first (rg_shape_rank)
int rg_nparams
int rg_resume      # codepos past the region's argument loads, 0: none
int rg_regs_cur    # the parameters' registers so far, packed as at +158
int rg_loaded      # parameters the region loaded
# --stats
int regargs_entries
int regargs_calls
void rg_shape_rank();
void rg_note_param(int index, int reg);

# --- loop facts (R3, §2.3): one record per 'while'/'for' keyword of the
# body in source order, keyed by the keyword's file offset, which
# grammar/while_statement.w's loop_enter looks up (loop_stmt_offset).
# Only the full scan (mode 1) records them.
list[int] rs_lp_offset     # keyword file offset
list[int] rs_lp_flags      # bit 0: a call inside; bit 1: '/', '%' or a shift inside
list[int] rs_lp_cands      # rs_lp_stride candidate indices, best first, -1 pads
list[int] rs_lp_vals       # each candidate's loop-weighted key delta (the value a register has in the loop)
list[int] rs_lp_ops        # binary operators inside the loop, loop-weighted (A9: the parks a loop register displaces on x86)
list[int] rs_lp_tabs       # O7: leading tabs of the keyword's line
list[int] rs_lp_inner      # O7: 1 when another loop is nested in it
list[int] rs_lp_ivneed     # O7: pointer registers the innermost loops in it want (compiler/ivopt.w)
int[64] rs_lp_ops_snap     # rs_ops at each open loop's start
int rs_ops                 # binary operator runs seen, loop-weighted
const int rs_lp_stride = 16
const int rs_lp_has_call = 1
const int rs_lp_has_divshift = 2
# O2's register gain thresholds (rs_gain): the function region costs one
# instruction per name (rs_fn_rank), a callee-saved register in a body or
# for a name a loop does not rank (rs_assign_registers' third round, x64)
# its push and pop besides that
const int rs_fn_min_gain = 2
const int rs_callee_min_gain = 5
# The open loops' records and use-count snapshots (parallel to
# rs_loop_tabs); the delta against the snapshot at the loop's end ranks
# the loop's own candidates.
int[64] rs_lp_open         # record index of each open loop
int[64] rs_lp_snap         # malloc'ed copy of rs_uses at the loop start
int[64] rs_lp_snap_len
int rs_lp_depth            # open loops with a record (mode 1)
int rs_lp_overflow         # more than 64 nested loops: no loop facts
int rs_has_goto            # 'goto' or a label: loops own no registers
# A3 (code_generator/x86.w's expression register stack): the body
# divides, takes a modulo or shifts by a non-literal count, so ecx/edx
# are not parking registers in it; rs_shift_pending holds a seen shift
# operator until its count token says whether the count is a literal.
int rs_has_divshift
int rs_shift_pending
int rs_has_defer           # 'defer': same (every return is an exit edge)
int rs_tok_off             # file offset of the token being read
int rs_expect_range        # 'in' of a for header seen: 'range' or a container
# A1: the previous identifier's candidate index (-1 after a keyword, a
# field name or a literal prefix), captured as rs_decl_index with the
# previous token kind rs_decl_kind when an identifier starts, so a
# declaration can look at its type; the base a '[' follows; the open
# subscripts' bases (the write hazard, rs_write); and whether the
# previous operator run was a prefix '++'/'--'.
int rs_prev_index
int rs_decl_kind
int rs_decl_index
int rs_sub_base
int rs_incdec
int[64] rs_br_base
int[64] rs_br_tokens       # tokens seen inside each open '['
int rs_br_depth
# A2's store hazard (rs_store_line, rs_write): the candidates named on
# the current statement line so far, whether an assignment THROUGH AN
# ADDRESS ('a[i] = ...', 'p.f += ...', '*p = ...') has been seen on it,
# the paren depth that keeps a statement spanning lines together, and
# whether a single '*' (a dereference) precedes the identifier being read.
int[64] rs_line_names
int rs_line_name_count
int rs_line_overflow
int rs_store_line
int rs_paren_depth
int rs_deref_pending

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
		rs_base = new list[int]
		rs_lv = new list[int]
		rs_field = new list[int]
		rs_peek = new list[int]
		rs_fnreg = new list[int]
		rs_fn_cands = new list[int]
		rs_excluded = new list[int]
		rs_reg = new list[int]
		rs_taken = new list[int]
		rs_argsym = new list[int]
		rs_hash = new list[int]
		rs_chain = new list[int]
		regalloc_promoted_syms = new list[int]
		regalloc_promoted_live = new list[int]
		regalloc_promoted_names = new list[char*]
		regalloc_arg_syms = new list[int]
		regalloc_arg_regs = new list[int]
		rs_lp_offset = new list[int]
		rs_lp_flags = new list[int]
		rs_lp_cands = new list[int]
		rs_lp_vals = new list[int]
		rs_lp_ops = new list[int]
		rs_lp_tabs = new list[int]
		rs_lp_inner = new list[int]
		rs_lp_ivneed = new list[int]
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
	rs_base.clear()
	rs_lv.clear()
	rs_field.clear()
	rs_peek.clear()
	rs_fnreg.clear()
	rs_fn_cands.clear()
	rs_excluded.clear()
	rs_reg.clear()
	rs_taken.clear()
	rs_argsym.clear()
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
	rs_lp_vals.clear()
	rs_lp_ops.clear()
	rs_lp_tabs.clear()
	rs_lp_inner.clear()
	rs_lp_ivneed.clear()
	ivopt_reset()
	rs_lp_overflow = 0
	rs_has_goto = 0
	rs_has_defer = 0


# Mark a fact on the innermost open loop (parents inherit it when the
# loop closes).
void rs_lp_mark(int flag):
	if (flag & rs_lp_has_call):
		rs_fn_has_call = 1
		rs_fn_real_call = 1
	if (rs_lp_depth == 0): return;
	int k = rs_lp_open[rs_lp_depth - 1]
	rs_lp_flags[k] = rs_lp_flags[k] | flag


# The count a loop ranks its candidates by: every loop-weighted use on
# x64, where a caller-saved register shortens every read; on x86 only
# the uses a register shortens there (rs_lv: writes, subscript bases and
# one-token indices, a compare's left operand -- a read folded as a
# memory operand, 'cmp R,[esp+d]' or 'imul eax,[esp+d]', costs the same
# from a slot), because the loop's ecx/edx are taken from A3's parks,
# which a read-only candidate would not pay for (A9).
int rs_lp_key(int i):
	if (word_size == 4): return rs_lv[i]
	return rs_uses[i] + rs_gain(i)


# A loop keyword (mode 1): open its record and snapshot the use counts.
void rs_lp_open_loop():
	if (rs_lp_depth >= 64):
		rs_lp_overflow = 1
		return;
	int k = rs_lp_offset.length
	rs_lp_offset.push(rs_tok_off)
	rs_lp_flags.push(0)
	rs_lp_ops.push(0)
	rs_lp_tabs.push(rs_tabs)
	rs_lp_inner.push(0)
	rs_lp_ivneed.push(0)
	if (rs_lp_depth > 0): rs_lp_inner[rs_lp_open[rs_lp_depth - 1]] = 1
	for i in range(rs_lp_stride):
		rs_lp_cands.push(-1)
		rs_lp_vals.push(0)
	rs_lp_ops_snap[rs_lp_depth] = rs_ops
	int* snap = cast(int*, malloc((rs_count + 1) * __word_size__))
	for i in range(rs_count): snap[i] = rs_lp_key(i)
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
		int d = rs_lp_key(i) - before
		if ((d <= 0) || rs_excluded[i] || (rs_decls[i] > 1)): continue
		# insertion into the sorted slots: the delta is recomputed for
		# the slot's occupant (its snapshot entry is still valid here)
		int j = 0
		while (j < rs_lp_stride):
			int c = rs_lp_cands[base + j]
			if (c < 0): break
			int cb = 0
			if (c < snap_len): cb = snap[c]
			if (rs_lp_key(c) - cb < d): break
			j = j + 1
		if (j >= rs_lp_stride): continue
		int m = rs_lp_stride - 1
		while (m > j):
			rs_lp_cands[base + m] = rs_lp_cands[base + m - 1]
			rs_lp_vals[base + m] = rs_lp_vals[base + m - 1]
			m = m - 1
		rs_lp_cands[base + j] = i
		rs_lp_vals[base + j] = d
	rs_lp_ops[k] = rs_ops - rs_lp_ops_snap[rs_lp_depth]
	free(cast(char*, snap))
	# O7 (compiler/ivopt.w): an innermost loop's subscripts that can
	# become pointer walks, read from its bytes (the keyword's offset to
	# the first byte of the line that ended it, or of the end of the body)
	if ((rs_lp_inner[k] == 0) && (word_size == 8) && (rs_abort == 0)):
		int end = rs_cur_offset()
		if (end > 0): rs_lp_ivneed[k] = ivopt_scan_loop(rs_lp_offset[k], end, rs_lp_tabs[k])
		if (rs_lp_ivneed[k] > 0): rs_iv_discount()
	if (rs_lp_depth > 0):
		int parent = rs_lp_open[rs_lp_depth - 1]
		rs_lp_flags[parent] = rs_lp_flags[parent] | rs_lp_flags[k]
		if (rs_lp_ivneed[k] > rs_lp_ivneed[parent]): rs_lp_ivneed[parent] = rs_lp_ivneed[k]


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
	regalloc_arg_syms.clear()
	regalloc_arg_regs.clear()
	regalloc_promoted_count = 0
	regalloc_active = 0
	regalloc_saved_mask = 0
	regalloc_saved_count = 0
	regalloc_pending_mask = 0
	regalloc_function = -1
	regalloc_loops_ok = 0
	reg_lvalue_end = 0
	regalloc_reg_unbind_all()
	ers_hazard = 1
	rl_reset()
	rg_shaped = 0
	rg_resume = 0
	rg_regs_cur = 0
	rg_loaded = 0
	rg_touch = 0
	rg_homes = 0


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
		if ((t < table_pos) && regalloc_promoted_live[i] && (table[t + 1] == 'L')):
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
		if ((t < table_pos) && regalloc_promoted_live[i] && (table[t + 1] == 'L')):
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
	# An empty stream (the closed pipe under an in-memory window,
	# compiler/tokenizer.w) cannot seek; it images as an empty file
	int empty = (saved < 0) && empty_stream_is(file)
	if ((saved < 0) && (empty == 0)): return;
	if (empty == 0):
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
	if (empty == 0): seek(file, saved, 0)
	if (n >= 0): rs_img_ok = 1
	else: rs_img_len = 0
	rs_img[rs_img_len] = 0

# A copy of the bytes offset..end of the file being compiled, with a
# newline appended (compiler/inline_table.w: the body a call site
# re-parses in place). The bytes come from this scan's image of the
# file, or from getchar's window when the image does not hold them (a
# retained source window, a pipe). Returns the length, 0 when they are
# in neither.
int inline_source_copy(int offset, int end, char** out):
	if ((file < 0) || (file >= GETCHAR_MAX_FD)): return 0
	if ((offset < 0) || (end <= offset)): return 0
	int n = end - offset
	char* src = 0
	rs_image_bind()
	if (rs_img_ok && (end <= rs_img_len)): src = &rs_img[offset]
	else:
		int window_start = getchar_kernel_pos[file] - getchar_limit[file]
		if ((offset >= window_start) && (end <= getchar_kernel_pos[file])):
			src = cast(char*, getchar_buf_addr[file]) + (offset - window_start)
	if (src == 0): return 0
	char* text = cast(char*, malloc(n + 2))
	for i in range(n): text[i] = src[i]
	text[n] = 10
	text[n + 1] = 0
	*out = text
	return n + 1


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


# O7: the file offset of rs_c (the end of the file once it is -1), -1
# when no byte is being served.
int rs_cur_offset():
	if ((rs_p == 0) || (rs_run_base == 0)): return -1
	int off = rs_run_off + (cast(int, rs_p) - cast(int, rs_run_base))
	if (rs_c == -1): return off
	return off - 1


# P2: the profile's class, span hash and loop weights read this byte
# source (compiler/regalloc_profile.w; docs §3.4).
import compiler.regalloc_profile


# O7: the innermost loop just closed (rs_lp_depth is its parent's
# depth) has subscripts that become pointer walks (compiler/ivopt.w):
# take back the uses those subscripts counted -- a base's two reads and
# its register-base gain (rs_br_pop, rs_identifier), one read per name
# of the index -- so the enclosing loops and the function do not rank
# names for uses that no longer exist. A ranking heuristic only.
void rs_iv_discount():
	if (rs_profile_weighted): return;
	int depth = rs_lp_depth + 1
	if (depth > 8): depth = 8
	int w = 1 << (3 * depth)
	for q in range(ivopt_inside_names()):
		int nb = ivopt_inside_base(q)
		int ni = ivopt_inside_index(q)
		if ((nb == 0) && (ni == 0)): continue
		int i = rs_lookup(ivopt_inside_name(q))
		if (i < 0): continue
		rs_uses[i] = rs_uses[i] - nb * (w << 1) - ni * w
		rs_base[i] = rs_base[i] - nb * (w << 1)
		rs_lv[i] = rs_lv[i] - nb * w
		if (rs_uses[i] < 0): rs_uses[i] = 0
		if (rs_base[i] < 0): rs_base[i] = 0
		if (rs_lv[i] < 0): rs_lv[i] = 0


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
	rs_base.push(0)
	rs_lv.push(0)
	rs_field.push(0)
	rs_peek.push(0)
	rs_fnreg.push(0)
	rs_excluded.push(0)
	rs_reg.push(0)
	rs_taken.push(0)
	rs_argsym.push(-2)
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


# A declaration of candidate i was recognised (rs_decl_kind / rs_decl_index
# describe the token before the name): count it, and exclude what the
# declared type already rules out, so a name sym_declare would refuse
# anyway (regalloc_type_ok) does not take a register slot in the ranking
# -- an array, slice or container ('T[..] name'), or a type the table
# knows as unpromotable (a struct value, a narrow integer, a float). An
# unknown type name (a generic parameter, say) decides nothing here.
void rs_declare(int i):
	rs_decls[i] = rs_decls[i] + 1
	if (rs_decl_kind == 4): rs_excluded[i] = 1
	elif ((rs_decl_kind == 1) && (rs_decl_index >= 0)):
		int t = type_lookup(rs_names[rs_decl_index])
		if ((t >= 0) && (regalloc_type_ok(t) == 0)): rs_excluded[i] = 1


# Candidate i is written here. Inside a subscript whose base it is
# ('a[a = q]', 'a[++a]'), the register-base fold would read the new
# value where the stack path read the old one: such a name keeps the
# stack.
void rs_write(int i):
	int k = 0
	while (k < rs_br_depth):
		if (rs_br_base[k] == i): rs_excluded[i] = 1
		k = k + 1
	# Written on the right side of a store through an address that
	# named it on its left ('a[i] = (i = i + 1)', 'p.f = (p = q)'): A2's
	# store addresses [base+index*scale+disp] AFTER the right side ran,
	# where the stack path formed the address first, so such a name
	# keeps the stack (the stack path reads it before the write). Every
	# name seen earlier on the line counts, which over-approximates the
	# left side and only ever excludes.
	if (rs_store_line):
		if (rs_line_overflow): rs_excluded[i] = 1
		k = 0
		while (k < rs_line_name_count):
			if (rs_line_names[k] == i): rs_excluded[i] = 1
			k = k + 1


# A statement line starts (or ends): forget its names.
void rs_line_reset():
	rs_line_name_count = 0
	rs_line_overflow = 0
	rs_store_line = 0


void rs_line_name(int i):
	if (rs_line_name_count >= 64):
		rs_line_overflow = 1
		return;
	rs_line_names[rs_line_name_count] = i
	rs_line_name_count = rs_line_name_count + 1


# An operator run that assigns: '=' alone or '...=' other than a
# comparison ('==', '<=', '>=', '!=').
int rs_run_assigns(int n, int first, int second, int last):
	if (n == 1): return first == '='
	if (last != '='): return 0
	if ((n == 2) && ((first == '=') || (first == '<') || (first == '>') || (first == '!'))): return 0
	return 1


# A '[' opened (base: the candidate it follows, -1 none) / a ']' closed.
void rs_br_push(int base):
	if (rs_br_depth >= 64):
		rs_abort = 1
		return;
	rs_br_base[rs_br_depth] = base
	rs_br_tokens[rs_br_depth] = 0
	rs_br_depth = rs_br_depth + 1

# A ']' closes the innermost '[': an index of more than one token
# ('a[i * n + k]') counts as two reads of the base -- on the stack it
# costs the base's slot load and a parked copy around the index, which
# the register-base fold removes; a one-token index ('a[i]') folds into
# the stack path's shuttle already and a register saves nothing but the
# load, so it does not count (nor does a field read): a register taken
# for such uses costs its push and pop per call, or its loop-entry load
# and write-back, for no instruction saved ('__w_list_compare_values'
# ran 4-7% more instructions with sa and sb promoted either way).
void rs_br_pop(int index_ident):
	if (rs_br_depth == 0): return;
	rs_br_depth = rs_br_depth - 1
	int base = rs_br_base[rs_br_depth]
	# the count includes the ']' itself
	if ((base >= 0) && (rs_br_tokens[rs_br_depth] > 2)):
		rs_uses[base] = rs_uses[base] + (rs_weight() << 1)
		rs_base[base] = rs_base[base] + (rs_weight() << 1)
	# a one-token index that is a tracked name ('a[i]'): in a register
	# it is the operand's SIB index, no load into eax (A9's x86 loop
	# ranking)
	if ((rs_br_tokens[rs_br_depth] == 2) && index_ident && (rs_prev_index >= 0)): rs_lv[rs_prev_index] = rs_lv[rs_prev_index] + rs_weight()


# An operator run after an operand (an identifier, a literal, ')' or
# ']'): a binary operator -- not an assignment, not '++'/'--' -- is a
# park site (A3) whose register a loop register would take on x86
# (A9's rs_lp_ops, the loop's operator pressure).
void rs_count_operator(int n, int first, int second, int last):
	if (rs_run_assigns(n, first, second, last)): return;
	if ((n == 2) && (first == second) && ((first == '+') || (first == '-'))): return;
	rs_ops = rs_ops + rs_weight()


# O2: 'name.f' that is not a method call ('name.f(') or an indexed
# container field ('name.f[i]', a hidden call): through a register the
# field's load or store is one '[R+disp]' operand (A2), where the stack
# path loads the pointer first -- one instruction saved on x64, where a
# field access counts as a use of the name (rs_uses) and towards its
# register gain (rs_gain). x86 keeps its A9-tuned model.
void rs_field_use(int i):
	rs_field[i] = rs_field[i] + rs_weight()
	if (word_size == 8): rs_uses[i] = rs_uses[i] + rs_weight()


# Do the bytes after the current token (blanks skipped) spell candidate
# i's name as a whole identifier: 'x = x ...'. A peek, consuming only
# blanks; the end of the window says no.
int rs_peek_name(int i):
	rs_skip_blanks()
	char* name = rs_names[i]
	int n = strlen(name)
	if (n == 0): return 0
	if (rs_c != (name[0] & 255)): return 0
	if (cast(int, rs_end) - cast(int, rs_p) < n): return 0
	int j = 1
	while (j < n):
		if ((rs_p[j - 1] & 255) != (name[j] & 255)): return 0
		j = j + 1
	return (rs_class[rs_p[n - 1] & 255] & rs_cl_part) == 0


# Is the operator run a comparison ('<', '>', '<=', '>=', '==', '!='):
# the name before it is a compare's left operand, which a register
# serves as 'cmp R,X' without the load into eax (A9's x86 loop ranking).
int rs_run_compares(int n, int first, int second, int last):
	if (n == 1): return (first == '<') || (first == '>')
	if ((n == 2) && (last == '=')): return (first == '=') || (first == '<') || (first == '>') || (first == '!')
	return 0


# An operator run after an identifier (the identifier's index is i, -1
# when it is not tracked): classify the run as a compound assignment or
# increment (both read and write the name), a plain
# '=' write, or an ordinary operator. The run is consumed.
void rs_after_ident_operator(int i, int type_context):
	int deref = rs_deref_pending
	rs_deref_pending = 0
	int n = 0
	int first = rs_c
	int second = 0
	int last = 0
	while (rs_is_op_char(rs_c)):
		if (n == 1): second = rs_c
		last = rs_c
		n = n + 1
		rs_next()
	if ((first == '/') || (first == '%')):
		rs_lp_mark(rs_lp_has_divshift)
		rs_has_divshift = 1
	elif ((n >= 2) && (first == second) && ((first == '<') || (first == '>'))): rs_shift_pending = 1
	rs_count_operator(n, first, second, last)
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
	# name: two uses (R3: grammar/increment.w emits 'op R,X' in place).
	# '*name = ...' and '*name += ...' store through the pointer, not
	# into the name: a read, and a store through an address (A2).
	if (deref && ((use == 2) || (use == 3))):
		if (i >= 0): rs_uses[i] = rs_uses[i] + rs_weight()
		rs_store_line = 1
	elif (i >= 0):
		if (use == 0): rs_declare(i)
		else if (use == 3):
			rs_uses[i] = rs_uses[i] + (rs_weight() << 1)
			rs_lv[i] = rs_lv[i] + (rs_weight() << 1)
			rs_write(i)
		else:
			rs_uses[i] = rs_uses[i] + rs_weight()
			if (use == 2):
				# 'x = x op ...' folds into 'op R,...' (R3): worth a
				# compound assignment; a plain store into a register
				# costs what a store into a slot does
				if (rs_peek_name(i)):
					rs_lv[i] = rs_lv[i] + (rs_weight() << 1)
					rs_peek[i] = rs_peek[i] + rs_weight()
				rs_write(i)
			elif (rs_run_compares(n, first, second, last)): rs_lv[i] = rs_lv[i] + rs_weight()
	# '&' alone after an operand is the binary operator
	rs_prev_kind = 0
	# 'T* name' only where a statement, parameter, cast or generic
	# argument may begin; 'a * b' mid-expression is the product (the
	# distinction keeps 'x = i * m' from counting m as a declaration)
	if ((n == 1) && (first == '*') && (rs_ident_type_pos || type_context)): rs_prev_kind = 3


# An identifier (not a field name) has been read into rs_ident.
# 1 when 'name(' is one of the compiler's inline intrinsics (shr, rotl,
# rotr, popcount, clz, ctz, mul_hi, mul_wide, add_carry) and no symbol
# of that name is in scope, so the parsers will lower it without a
# call (unit A8: the loops of lib/sha256.w own registers across their
# rotates). A symbol declared later in the body (a local of that name)
# is a call the emitter spills around, like any other scan miss.
# The intrinsics whose emitter keeps a pointer in ecx from before the
# operand pops to the sequence's end (grammar/limb_builtin.w,
# mov_ecx_eax): a loop owning ecx on x86 must not meet one.
int rs_intrinsic_holds_ecx(char* name):
	if (strcmp(name, c"mul_wide") == 0): return 1
	return strcmp(name, c"add_carry") == 0


int rs_intrinsic_name(char* name):
	int hit = 0
	if (strcmp(name, c"rotr") == 0): hit = 1
	elif (strcmp(name, c"rotl") == 0): hit = 1
	elif (strcmp(name, c"shr") == 0): hit = 1
	elif (strcmp(name, c"popcount") == 0): hit = 1
	elif (strcmp(name, c"clz") == 0): hit = 1
	elif (strcmp(name, c"ctz") == 0): hit = 1
	elif (strcmp(name, c"mul_hi") == 0): hit = 1
	elif (strcmp(name, c"mul_wide") == 0): hit = 1
	elif (strcmp(name, c"add_carry") == 0): hit = 1
	if (hit == 0): return 0
	return sym_probe(name) < 0


void rs_identifier():
	char* name = rs_ident
	int type_context = (rs_prev_kind == 3) || (rs_prev_kind == 4) || ((rs_prev_kind == 1) && (rs_prev_keyword == 0))
	int address_taken = rs_prev_kind == 5
	int written = rs_incdec   # '++name' / '--name'
	rs_incdec = 0
	rs_decl_kind = rs_prev_kind
	rs_decl_index = rs_prev_index
	rs_prev_index = -1
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
	if (rs_mode == 1): i = rs_intern(name, rs_ident_hash)
	if (i >= 0): rs_line_name(i)
	rs_prev_index = i
	rs_prev_kind = 1
	rs_prev_keyword = 0
	rs_skip_blanks()
	int c = rs_c
	# '&name' takes the variable's address: excluded. '&name[i]' and
	# '&name.f' form the element's or the field's address from the
	# pointer's value, which a register serves like any other read.
	if (address_taken && (c != '[') && (c != '.')):
		if (i >= 0): rs_excluded[i] = 1
	if (written && (i >= 0)):
		rs_lv[i] = rs_lv[i] + rs_weight()
		rs_write(i)
	if (rs_for_header):
		# 'for [T] name[, [T] name] in': every identifier of the header
		# is a declaration (the type names over-count, conservatively);
		# the loop stores the variable itself through the register path
		# (R2b), so it stays a candidate -- and the loop writes it every
		# iteration (A9's x86 loop ranking).
		if (i >= 0):
			rs_declare(i)
			rs_lv[i] = rs_lv[i] + rs_weight()
		return;
	if (c == '('):
		if (i >= 0): rs_excluded[i] = 1
		# A call to a function whose body inlines without a call of its
		# own (unit A5) leaves no call instruction in this loop; neither
		# does a bit or limb intrinsic (grammar/bit_builtin.w,
		# grammar/limb_builtin.w), which lowers inline unless a symbol
		# of its name shadows it (the same rule the parsers apply)
		if (rs_intrinsic_name(name)):
			# ... but mul_wide and add_carry hold their pointer in ecx
			# across the pops that follow (mov_ecx_eax), which no
			# bracket can spill around: no loop register there on x86
			# (A9). The other intrinsics write ecx (a variable count)
			# or edx (the temporaries, the high half) inside a bracket
			# that parks an owned register (rl_hazard_begin/_end), and
			# a constant count never reaches ecx (alu_bit_shuttle_imm),
			# so the rotate idiom of lib/sha256.w keeps its loop.
			if (rs_intrinsic_holds_ecx(name)): rs_lp_mark(rs_lp_has_divshift)
		elif ((rs_lp_depth != 0) && (inline_name_is_leaf(name) == 0)): rs_lp_mark(rs_lp_has_call)
		else:
			# only rg_shape_rank reads it: x64 alone pays the lookup
			if ((rs_fn_real_call == 0) && (word_size == 8)):
				if (inline_name_is_leaf(name) == 0): rs_fn_real_call = 1
		return;
	if (c == '['):
		# a subscript base (A1): a read a register makes no shorter
		# unless the index has more than one token, which rs_scan_body's
		# ']' counts (rs_br_pop); its '[' records the base for rs_write.
		# With A2's addressing forms a register base is the operand's
		# base register, one slot load less per subscript (A9's x86
		# loop ranking counts every subscript).
		rs_sub_base = i
		if (i >= 0): rs_lv[i] = rs_lv[i] + rs_weight()
		return;
	if (c == '.'):
		# a field access or a method call's receiver (A1); the field
		# name decides which (rs_scan_body's field branch, rs_field)
		rs_field_owner = i
		return;
	if (c == ':'):
		rs_next()
		rs_prev_kind = 0
		rs_type_pos = 1
		if (rs_c == '='):
			rs_next()
			if (i >= 0): rs_declare(i)
		elif (rs_at_start && (type_context == 0)): rs_has_goto = 1   # 'name:' is a label
		return;
	if (rs_is_op_char(c)):
		rs_after_ident_operator(i, type_context)
		return;
	# end of line, ',', ')', ']', ';', '}' ...: a read, or 'T name' alone
	if (i >= 0):
		if (type_context && ((c == 10) || (c == ';') || (c == -1) || (c == '#'))): rs_declare(i)
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
	rs_prev_index = -1
	rs_sub_base = -1
	rs_incdec = 0
	rs_br_depth = 0
	rs_line_reset()
	rs_paren_depth = 0
	rs_deref_pending = 0
	rs_has_divshift = 0
	rs_shift_pending = 0
	rs_ops = 0
	rs_fn_has_call = 0
	rs_fn_real_call = 0
	rs_field_owner = -1
	int first = 1
	while ((rs_done == 0) && (rs_abort == 0) && (rs_c != -1)):
		if ((rs_mode == 0) && rs_has_loop): return;
		if (rs_c == 10):
			if (rs_same_line && (rs_depth == 0)): return;
			rs_newline()
			rs_prev_kind = 0
			rs_deref_pending = 0
			if ((rs_paren_depth == 0) && (rs_br_depth == 0)): rs_line_reset()
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
			rs_has_divshift = 1
			rs_ops = rs_ops + rs_weight()
			rs_prev_kind = 0
			continue
		# a token starts here
		int owner = rs_field_owner
		rs_field_owner = -1
		if (rs_shift_pending):
			# the count of the shift just seen: a literal keeps the shift
			# out of ecx (shift_imm_fold), anything else goes through cl
			# -- for the function (A3's parks) and for the loop (A9's
			# loop registers; a fold that fails spills around the shift)
			if ((rs_c < '0') || (rs_c > '9')):
				rs_has_divshift = 1
				rs_lp_mark(rs_lp_has_divshift)
			rs_shift_pending = 0
		if (rs_br_depth > 0): rs_br_tokens[rs_br_depth - 1] = rs_br_tokens[rs_br_depth - 1] + 1
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
				rs_prev_index = -1
				rs_incdec = 0
				rs_deref_pending = 0
				rs_skip_blanks()
				if (rs_c == '('): rs_lp_mark(rs_lp_has_call)
				elif (rs_c == '['):
					# a container field indexed is a hidden call; a pointer
					# field indexed is not, and which it is the scan cannot
					# tell: the loop declines it, the function region (O2)
					# takes the chance (a call spills its registers)
					int had_call = rs_fn_has_call
					int had_real = rs_fn_real_call
					rs_lp_mark(rs_lp_has_call)
					rs_fn_has_call = had_call
					rs_fn_real_call = had_real
					if (owner >= 0): rs_field_use(owner)
				elif (owner >= 0): rs_field_use(owner)
			else: rs_identifier()
			continue
		rs_type_pos = 0
		rs_incdec = 0
		rs_deref_pending = 0
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
			if (rs_paren_depth > 0): rs_paren_depth = rs_paren_depth - 1
			continue
		if (c == ']'):
			rs_next()
			int index_ident = rs_prev_kind == 1
			rs_prev_kind = 4
			rs_br_pop(index_ident)
			continue
		if (c == '.'):
			rs_next()
			rs_prev_kind = 6
			rs_field_owner = owner
			continue
		if (rs_is_op_char(c)):
			int n = 0
			int firstc = c
			int before = rs_prev_kind
			int secondc = 0
			int lastc = 0
			while (rs_is_op_char(rs_c)):
				if (n == 1): secondc = rs_c
				lastc = rs_c
				n = n + 1
				rs_next()
			rs_prev_kind = 0
			if (firstc == '%'):
				rs_lp_mark(rs_lp_has_divshift)
				rs_has_divshift = 1
			elif ((n >= 2) && (firstc == secondc) && ((firstc == '<') || (firstc == '>'))): rs_shift_pending = 1
			if ((before == 2) || (before == 4)): rs_count_operator(n, firstc, secondc, lastc)
			# a prefix '++'/'--': the identifier it precedes is written
			if ((n == 2) && (firstc == secondc) && ((firstc == '+') || (firstc == '-'))): rs_incdec = 1
			# an assignment after ']' or an operand end ('a[i] =',
			# 'p.f +=', '(*p).f ='): a store through an address (A2)
			if (((before == 2) || (before == 4)) && rs_run_assigns(n, firstc, secondc, lastc)): rs_store_line = 1
			if ((n == 1) && (firstc == '&')):
				# '&' not after an operand: address-of
				if (before != 2): rs_prev_kind = 5
				# '&(' parenthesised address-of: cannot tell the name
				rs_skip_blanks()
				if ((rs_prev_kind == 5) && (rs_c == '(')): rs_abort = 1
			else if ((n == 1) && (firstc == '*')):
				# 'T* name' after a type; '*p' at an operator is a deref
				if ((before == 1) || (before == 3)): rs_prev_kind = 3
				else: rs_deref_pending = 1
			continue
		# '(' '[' ',' ';' ':' '?' '@' and anything else; '(' right after
		# an operand ('f(x)(y)', 'table[i](x)') is a call
		if ((c == '(') && ((rs_prev_kind == 2) || (rs_prev_kind == 4))): rs_lp_mark(rs_lp_has_call)
		if ((c == '(') && rs_expect_range):
			rs_expect_range = 0
			rs_lp_mark(rs_lp_has_call)
		if ((c == '(') || (c == '[') || (c == ',') || (c == ';') || (c == ':')): rs_type_pos = 1
		if (c == '('): rs_paren_depth = rs_paren_depth + 1
		if (c == '['):
			# the subscript's base, for the write hazard (rs_write):
			# the identifier directly before it, or nothing ('f()[i]',
			# 'a[i][j]', 'p.f[i]', a type's '[')
			rs_br_push(rs_sub_base)
			rs_sub_base = -1
		rs_next()
		rs_prev_kind = 0


# A name the body never declares: the record of this function's
# parameter of that name when it is one a register can hold (A1), else
# -1. Probed once per candidate, and only for names the ranking reaches.
int rs_arg_record(int i):
	if (rs_argsym[i] == -2):
		rs_argsym[i] = -1
		int t = sym_probe(rs_names[i])
		if ((t >= 0) && (table[t + 1] == 'A')):
			if (regalloc_type_ok(load_int(table + t + 6))): rs_argsym[i] = t
	return rs_argsym[i]


# Arguments rank at function level on x64 only (the second round of
# rs_assign_registers): x86's two registers stay with the body's
# scalars, where an argument read is already one folded memory operand
# ('imul eax,[esp+d]', 'cmp eax,[esp+d]'). The loop pass ranks them on
# both widths; on x86 by the per-use model of rs_lp_key (A9), which is
# where a pointer argument used as a base takes ecx/edx.
int rs_args_rank():
	return word_size == 8


# Rank the candidates and assign registers; returns the mask to push.
# A local candidate takes its register at its declaration
# (regalloc_declare); an argument's goes to regalloc_arg_syms for the
# prologue (regalloc_prologue_args).
#
# Two rounds (A1): the body's locals ranked by their scalar uses first
# (rs_uses less rs_base) -- exactly the pre-A1 ranking, which excluded
# every subscripted or field-accessed name -- then, for the registers
# those leave, the bases ranked by their multi-token-index subscripts
# (rs_base): locals, and on x64 arguments (rs_args_rank). A base never
# displaces a scalar: a scalar that loses its register pays a parked
# address and a store on every write ('sieve' on x64 ran 0.4% more
# instructions with 'composite' in r14 and 'h' on the stack; 'matmul'
# on x86 10% more with n in edi and acc on the stack). The loop pass
# (rs_lp_close_loop) ranks every candidate by rs_uses, so there a base
# with multi-token subscripts competes with the scalars for the
# caller-saved registers, weighted by those subscripts.
int rs_assign_registers():
	int budget = 2
	int first_reg = 6   # esi, edi
	if (word_size == 8):
		budget = 4
		first_reg = 12  # r12-r15
	int mask = 0
	int assigned = 0
	int round = 0
	# a loop-free body (scanned whole on x64) has no loop names to rank
	if ((rs_has_loop == 0) && rs_fn_target_ok()): round = 2
	while (assigned < budget):
		int best = -1
		int best_uses = 7   # at least one use inside a loop (weight 8)
		if (round == 2): best_uses = rs_callee_min_gain - 1
		for i in range(rs_count):
			if ((rs_reg[i] != 0) || rs_excluded[i] || rs_fnreg[i]): continue
			if (round == 2):
				if (rs_gain(i) <= best_uses): continue
				if (rs_decls[i] != 1):
					if (rs_decls[i] != 0): continue
					if (rs_arg_record(i) < 0): continue
				best = i
				best_uses = rs_gain(i)
			elif (round == 0):
				if ((rs_decls[i] != 1) || (rs_uses[i] - rs_base[i] <= 7)): continue
				# x64 (O2): ranked by the scalar uses plus the register gain
				int key = rs_uses[i] - rs_base[i]
				if (word_size == 8): key = key + rs_gain(i)
				if (key <= best_uses): continue
				best = i
				best_uses = key
			else:
				if (rs_base[i] <= best_uses): continue
				if (rs_decls[i] == 1): best = i
				elif ((rs_decls[i] == 0) && rs_args_rank() && (rs_arg_record(i) >= 0)): best = i
				else: continue
				best_uses = rs_base[i]
		if (best < 0):
			if (round == 2): break
			if (round == 1):
				if (rs_fn_target_ok() == 0): break
			round = round + 1
			continue
		int r = first_reg + assigned
		rs_reg[best] = r
		mask = mask | (1 << r)
		assigned = assigned + 1
		if (rs_decls[best] == 0):
			rs_taken[best] = 1
			regalloc_arg_syms.push(rs_argsym[best])
			regalloc_arg_regs.push(r)
	return mask


# --- the function region (O2) ----------------------------------------------
# A body the scan saw whole that makes no call it can see (a leaf: no
# call, method call, 'new', container iteration or membership test,
# and no goto/labels or defer) keeps its best names in the caller-saved
# registers the loops use (x64: rsi rdi r8-r11) for the whole body, at
# no prologue or epilogue cost: an argument is loaded from its stack
# word right after the prologue, a local takes its register at its
# declaration (class 'B' of the loop machinery below), and nothing is
# written back, since every register is dead at a return. The region is
# the loop machinery's outermost level (rl_fn_region_enter): a call the
# body emits after all (a container subscript, an operator overload, a
# bounds trap) spills the live entries to their homes and reloads them
# (regalloc_call_spill / _reload), exactly as inside a loop, so a scan
# miss costs instructions, never correctness. Loops inside the body take
# the registers the region leaves.
#
# The ranking key is a name's register gain (rs_gain): the uses a
# register makes shorter on x64 -- writes folded into 'op R,X',
# compound assignments and '++', compare left sides, subscript bases and
# one-token indices (rs_lv), and field accesses through the name as a
# base (rs_field) -- loop-weighted. 'x = x op ...' counts half of what
# rs_lv gives it: it folds to 'op R,...' only when the right side is
# simple, which the scan does not look at. A plain read costs one
# instruction either way ('mov rax,[rbp+d]' or 'mov rax,R'). The
# region's own cost is one instruction per name (the argument's load,
# or the local's copy of its initial value), so a name needs a gain of
# rs_fn_min_gain. The x64 loop ranking (rs_lp_key) and the callee-saved
# ranking (rs_assign_registers) add the gain to the use count too.

int rs_gain(int i):
	return rs_lv[i] - rs_peek[i] + rs_field[i]


# Only x64 has a region: x86's caller-saved pair is the expression
# stack's whole park set (A3, A9).
int rs_fn_target_ok():
	if (word_size != 8): return 0
	return rl_target_mask() != 0


# Pick the region's names (rs_fn_cands, best first) from the scan's
# candidates: declared exactly once in the body, or a promotable argument.
void rs_fn_rank():
	rs_fn_cands.clear()
	if (rs_fn_target_ok() == 0): return;
	if (rs_fn_has_call): return;
	int budget = 0
	int mask = rl_target_mask()
	for r in range(16):
		if (mask & (1 << r)): budget = budget + 1
	# O7: the loops' pointer walks keep theirs (compiler/ivopt.w)
	int ivneed = 0
	for k in range(rs_lp_ivneed.length):
		if ((rs_lp_inner[k] == 0) && (rs_lp_ivneed[k] > ivneed)): ivneed = rs_lp_ivneed[k]
	budget = budget - ivneed
	while (rs_fn_cands.length < budget):
		int best = -1
		int best_gain = rs_fn_min_gain - 1
		for i in range(rs_count):
			if (rs_fnreg[i] || rs_excluded[i]): continue
			if (rs_decls[i] != 1):
				if (rs_decls[i] != 0): continue
				if (rs_arg_record(i) < 0): continue
			int g = rs_gain(i)
			if (g <= best_gain): continue
			best = i
			best_gain = g
		if (best < 0): break
		rs_fnreg[best] = 1
		rs_fn_cands.push(best)
	rg_shape_rank()   # O5


# The prologue has pushed what it saves and loaded the callee-saved
# arguments (x86.w's regalloc_prologue_emit): open the function region,
# load its arguments into their registers and leave its locals pending
# their declarations, with a register reserved for each.
void debug_local_set_register_named(char* name, int reg);
void regalloc_fn_region_enter():
	if (rs_fn_cands == 0): return;
	if (rs_fn_cands.length == 0): return;
	if (regalloc_active == 0): return;
	rl_ensure()
	rl_mark.push(rl_sym.length)
	rl_pending_mark.push(rl_pending.length)
	rl_eligible.push(1)
	rl_fn_region = 1
	rl_free_mask = rl_target_mask()
	int pending = 0
	for j in range(rs_fn_cands.length):
		int i = rs_fn_cands[j]
		if (rs_decls[i] == 1):
			rl_pending.push(i)
			pending = pending + 1
			continue
		int t = rs_argsym[i]
		if ((t < 0) || (load_int(table + t + 146) != 0)): continue
		int reg = rl_take_register()
		if (reg == 0): continue
		save_int(table + t + 146, reg)
		int slot = load_int(table + t + 2)
		# a register-shaped body with homes (O5): the parameter's home
		# is its frame word below the saved registers ('P'), not the
		# word above the return address
		if (rg_homes): rl_add(t, reg, slot - 1, 'P', rs_names[i], 1)
		else: rl_add(t, reg, slot, 'A', rs_names[i], 1)
		# the argument's word, read once here (rl_home_disp would count
		# it as a body touch, O5)
		mov_reg_ebp_disp(reg, (number_of_args - slot + 2) << word_size_log2)
		debug_local_set_register_named(rs_names[i], reg)
		regalloc_fn_regs = regalloc_fn_regs + 1
		if (rg_shaped): rg_note_param(slot - 1, reg)
	# O5: a register entry resumes here, past the argument loads
	if (rg_shaped): rg_resume = codepos
	rl_fn_pending_end = rl_pending.length
	rl_fn_reserved = pending


# Called by function_definition (grammar/program.w) with the current
# token at the body's '{' or ':', right before the prologue. symbol is
# the function's record; variadic functions promote nothing.
void regalloc_function_scan(int symbol, int is_variadic):
	rs_tables_ensure()
	rs_class_ensure()
	regalloc_function_end()
	rg_symbol = symbol
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
	# O2: on x64 every body is ranked (loop-free ones too, rs_fn_rank
	# and rs_assign_registers), so there is no probe for a loop
	if (word_size == 8): rs_mode = 1
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
	# The expression register stack (A3) may park in ecx/edx only when
	# a full pass saw the whole body and nothing in it writes them. A
	# body the line probe finished without a loop stays hazardous: the
	# probe sees line-leading tokens only, and --ast-emit-retained
	# (whose instantiations the probe cannot serve, rs_image_bind) must
	# reach the same verdict from the full pass as streaming does here.
	if ((rs_mode == 1) && (rs_abort == 0) && (rs_has_divshift == 0)): ers_hazard = 0
	# Loops own caller-saved registers (R3) only when no jump can leave a
	# loop body other than through its exit region: no goto/labels, no
	# defer (every return would be an exit edge), and the scan saw every
	# loop. The function region (O2) asks the same of the whole body.
	int body_ok = 0
	if ((rs_abort == 0) && (rs_has_goto == 0) && (rs_has_defer == 0) && (rs_lp_overflow == 0)): body_ok = 1
	if ((rs_mode == 1) && (rs_abort == 0)):
		regalloc_scanned_functions = regalloc_scanned_functions + 1
		if (body_ok): rs_fn_rank()
		mask = rs_assign_registers()
		if (mask == 0): rs_profile_fruitless = rs_profile_fruitless + 1   # P2: --stats
	int loops = 0
	if (body_ok && ((rs_lp_offset.length > 0) || (rs_fn_cands.length > 0))): loops = 1
	if ((mask == 0) && (loops == 0)):
		rs_tables_clear()
		return;
	regalloc_pending_mask = mask
	regalloc_function = symbol
	regalloc_loops_ok = loops


# Is a declared type one a register can hold: the word-sized 'int', a
# pointer (not an array, not const), or -- unit A8,
# docs/projects/codegen_gap_plan.md §2.7 -- a 32-bit integer
# ('int32'/'uint32'): the word itself on x86, a narrow value on x64
# that the register keeps extended as the memory path's load would
# (regalloc_reg_kind_of_type below, x86.w's writers). --no-narrow-regs
# keeps the narrow types on the stack.
int regalloc_type_ok(int type):
	if (type_is_const(type)): return 0
	if (type_is_array(type)): return 0
	if (type_get_pointer_level(type) > 0): return 1
	if (type_stack_words(type) != 1): return 0
	int canonical = type_canonical(type)
	if (type_get_size(type) == 4):
		if (narrow_regs_disabled): return 0
		if (canonical == uint32_type): return 1
		if (canonical == type_lookup(c"int32")): return 1
	if (type_get_size(type) != word_size): return 0
	return canonical == type_lookup(c"int")


# The value kind a register bound to a symbol of this type holds
# (x86.w's regalloc_reg_kind): 1 a uint32, 2 an int32, 0 the word.
# Only x64 has narrow registers; on x86 the 32-bit types are the word.
int regalloc_reg_kind_of_type(int type):
	if (word_size != 8): return 0
	if (type_get_pointer_level(type) > 0): return 0
	if (type_get_size(type) != 4): return 0
	int canonical = type_canonical(type)
	if (canonical == uint32_type): return 1
	if (canonical == type_lookup(c"int32")): return 2
	return 0


# sym_declare's hook for a new local 'name' (record t, declared type):
# returns the register it lives in, 0 for the stack. The candidate's
# register goes to its first declaration in the function; anything the
# scan did not see as that one declaration (a shadow in a sibling
# block, a loop variable) keeps the stack.
int regalloc_declare(int t, char* name, int type):
	if (regalloc_active == 0): return 0
	if (target_isa != 0): return 0
	# The locals of a body inlined at a call site (unit A5) are not in
	# the scan: plain stack slots, whatever their names
	if (inline_depth != 0): return 0
	int i = rs_lookup(name)
	if (i < 0): return 0
	if ((rs_reg[i] == 0) || rs_taken[i]): return rl_declare_pending(t, name, type)
	if (regalloc_type_ok(type) == 0): return 0
	rs_taken[i] = 1
	save_int(table + t + 146, rs_reg[i])
	regalloc_reg_bind(rs_reg[i], regalloc_reg_kind_of_type(type))
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


# The prologue pushed the function's registers (x86.w's
# regalloc_prologue_emit): load each promoted argument (A1) from its stack
# word, '[ebp+W*(nargs-index+2)]' (the frame-pointer home R3's loop
# registers use too), mark its record so sym_emit_value notes the
# register, and keep it on the promoted list for the guard. Its wdbg/
# DWARF note (recorded at the parameter's declaration) gets the register
# as a local's would.
void regalloc_prologue_args():
	if (regalloc_arg_syms == 0): return;
	# O5: a callee-saved argument's load is not skipped by a register
	# entry (rg_resume follows the region's loads only)
	if (regalloc_arg_syms.length > 0): rg_touch = rg_touch + 1
	for i in range(regalloc_arg_syms.length):
		int t = regalloc_arg_syms[i]
		int reg = regalloc_arg_regs[i]
		save_int(table + t + 146, reg)
		# a narrow argument (A8) loads its word's low half, extended
		regalloc_reg_bind(reg, regalloc_reg_kind_of_type(load_int(table + t + 6)))
		mov_reg_ebp_disp(reg, (number_of_args - load_int(table + t + 2) + 2) << word_size_log2)
		char* name = sym_record_name(t)
		regalloc_promoted_syms.push(t)
		regalloc_promoted_live.push(1)
		regalloc_promoted_names.push(strclone(name))
		regalloc_promoted_count = regalloc_promoted_count + 1
		regalloc_promoted_args = regalloc_promoted_args + 1
		debug_local_set_register_named(name, reg)
	regalloc_arg_syms.clear()
	regalloc_arg_regs.clear()


# --- loop-scoped registers (R3, §2.3; x86 since A9) ------------------------
# In a loop the scan found call-free, locals the function-scoped ranking
# left on the stack (and the function's arguments, and the range loop's
# hidden end/step slots) live in caller-saved registers for the loop's
# extent: x64 rsi rdi r8-r11; x86 ecx edx (unit A9,
# docs/projects/codegen_gap_plan.md §2.7) in a loop whose body never
# shifts by a variable, divides or takes a modulo, for the candidates
# whose uses a register shortens there outweigh the expression parks
# (A3) the register is taken from (rs_lp_key, regalloc_loop_enter). An
# emitter that writes ecx/edx inside such a loop after all parks the
# owned register in its home around the sequence (regalloc_hazard_spill
# / _reload). The loop head (loop_enter in
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
	regalloc_loop_owned = 0
	rl_fn_region = 0
	rl_fn_pending_end = 0
	rl_fn_reserved = 0
	ivopt_active_reset()


# The caller-saved registers a loop may own on this target: x64 rsi rdi
# r8-r11; x86 ecx/edx (A9, docs/projects/codegen_gap_plan.md §2.7) in a
# loop the scan found free of the sequences that write them -- the
# shift count and the division's high half (rs_lp_has_divshift, checked
# in regalloc_loop_enter) -- unless --no-x86-budget.
# x86 (A9): a loop candidate's value (rs_lp_vals: the loop-weighted
# count of its uses a register shortens) times this must reach the
# loop's operator count (rs_lp_ops, the park sites) for the first and
# the second register taken from the parks.
const int rl_x86_ratio_first = 8
const int rl_x86_ratio_second = 8

int rl_target_mask():
	if (target_isa != 0): return 0
	if (target_os != 0): return 0
	if (word_size != 8):
		if (x86_budget_disabled): return 0
		return (1 << 1) | (1 << 2)
	return (1 << 6) | (1 << 7) | (1 << 8) | (1 << 9) | (1 << 10) | (1 << 11)


# Registers no open loop owns and no expression park holds.
int rl_free_count():
	int free = 0
	int q = 0
	while (q < 16):
		if ((rl_free_mask & (1 << q)) && ((ers_used & (1 << q)) == 0)): free = free + 1
		q = q + 1
	return free


int rl_take_register():
	# the function region's locals not declared yet keep their registers
	# (O2): a loop, a hidden slot or a loop's own local takes one only
	# when more are free
	if (rl_fn_reserved > 0):
		int free = 0
		int q = 0
		while (q < 16):
			if ((rl_free_mask & (1 << q)) && ((ers_used & (1 << q)) == 0)): free = free + 1
			q = q + 1
		if (free <= rl_fn_reserved): return 0
	int r = 0
	while (r < 16):
		# never a register with an expression park in it (A3): a
		# declaration inside a loop body takes its register while the
		# statement's parks may be live
		if ((rl_free_mask & (1 << r)) && ((ers_used & (1 << r)) == 0)):
			rl_free_mask = rl_free_mask & ~(1 << r)
			return r
		r = r + 1
	return 0


# The frame-pointer displacement of an entry's home.
int rl_home_disp(int i):
	int kind = rl_kind[i]
	if (kind == 'A'):
		rg_touch = rg_touch + 1   # O5: the argument's word is its home
		return (number_of_args - rl_slot[i] + 2) << word_size_log2
	if (kind == 'P'): return 0 - ((regalloc_saved_count + 1 + rl_slot[i]) << word_size_log2)
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
	# the register's value kind (A8): a narrow symbol's register loads,
	# stores and operates at 32 bits for the loop's extent
	int value_kind = 0
	if (t >= 0): value_kind = regalloc_reg_kind_of_type(load_int(table + t + 6))
	regalloc_reg_bind(reg, value_kind)
	rl_sym.push(t)
	rl_reg.push(reg)
	rl_slot.push(slot)
	rl_kind.push(kind)
	rl_live.push(live)
	rl_name.push(strclone(name))
	regalloc_loop_owned = regalloc_loop_owned | (1 << reg)
	regalloc_loop_regs = regalloc_loop_regs + 1


# A loop statement begins, before its loop region: offset is the file
# offset of its keyword (grammar/statement.w's loop_stmt_offset). Loads
# the loop's candidates into free caller-saved registers.
void regalloc_loop_enter(int offset):
	inline_loop_count = inline_loop_count + 1
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
	# x86: a body that shifts by a variable, divides or takes a modulo
	# (in this loop or a nested one: the bit is inherited upward) writes
	# ecx/edx; the emitters spill a loop register around such a
	# sequence anyway (regalloc_hazard_spill), so this is the ranking's
	# choice, not a correctness rule
	if ((word_size == 4) && (flags & rs_lp_has_divshift)): return;
	if ((regalloc_loop_depth == 1) && (rl_fn_region == 0)): rl_free_mask = rl_target_mask()
	int last_open = rl_eligible.length - 1
	rl_eligible[last_open] = 1
	regalloc_loops_owned = regalloc_loops_owned + 1
	int base = k * rs_lp_stride
	int ops = rs_lp_ops[k]
	int taken = 0
	# O7 (compiler/ivopt.w): an innermost loop's pointer walks take
	# their registers first; an enclosing loop leaves as many free as
	# the innermost loops in it will want
	int reserve = 0
	if (rs_lp_inner[k] == 0): ivopt_loop_enter(offset)
	else: reserve = rs_lp_ivneed[k]
	for j in range(rs_lp_stride):
		if (rl_free_mask == 0): return;
		if ((reserve > 0) && (rl_free_count() - rl_fn_reserved <= reserve)): return;
		int i = rs_lp_cands[base + j]
		if (i < 0): return;
		# x86: the register comes out of A3's park set, where it saves
		# about one instruction per park the loop body makes; the
		# candidate must be worth more than the parks it displaces
		# (rs_lp_vals against the loop's operator count), and the
		# second register is dearer than the first (the parks then
		# have none). The candidates are sorted, so the first one that
		# fails ends it.
		if (word_size == 4):
			int ratio = rl_x86_ratio_first
			if (taken): ratio = rl_x86_ratio_second
			if (rs_lp_vals[base + j] * ratio < ops): return;
		if (rs_excluded[i] || (rs_reg[i] != 0) || (rs_decls[i] > 1) || rs_fnreg[i]): continue
		char* name = rs_names[i]
		if (ivopt_covers(name)): continue
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
		taken = taken + 1
		save_int(table + t + 146, reg)
		rl_add(t, reg, load_int(table + t + 2), scope, name, 1)
		mov_reg_ebp_disp(reg, rl_home_disp(rl_sym.length - 1))


# A range loop's hidden end or step word (its slot, as the for statement
# numbers it): a free register of the innermost loop, loaded here, or 0.
int regalloc_loop_hidden(int slot):
	if (rl_eligible == 0): return 0
	if (rl_eligible.length == 0): return 0
	if (rl_eligible[rl_eligible.length - 1] == 0): return 0
	# x86: the end and step words are only ever the right operand of a
	# compare or an add, folded as memory operands; a register saves
	# nothing there and is better left to a candidate (A9)
	if (word_size == 4): return 0
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
	ivopt_loop_leave()
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
		regalloc_reg_bind(rl_reg[i], 0)
		regalloc_loop_owned = regalloc_loop_owned & ~(1 << rl_reg[i])
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
	if ((regalloc_loop_depth == 0) && (rl_fn_region == 0)): rl_free_mask = 0


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
		if (k < rl_fn_pending_end):
			# the function region's (O2): its reservation is this one's
			if (rl_fn_reserved > 0): rl_fn_reserved = rl_fn_reserved - 1
		elif (rl_eligible[rl_eligible.length - 1] == 0): return 0
		if (regalloc_type_ok(type) == 0): return 0
		int reg = rl_take_register()
		if (reg == 0): return 0
		rl_add(t, reg, load_int(table + t + 2), 'B', name, 0)
		save_int(table + t + 146, reg)
		if (k < rl_fn_pending_end): regalloc_fn_regs = regalloc_fn_regs + 1
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
	ivopt_call_reload()


# An emitter is about to write the registers of mask (x86: ecx as a
# shift count, edx as a division's high half, the limb and bit
# intrinsics' temporaries) while a loop owns one of them (A9): park
# that register in its home before the sequence and fetch it back
# after. The scan declines loops whose body spells such an operator
# (rs_lp_has_divshift), so this is the fallback for what it cannot
# see -- a shift-by-constant whose fold fails, an inlined body (unit
# A5) -- and, like the call spill, costs instructions, never
# correctness. --stats counts the spills.
int regalloc_hazard_spills
void regalloc_hazard_spill(int mask):
	if (rl_sym == 0): return;
	if ((regalloc_loop_owned & mask) == 0): return;
	for i in range(rl_sym.length):
		if ((mask & (1 << rl_reg[i])) && rl_entry_live(i)):
			regalloc_hazard_spills = regalloc_hazard_spills + 1
			if (rl_kind[i] != 'H'): mov_ebp_disp_reg(rl_reg[i], rl_home_disp(i))

# An emitter whose ecx lives across grammar-emitted operands (the limb
# intrinsics' pointer, the atomic cas) cannot bracket the register: the
# scan counts those intrinsics as calls, so a loop never owns ecx across
# one, and this is the fail-closed check of that.
void regalloc_hazard_assert(int mask):
	if (rl_sym == 0): return;
	if ((regalloc_loop_owned & mask) == 0): return;
	for i in range(rl_sym.length):
		if ((mask & (1 << rl_reg[i])) && rl_entry_live(i)): error3(c"internal error: loop register of '", rl_name[i], c"' clobbered by an intrinsic (compile with --no-regs and report this)")

void regalloc_hazard_reload(int mask):
	if (rl_sym == 0): return;
	if ((regalloc_loop_owned & mask) == 0): return;
	for i in range(rl_sym.length):
		if ((mask & (1 << rl_reg[i])) && rl_entry_live(i)): mov_reg_ebp_disp(rl_reg[i], rl_home_disp(i))


# The loop entry whose storage word is stack slot 'slot' (see
# regalloc_slot_register), -1 when none.
int rl_find_slot(int slot):
	if (rl_sym == 0): return -1
	for i in range(rl_sym.length):
		int kind = rl_kind[i]
		if (((kind == 'L') || (kind == 'B')) && (rl_slot[i] == slot) && rl_entry_live(i)): return i
	return -1


# --- register arguments (O5) ------------------------------------------------
# A direct call (A4) to a W function on x64 passes its arguments in
# registers when the callee published a register entry; every other
# call -- through a pointer, a forward reference, from asm or the FFI,
# with the entry not yet published (a self call) -- keeps the stack ABI
# through the function's own address, which is unchanged. The scheme is
# callee-side and single-pass sound:
#
# - A body may get an entry when it is "register-shaped" (rg_shape_ok:
#   1 to 6 word-sized, non-narrow, non-const parameters, no aggregate
#   return, not variadic/a generator/a kernel/an asm body) and the
#   function region (O2) holds every parameter (rg_shape_rank), so each
#   has a caller-saved register (rsi rdi r8-r11) loaded right after the
#   prologue.
# - The entry is published only once the body is complete
#   (regargs_close, from be_function_epilogue) and only if nothing in it
#   read or wrote an argument's stack word: rg_touch counts every such
#   access (sym_emit_value's 'A' path, the AST emitter's bindings,
#   rl_home_disp for a spill/reload or a loop's home, a callee-saved
#   argument's load). Its register callers push no argument words, so
#   that is the whole correctness condition; the region keeps each
#   parameter in its register for the body's extent.
# - The entry itself is a stub after the body: 'push rbp; mov rbp,rsp',
#   the prologue's register pushes, and a jump to rg_resume, the point
#   past the region's argument loads. The frame it builds is the
#   prologue's, so the body, its returns and the debugger see the same
#   frame either way; only the argument words above the return address
#   are missing, and nothing reads them.
#
# Callers (grammar/stack_slot.w, regcall_*) park each argument straight
# into its parameter's register (an expression park, A3), so a simple
# argument costs one instruction and there is no 'add rsp' after the
# call.
int rg_enabled():
	if (reg_args_disabled || direct_calls_disabled || regalloc_disabled): return 0
	if ((target_isa != 0) || (target_os != 0) || (word_size != 8)): return 0
	if (repl_call_site_hook != 0): return 0
	return 1


int rg_shape_ok(int symbol):
	if (rg_enabled() == 0): return 0
	if (rg_asm_body || (symbol < 0)): return 0
	if (sym_is_generator(symbol) || sym_is_kernel(symbol)): return 0
	if (load_int(table + symbol + 130) != -1): return 0   # a W variadic
	int n = load_int(table + symbol + 22)
	if ((n < 1) || (n > 6)): return 0
	# one word per parameter, and no hidden return-buffer word
	if (number_of_args != n): return 0
	for i in range(n):
		int type = load_int(table + symbol + 26 + (i << 2))
		if (type < 0): return 0
		if (regalloc_type_ok(type) == 0): return 0
		# a narrow parameter's register holds its word re-extended by
		# the load the entry skips
		if ((type_get_pointer_level(type) == 0) && (type_get_size(type) != word_size)): return 0
	return 1


# rs_fn_rank's last step: the body is register-shaped (rg_shaped) when
# the gain ranking put every parameter into the function region. A
# parameter the ranking left out is not added: its debug note would name
# a caller-saved register, which wdbg cannot read (debugger/locals.w reads
# r12-r15, and attach mode no register at all), so a parameter that
# stays readable on the stack today would become unreadable
# (tools/attach_e2e.w's frame-selection case). Filling the free
# registers gave regex_backtrack -4.7% instead of -0.8%.
void rg_shape_rank():
	if (rg_shape_ok(rg_symbol) == 0): return;
	int n = load_int(table + rg_symbol + 22)
	int found = 0
	for i in range(rs_count):
		if ((rs_decls[i] == 0) && (rs_excluded[i] == 0) && (rs_arg_record(i) >= 0)):
			if (rs_fnreg[i] == 0): return;
			found = found + 1
	if (found != n): return;
	rg_nparams = n
	rg_shaped = 1
	# a call the region spills its registers around: the parameters'
	# homes go into the frame (rl_home_disp's 'P'), which both entries
	# reserve below the saved registers
	if (rs_fn_real_call): rg_homes = n


# The region loaded parameter index (0-based) into reg.
void rg_note_param(int index, int reg):
	if ((index < 0) || (index >= 6)): return;
	rg_regs_cur = rg_regs_cur | (reg << (index << 2))
	rg_loaded = rg_loaded + 1


# The body has ended (be_function_epilogue, after its last return):
# publish the register entry when the body qualifies. framed is
# be_frame_active.
void regargs_close(int framed):
	int shaped = rg_shaped
	rg_shaped = 0
	if (shaped == 0): return;
	if ((framed == 0) || (rg_resume == 0) || (rg_touch != 0)): return;
	if (rg_loaded != rg_nparams): return;
	if (rg_enabled() == 0): return;
	int entry = codepos
	emit(1, c"\x55")              # push rbp
	emit(3, c"\x48\x89\xe5")      # mov rbp,rsp
	for r in range(16):
		if (regalloc_saved_mask & (1 << r)): push_reg(r)
	sub_rsp_words(rg_homes)
	int rel = rg_resume - (codepos + 2)
	if (rel >= -128):
		emit_int8(0xeb)            # jmp rel8
		emit_int8(rel)
	else:
		emit_int8(0xe9)            # jmp rel32
		emit_int32(rg_resume - (codepos + 4))
	# the symbol record's O5 fields (compiler/symbol_table.w): the
	# entry's address and the parameters' registers, 4 bits each
	save_int(table + rg_symbol + 154, code_offset + entry)
	save_int(table + rg_symbol + 158, rg_regs_cur)
	# the stub is not the body's code: the inline table's byte budget
	# (compiler/inline_table.w) measures the body alone
	if (inline_capture_active): inline_capture_codepos = inline_capture_codepos + (codepos - entry)
	regargs_entries = regargs_entries + 1


# The number of parameters a direct call to the function symbol t
# passes in registers: all of them when t has a register entry, else 0.
int regargs_callee_params(int t):
	if (rg_enabled() == 0): return 0
	if (t < 0): return 0
	if (table[t + 1] != 'D'): return 0
	if (load_int(table + t + 154) == 0): return 0
	return load_int(table + t + 22)


# The register of parameter index of t (regargs_callee_params(t) > 0).
int regargs_callee_reg(int t, int index):
	return (load_int(table + t + 158) >> (index << 2)) & 15


int regargs_callee_entry(int t):
	return load_int(table + t + 154)


void regalloc_stats_dump():
	print_int0(c"regalloc: bodies scanned: ", regalloc_scanned_functions)
	print_int0(c" locals promoted: ", regalloc_promoted_locals)
	print_int0(c" arguments promoted: ", regalloc_promoted_args)
	print_int0(c" loops owning registers: ", regalloc_loops_owned)
	print_int0(c" loop registers: ", regalloc_loop_regs)
	print_int0(c" function registers: ", regalloc_fn_regs)
	print_int0(c" hazard spills: ", regalloc_hazard_spills)
	print_int0(c" expression parks: ", ers_parks)
	print_int0(c" spilled: ", ers_spills)
	print_int0(c" retargeted: ", xrt_retargets)
	print_error(c"\x0a")
	ivopt_stats_dump()
	# O1 (code_generator/x86.w): constant folds, const-global reads
	# loaded as immediates, unreachable branches/returns not emitted
	print_int0(c"constants: folded: ", k64_folds)
	print_int0(c" const reads: ", const_global_reads_folded)
	print_int0(c" dead jumps/returns: ", term_notes_elided)
	print_error(c"\x0a")
	# O5 (the register arguments section above)
	print_int0(c"register arguments: entries: ", regargs_entries)
	print_int0(c" calls: ", regargs_calls)
	print_error(c"\x0a")
	rs_profile_stats_dump()   # P2
