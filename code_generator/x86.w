void emit_x64_opcode():
	if (word_size == 8): emit(1, c"\x48")


# Local-slot load fusion (docs/projects/optimization.md, the v0 window).
# A local or argument read is emitted as an address materialization
# (lea eax,[esp+N]) followed by a load through eax. lea_eax_esp_plus notes
# the lea; a loader running while the note is still CURRENT -- nothing
# emitted since, so lea_note_end == codepos -- rolls the lea back and
# emits one load addressing [esp+N] directly. add_eax_int32 folds a
# constant offset into a current lea (struct fields of a local). The
# folded load notes itself in turn, so pop_ebx can move it into the
# register shuttle of a binary operator, and push_eax notes every push
# for that shuttle and for the shift-by-constant fold. Same fail-closed
# contract as the constant and compare notes further down: any emission
# the fold did not expect advances codepos and the note stops matching;
# every backward codepos move and every jump target (region ends, loop
# heads, labels, statement starts) clears the notes.
int lea_note_start
int lea_note_end
int lea_note_disp
int load_note_start
int load_note_end
int load_note_disp
int load_note_oplen
char* load_note_op
int push_note_start
int push_note_end
# A 'mov eax,R' read of a register-resident local (mov_eax_reg), so the
# pop_ebx shuttle can fold 'push eax; mov eax,R; pop ebx' like a local
# load.
int regload_note_start
int regload_note_end
int regload_note_reg
# The register read the push carried (push_eax saw a current regload
# note): the left operand of a binary operator is 'mov eax,R' directly
# before its push, so pop_ebx can shuttle it as 'mov ebx,R' and the
# operator can use R itself (R3, docs/projects/register_allocation_pgo.md
# §2.3). Cleared with push_note_end.
int push_left_reg
int push_left_start
# The register shuttle note (R3): pop_ebx emitted 'mov ebx,<left>;
# mov eax,X' with X a constant (kind 1), a word-sized local load
# (kind 2, [esp+disp]) or a register (kind 3), and the left operand is
# register shuttle_left_reg or, when that is 0, whatever eax held at
# shuttle_start. A binary operator running while the note is CURRENT
# (shuttle_end == codepos) rolls the shuttle back and emits
# 'op eax,X' (an ALU operator) or 'cmp eax,X' / 'cmp R,X' (a compare)
# instead of 'op eax,ebx'. Any other consumer sees the ordinary shuttle.
int shuttle_start
int shuttle_end
int shuttle_kind
int shuttle_left_reg
int shuttle_value      # kind 1: the constant
int shuttle_disp       # kind 2: the esp displacement
int shuttle_oplen      # kind 2: the load's opcode (only the word load folds)
char* shuttle_op
int shuttle_reg        # kind 3: the register
# The register binary-operator note (R3): an ALU operator consumed the
# shuttle note, so the bytes from binop_start to codepos are
# '[mov eax,R_left;] op eax,X' and eax holds R_left op X. A store into a
# register-resident local R (regalloc_reg_store) running while this note
# is current and R == R_left (or X == R for a commutative op) rolls the
# sequence back and emits 'op R,X' in place: 'i = i + 1' is 'add R,1'.
int binop_start
int binop_end
int binop_op           # the /n extension: 0 add, 1 or, 4 and, 5 sub, 6 xor; 8 imul
int binop_left_reg
int binop_kind
int binop_value
int binop_disp
int binop_reg
# The constant-folding notes (described at their section further down):
# mov_eax_int's immediate, the constant push_eax carried, and the armed
# two-operand fold.
int imm_note_start
int imm_note_end
int imm_note_value
int push_imm_start
int push_imm_end
int push_imm_value
int binfold_end
int binfold_start
int binfold_left
int binfold_right
int fold_mul_fits(int a, int b);
int fold_add_fits(int a, int b);

void peep_rollback(int pos);
void be_cmp_note_reset();
void be_imm_note_reset();
void be_notes_reset();

void arm64_promote_acc(int instruction);

############################ register-resident locals ###########################
# Function-scoped promotion of word-sized locals into callee-saved
# registers (docs/projects/register_allocation_pgo.md §2.2, unit R2):
# x64 r12-r15, x86 esi/edi. The state is in code_generator/code_emitter.w
# (reg_lvalue note, regalloc_* prologue masks), the decision in
# compiler/regalloc_scan.w. These are the x86-family emitters: the
# register moves the note's consumers emit, the prologue pushes and the
# epilogue pops. (The stack-slot assertion that keeps every path off a
# promoted local's never-updated stack word is regalloc_slot_assert in
# regalloc_scan.w, called by the slot-addressing grammar helpers: the raw
# [esp+disp] emitters here also serve pushes stack_pos does not track,
# so a displacement alone does not name a slot.)

# 1 when the register lvalue note is current: the accumulator "holds" the
# address of a register-resident local.
int regalloc_note_current():
	if (reg_lvalue_end == 0): return 0
	return reg_lvalue_end == codepos

# Consume the note: returns the register, clearing the note.
int regalloc_note_take():
	int r = reg_lvalue
	reg_lvalue_end = 0
	return r

# The narrow-register table (unit A8, docs/projects/codegen_gap_plan.md
# §2.7): the kind of value a promoted register holds, 0 a word, 1 a
# uint32 (zero-extended), 2 an int32 (sign-extended), from the masks in
# code_emitter.w. The decision side (compiler/regalloc_scan.w) binds a
# register when it hands it to a symbol and releases it with the
# symbol; the writers below (mov_reg_eax, regalloc_reg_store, the
# frame-home loads, the for-loop steps) ask here and emit the 32-bit
# forms, so the register holds exactly what the memory path's
# movsxd/mov load would have promoted. x86-32 binds nothing: its
# 32-bit register is the word.
int regalloc_reg_kind(int r):
	if (word_size != 8): return 0
	if ((regalloc_zx_mask >> r) & 1): return 1
	if ((regalloc_sx_mask >> r) & 1): return 2
	return 0

void regalloc_reg_bind(int r, int kind):
	regalloc_zx_mask = regalloc_zx_mask & ~(1 << r)
	regalloc_sx_mask = regalloc_sx_mask & ~(1 << r)
	if (kind == 1): regalloc_zx_mask = regalloc_zx_mask | (1 << r)
	if (kind == 2): regalloc_sx_mask = regalloc_sx_mask | (1 << r)

void regalloc_reg_unbind_all():
	regalloc_zx_mask = 0
	regalloc_sx_mask = 0

# A REX prefix with REX.W when wide, REX.R for the reg field and REX.B
# for the r/m field; nothing when no bit is set, nothing on x86. The
# 32-bit forms of the narrow registers (wide 0: 'add r12d,1' is
# 41 83 c4 01) and the word forms (wide 1) share every encoder below.
void emit_rex(int wide, int reg, int rm):
	if (word_size != 8): return
	int rex = 0x40
	if (wide): rex = rex | 8
	if (reg >= 8): rex = rex | 4
	if (rm >= 8): rex = rex | 1
	if (rex != 0x40): emit_int8(rex)

/* movsxd R,R32 (REX.W+R+B 63 /r): re-extend an int32 register after a
   32-bit in-place operation */
void regalloc_reg_sx(int r):
	emit_rex(1, r, r)
	emit(1, c"\x63")
	emit_int8(0xc0 | ((r & 7) << 3) | (r & 7))

# REX prefix for one extended register (r8-r15) in the r/m field (REX.B)
# or the reg field (REX.R), with REX.W set.
void emit_rex_w_b(int r):
	if (r >= 8): emit(1, c"\x49")
	else: emit(1, c"\x48")

void emit_rex_w_r(int r):
	if (r >= 8): emit(1, c"\x4c")
	else: emit(1, c"\x48")

/* mov eax,R (x86: 89 /r with eax as r/m; x64: REX.W[+R] 89 /r) */
void mov_eax_reg(int r):
	regload_note_start = codepos
	if (word_size == 8): emit_rex_w_r(r)
	emit(1, c"\x89")
	emit_int8(0xc0 | ((r & 7) << 3))
	regload_note_end = codepos
	regload_note_reg = r

/* mov R,eax -- or, for a narrow register (A8), 'mov R32,eax' (89 /r
   without REX.W: the 32-bit write zero-extends) for a uint32 and
   'movsxd R,eax' (REX.W 63 /r) for an int32, the truncating store and
   the extending load of the memory path in one instruction */
void mov_reg_eax(int r):
	int kind = regalloc_reg_kind(r)
	if (kind == 1):
		emit_rex(0, 0, r)
		emit(1, c"\x89")
		emit_int8(0xc0 | (r & 7))
		return
	if (kind == 2):
		emit_rex(1, r, 0)
		emit(1, c"\x63")
		emit_int8(0xc0 | ((r & 7) << 3))
		return
	if (word_size == 8): emit_rex_w_b(r)
	emit(1, c"\x89")
	emit_int8(0xc0 | (r & 7))

/* push R / pop R (41 prefix for r8-r15) */
void push_reg(int r):
	if (r >= 8): emit(1, c"\x41")
	emit_int8(0x50 | (r & 7))

void pop_reg(int r):
	if (r >= 8): emit(1, c"\x41")
	emit_int8(0x58 | (r & 7))

/* add R,imm8 (sign-extended): 83 /0 ib; a narrow register takes the
   32-bit form (and re-extends when signed), like every writer here */
void add_reg_int8(int r, int v):
	int kind = regalloc_reg_kind(r)
	emit_rex(kind == 0, 0, r)
	emit(1, c"\x83")
	emit_int8(0xc0 | (r & 7))
	emit_int8(v)
	if (kind == 2): regalloc_reg_sx(r)

/* add R,eax: 01 /r with R as r/m */
void add_reg_eax(int r):
	int kind = regalloc_reg_kind(r)
	emit_rex(kind == 0, 0, r)
	emit(1, c"\x01")
	emit_int8(0xc0 | (r & 7))
	if (kind == 2): regalloc_reg_sx(r)

/* mov ebx,R (89 /r with ebx as r/m) */
void mov_ebx_reg(int r):
	if (word_size == 8): emit_rex_w_r(r)
	emit(1, c"\x89")
	emit_int8(0xc3 | ((r & 7) << 3))

# REX.W with REX.R for the reg field and REX.B for the r/m field, x64 only.
void emit_rex_w_rb(int reg, int rm):
	if (word_size != 8): return
	int rex = 0x48
	if (reg >= 8): rex = rex | 4
	if (rm >= 8): rex = rex | 1
	emit_int8(rex)

# The register-operand ALU forms (R3). ext is the ModRM /n extension of
# the 81/83 immediate group (0 add, 1 or, 4 and, 5 sub, 6 xor, 7 cmp);
# 8 stands for imul, which has its own opcodes. dst is any register
# (0 = eax); the x64 forms carry REX.W.

/* op dst,imm: 83 /ext ib when the immediate fits a signed byte, the
   short eax form (05/0d/25/2d/35/3d id) for eax, 81 /ext id otherwise;
   imul dst,dst,imm is 6b/69 /r. wide 0 is the 32-bit form (A8: the
   in-place operation on a narrow register), wide 1 the word form. */
void emit_alu_reg_imm_w(int wide, int ext, int dst, int v):
	int fits8 = (v >= -128) && (v <= 127)
	if (ext == 8):
		# always the imm32 form (69): libs/asm decodes no 6b
		emit_rex(wide, dst, dst)
		emit_int8(0x69)
		emit_int8(0xc0 | ((dst & 7) << 3) | (dst & 7))
		emit_int32(v)
		return
	emit_rex(wide, 0, dst)
	if (fits8):
		emit_int8(0x83)
		emit_int8(0xc0 | (ext << 3) | (dst & 7))
		emit_int8(v)
		return
	if (dst == 0):
		emit_int8(0x05 | (ext << 3))
		emit_int32(v)
		return
	emit_int8(0x81)
	emit_int8(0xc0 | (ext << 3) | (dst & 7))
	emit_int32(v)

void emit_alu_reg_imm(int ext, int dst, int v):
	emit_alu_reg_imm_w(1, ext, dst, v)

/* The 'op r32, r/m32' opcode of an extension: add 03, or 0b, and 23,
   sub 2b, xor 33, cmp 3b (each 8*ext + 3). */
void emit_alu_rm_opcode(int ext):
	if (ext == 8): emit(2, c"\x0f\xaf")
	else: emit_int8(0x03 | (ext << 3))

/* op dst,src (register source): the 'r/m, reg' form (01/09/21/29/31/39,
   dst in r/m) that libs/asm's encoder picks for two registers, so the
   asm_x64_test encode identity holds; imul has only its 'reg, r/m' form. */
void emit_alu_reg_reg_w(int wide, int ext, int dst, int src):
	if (ext == 8):
		emit_rex(wide, dst, src)
		emit(2, c"\x0f\xaf")
		emit_int8(0xc0 | ((dst & 7) << 3) | (src & 7))
		return
	emit_rex(wide, src, dst)
	emit_int8(0x01 | (ext << 3))
	emit_int8(0xc0 | ((src & 7) << 3) | (dst & 7))

void emit_alu_reg_reg(int ext, int dst, int src):
	emit_alu_reg_reg_w(1, ext, dst, src)

/* op dst,[esp+disp] */
void emit_alu_reg_esp_w(int wide, int ext, int dst, int disp):
	emit_rex(wide, dst, 0)
	emit_alu_rm_opcode(ext)
	if ((disp >= -128) && (disp <= 127)):
		emit_int8(0x44 | ((dst & 7) << 3))
		emit_int8(0x24)
		emit_int8(disp)
	else:
		emit_int8(0x84 | ((dst & 7) << 3))
		emit_int8(0x24)
		emit_int32(disp)

void emit_alu_reg_esp(int ext, int dst, int disp):
	emit_alu_reg_esp_w(1, ext, dst, disp)

/* op dst,eax */
void emit_alu_reg_eax(int ext, int dst):
	emit_alu_reg_reg(ext, dst, 0)

/* add eax,R: the register-base fold of a subscript (A1,
   docs/projects/codegen_gap_plan.md §2.1): the base of 'p[i]' lives in
   R, so the scaled index in eax gets it added directly instead of
   through a parked copy ('push eax; ...; pop ebx; add eax,ebx'). The
   two-register ALU form emit_alu_reg_reg already carries the x64 REX
   bits for r8-r15. */
void add_eax_reg(int r):
	emit_alu_reg_reg(0, 0, r)

# 'op dst,X' for the operand X a shuttle or binop note recorded (kind 1
# constant, 2 [esp+disp] word load, 3 register), at the word width or
# (wide 0) the 32-bit width: the low 32 bits of a sum, difference,
# product or bitwise result depend only on the low 32 bits of the
# operands, so the 32-bit form on a narrow register reads a word
# operand's low half and writes the truncated result the memory path
# would have stored.
void emit_alu_reg_x_w(int wide, int ext, int dst, int kind, int value, int disp, int reg):
	if (kind == 1): emit_alu_reg_imm_w(wide, ext, dst, value)
	elif (kind == 2): emit_alu_reg_esp_w(wide, ext, dst, disp)
	else: emit_alu_reg_reg_w(wide, ext, dst, reg)

void emit_alu_reg_x(int ext, int dst, int kind, int value, int disp, int reg):
	emit_alu_reg_x_w(1, ext, dst, kind, value, disp, reg)

/* mov R,[ebp+disp] / mov [ebp+disp],R (8b / 89 /r, ebp base, no SIB):
   the loop-scoped register loads, write-backs and call spills (R3,
   compiler/regalloc_scan.w), addressed from the frame pointer so no
   push or pop between them matters. */
void emit_ebp_disp_modrm(int r, int disp):
	if ((disp >= -128) && (disp <= 127)):
		emit_int8(0x45 | ((r & 7) << 3))
		emit_int8(disp)
	else:
		emit_int8(0x85 | ((r & 7) << 3))
		emit_int32(disp)

void mov_reg_ebp_disp(int r, int disp):
	# A narrow register (A8) loads its home at the width the memory
	# path reads it: 'mov R32,[ebp+disp]' zero-extends a uint32,
	# 'movsxd R,[ebp+disp]' sign-extends an int32 (the word's high half
	# is stale after a 32-bit store, exactly as for a stack read)
	int kind = regalloc_reg_kind(r)
	if (kind == 2):
		emit_rex(1, r, 0)
		emit(1, c"\x63")
		emit_ebp_disp_modrm(r, disp)
		return
	if (kind == 1): emit_rex(0, r, 0)
	elif (word_size == 8): emit_rex_w_r(r)
	emit(1, c"\x8b")
	emit_ebp_disp_modrm(r, disp)

void mov_ebp_disp_reg(int r, int disp):
	if (word_size == 8): emit_rex_w_r(r)
	emit(1, c"\x89")
	emit_ebp_disp_modrm(r, disp)

# Loop-scoped allocation is on for the current function (the scan found
# no goto/label/defer and at least one loop); set with the pending mask.
int regalloc_loops_ok
void regalloc_call_spill();    /* compiler/regalloc_scan.w */
void regalloc_call_reload();

/* lea esp,[ebp-disp8] */
void lea_esp_ebp_minus(int disp):
	emit_x64_opcode()
	emit(2, c"\x8d\x65")
	emit_int8(0 - disp)

# The order registers are pushed: ascending register number, so the pops
# below and the debugger's saved-slot arithmetic (debugger/locals.w) agree.
int regalloc_mask_index(int mask, int r):
	int index = 0
	int i = 0
	while (i < r):
		if (mask & (1 << i)): index = index + 1
		i = i + 1
	return index

# The prologue's share: right after 'push ebp ; mov ebp,esp', push the
# registers the pre-scan asked for (regalloc_pending_mask), making them
# the current function's saved set. Called by be_function_prologue on the
# x86 path only; the pending mask is only ever set for that path.
void regalloc_prologue_args();   /* compiler/regalloc_scan.w: the argument loads (A1) */
void regalloc_prologue_emit():
	int mask = regalloc_pending_mask
	regalloc_pending_mask = 0
	regalloc_saved_mask = 0
	regalloc_saved_count = 0
	regalloc_active = 0
	if (regalloc_loops_ok): regalloc_active = 1
	if (mask == 0): return
	regalloc_active = 1
	int r = 0
	while (r < 16):
		if (mask & (1 << r)):
			push_reg(r)
			regalloc_saved_count = regalloc_saved_count + 1
		r = r + 1
	regalloc_saved_mask = mask
	regalloc_prologue_args()

# The framed return of a function whose prologue pushed registers:
# 'lea esp,[ebp-W*saved] ; pop ... ; pop ebp' replaces 'leave'. Callers
# emit the ret. Returns 1 when it emitted the frame teardown, 0 when the
# function saved nothing (the caller emits 'leave').
int regalloc_epilogue_emit():
	if (regalloc_saved_count == 0): return 0
	lea_esp_ebp_minus(regalloc_saved_count << word_size_log2)
	int r = 15
	while (r >= 0):
		if (regalloc_saved_mask & (1 << r)): pop_reg(r)
		r = r - 1
	return 1

# ModRM+SIB(+disp) for [esp+disp] with eax in the reg field; disp8 when
# it fits.
void emit_eax_esp_disp(int disp):
	if ((disp >= -128) && (disp <= 127)):
		emit(2, c"\x44\x24")
		emit_int8(disp)
		return
	emit(2, c"\x84\x24")
	emit_int32(disp)

# A load of [esp+disp] into eax whose opcode bytes (prefixes included) are
# op[0..oplen). Noted so pop_ebx can re-emit it at another displacement.
void emit_esp_load(int oplen, char* op, int disp):
	int start = codepos
	emit(oplen, op)
	emit_eax_esp_disp(disp)
	load_note_start = start
	load_note_end = codepos
	load_note_disp = disp
	load_note_op = op
	load_note_oplen = oplen

# Replace the current lea note with a direct [esp+disp] load. Callers have
# checked the note is current (lea_note_end != 0 && == codepos).
void lea_load_fold(int oplen, char* op):
	int disp = lea_note_disp
	peep_rollback(lea_note_start)
	emit_esp_load(oplen, op, disp)


############################ memory operands (A2) ############################
# Addressing modes (docs/projects/codegen_gap_plan.md §2.2, unit A2). The
# emitter's one data-addressing form was "compute the address into eax,
# then load [eax] / store [ebx]". The ADDRESS NOTE below describes an
# address the accumulator holds as a base register, an optional index
# register with a scale and a displacement -- [base + index*scale + disp]
# -- so the load or store that consumes it can address memory in one
# instruction with a ModRM/SIB operand instead. Who sets it:
#
# - a subscript whose base is register-resident (A1) or parked on the
#   stack (subscript_reg_base / subscript_stack_base, called from
#   grammar/postfix_expr.w's '[' and its retained twin): the index is a
#   constant (folded into the displacement), a register-resident local
#   (the SIB index), 'R +/- c' (index and displacement) or whatever eax
#   holds (eax as the index);
# - add_eax_int32, the field offset of 'p.f': a register-resident pointer
#   becomes 'lea eax,[R+off]', anything else keeps 'add eax,off' and is
#   noted as [eax+off]; a current note just grows its displacement, which
#   is how 'p.a.b' and 'a[i].f' compose.
#
# The bytes the note describes always leave the address in eax: 'lea
# eax,[...]' (or the 'add') is emitted, so a consumer that does not know
# the note -- '&a[i]', a struct element copied by address, every path on
# the other ISAs -- is correct by construction. A consumer that does
# (the promote_* loaders, the stores and compound stores of
# grammar/expression.w and grammar/increment.w through mem_lvalue_*
# below) rolls the bytes back and uses the operand directly, under the
# same contract as every other note here: valid only while nothing has
# been emitted since (addr_note_end == codepos), cleared by
# peep_rollback and be_notes_reset. Base 0 / index 0 mean "the value eax
# held before the noted bytes" (the two are never both 0), base 4 is
# esp (a stack local, from the lea note) and 3 is ebx (a popped base).
int addr_note_start
int addr_note_end
int addr_note_base
int addr_note_index    # -1: no index
int addr_note_scale
int addr_note_disp

# The folded memory load the loaders leave behind ('mov eax,[mem]',
# 'movsx eax,byte [mem]', ...): the compound store can turn 'load; op
# eax,X; store' into 'op [mem],X', and a comparison of the load against
# a constant into 'cmp [mem],imm' at the load's width (shuttle_cmp).
int memload_start
int memload_end
int memload_base
int memload_index
int memload_scale
int memload_disp
int memload_w          # REX.W (the word-sized load)
int memload_oplen
char* memload_op

void mov_ebx_esp_plus(int v);
void imul_eax_int32(int v);
void mov_eax_int(int v);
void pop_ebx();
void alu_add();

int addr_note_current():
	if (addr_note_end == 0): return 0
	return addr_note_end == codepos

# REX prefix for an instruction with a memory operand: W for a 64-bit
# operand, R for an extended reg field, X for an extended SIB index and B
# for an extended base. Nothing when no bit is needed (the 32-bit forms,
# movzx/movsx, byte and short stores keep their REX-free encodings).
void emit_rex_mem(int w, int reg, int index, int base):
	if (word_size != 8): return
	int rex = 0x40
	if (w): rex = rex | 8
	if (reg >= 8): rex = rex | 4
	if (index >= 8): rex = rex | 2
	if (base >= 8): rex = rex | 1
	if (rex != 0x40): emit_int8(rex)

# ModRM (+SIB, +disp8/disp32) for reg against [base + index*scale + disp].
# A base of esp/r12 needs the SIB form, ebp/r13 a displacement (mod 1 or
# 2) even when it is zero, and an SIB index field of 4 with REX.X clear
# means "no index", so esp can never be an index (W never uses it as a
# value register) while r12 can.
void emit_mem_modrm(int reg, int base, int index, int scale, int disp):
	int mod = 2
	if ((disp == 0) && ((base & 7) != 5)): mod = 0
	elif ((disp >= -128) && (disp <= 127)): mod = 1
	if ((index >= 0) || ((base & 7) == 4)):
		emit_int8((mod << 6) | ((reg & 7) << 3) | 4)
		int ss = 0
		if (scale == 2): ss = 1
		elif (scale == 4): ss = 2
		elif (scale == 8): ss = 3
		int idx = 4
		if (index >= 0): idx = index & 7
		emit_int8((ss << 6) | (idx << 3) | (base & 7))
	else: emit_int8((mod << 6) | ((reg & 7) << 3) | (base & 7))
	if (mod == 1): emit_int8(disp)
	elif (mod == 2): emit_int32(disp)

# REX + opcode bytes + memory ModRM.
void emit_mem_insn(int w, int oplen, char* op, int reg, int base, int index, int scale, int disp):
	emit_rex_mem(w, reg, index, base)
	emit(oplen, op)
	emit_mem_modrm(reg, base, index, scale, disp)

int scale_ok(int s):
	return (s == 1) || (s == 2) || (s == 4) || (s == 8)

# Leave eax = base + index*scale + disp (index -1: none) and note it.
# The eax-plus-displacement shape keeps the 'add eax,imm32' form
# add_eax_int32 always emitted (nothing for a zero displacement: the note
# is then empty, and its consumer rolls back nothing).
void addr_form(int base, int index, int scale, int disp):
	int start = codepos
	if ((base == 0) && (index < 0)):
		if (disp != 0):
			emit_x64_opcode()
			emit(1, c"\x05")
			emit_int32(disp)
	else: emit_mem_insn(word_size == 8, 1, c"\x8d", 0, base, index, scale, disp)
	if (addr_modes_disabled): return
	addr_note_start = start
	addr_note_end = codepos
	addr_note_base = base
	addr_note_index = index
	addr_note_scale = scale
	addr_note_disp = disp

# The loaders' consumer: replace the current address note with one load
# of its operand into eax (w: REX.W; op the opcode bytes), noting the
# load for the compound store and the byte compare.
void memload_note(int start, int base, int index, int scale, int disp, int w, int oplen, char* op):
	memload_start = start
	memload_end = codepos
	memload_base = base
	memload_index = index
	memload_scale = scale
	memload_disp = disp
	memload_w = w
	memload_oplen = oplen
	memload_op = op

void addr_load_fold(int w, int oplen, char* op):
	int base = addr_note_base
	int index = addr_note_index
	int scale = addr_note_scale
	int disp = addr_note_disp
	peep_rollback(addr_note_start)
	int start = codepos
	emit_mem_insn(w, oplen, op, 0, base, index, scale, disp)
	memload_note(start, base, index, scale, disp, w, oplen, op)

# The plain '[eax]' load the loaders emit when no address note precedes
# them (a field at offset 0, a dereference): the same bytes, noted as
# the memload of [eax] (base 0: the address eax held before it) so a
# compare against a constant still folds (shuttle_cmp).
void plain_load(int w, int oplen, char* op):
	int start = codepos
	emit_mem_insn(w, oplen, op, 0, 0, -1, 1, 0)
	if (addr_modes_disabled): return
	memload_note(start, 0, -1, 1, 0, w, oplen, op)

int memload_current():
	if (memload_end == 0): return 0
	return memload_end == codepos

# The folded load is the word-sized 'mov eax,[mem]'.
int memload_is_word():
	if (memload_oplen != 1): return 0
	if ((memload_op[0] & 255) != 0x8b): return 0
	if (word_size == 8): return memload_w
	return 1

# A displacement the disp32 field can hold: the compiler may be a 64-bit
# host folding offsets a 32-bit field cannot carry.
int disp_fits(int v):
	if (__word_size__ == 4): return 1
	return (v >= -2147483647 - 1) && (v <= 2147483647)

# --- the index of a subscript ------------------------------------------
# After the index expression ran (its first byte at index_start) and
# promote() put the index in eax, fold base register r and the element
# size into one address: a constant index becomes a displacement, a
# register-resident index ('mov eax,R2' was the whole expression) the
# SIB index, 'R2 +/- c' (R3's register fold, the binop note) index plus
# displacement, and anything else scales eax in the SIB byte, or by a
# shift for a power of two past 8, or by the imul for an odd size. Every
# shape ends in addr_form, so the load or store that follows folds it.
# The index shapes, tested against the index expression's first byte:
# a constant (the imm note), a register read (the regload note), 'R +/-
# c' (R3's binop note with a register left operand and a constant) and
# a word-sized local load (the load note). Each returns 1 when the
# index is that shape and fills index_reg / index_disp (the load's
# displacement for the last one).
int index_reg
int index_disp

int index_is_constant(int index_start, int size):
	if ((imm_note_end == 0) || (imm_note_end != codepos) || (imm_note_start != index_start)): return 0
	if (fold_mul_fits(imm_note_value, size) == 0): return 0
	index_disp = imm_note_value * size
	return disp_fits(index_disp)

int index_is_register(int index_start, int size):
	if (scale_ok(size) == 0): return 0
	if ((regload_note_end != 0) && (regload_note_end == codepos) && (regload_note_start == index_start)):
		index_reg = regload_note_reg
		index_disp = 0
		return 1
	if ((binop_end == 0) || (binop_end != codepos) || (binop_start != index_start)): return 0
	if ((binop_left_reg == 0) || (binop_kind != 1)): return 0
	if ((binop_op != 0) && (binop_op != 5)): return 0
	if (fold_mul_fits(binop_value, size) == 0): return 0
	index_disp = binop_value * size
	if (binop_op == 5): index_disp = 0 - index_disp
	if (disp_fits(index_disp) == 0): return 0
	index_reg = binop_left_reg
	return 1

int index_is_local_load(int index_start, int size):
	if (scale_ok(size) == 0): return 0
	if ((load_note_end == 0) || (load_note_end != codepos) || (load_note_start != index_start)): return 0
	if (load_note_disp < word_size): return 0
	if (word_size == 8):
		if ((load_note_oplen != 2) || ((load_note_op[0] & 255) != 0x48) || ((load_note_op[1] & 255) != 0x8b)): return 0
	elif ((load_note_oplen != 1) || ((load_note_op[0] & 255) != 0x8b)): return 0
	index_disp = load_note_disp
	return 1

# The index is in eax, computed by the bytes from index_start, and the
# base is register r (never eax): fold the two and the element size
# into one address. A scale the SIB byte cannot carry is a shift for a
# power of two, the imul otherwise.
void subscript_index_eax(int base, int size):
	if (scale_ok(size)):
		addr_form(base, 0, size, 0)
		return
	int k = 0
	int s = size
	while ((s > 1) && ((s & 1) == 0)):
		s = s >> 1
		k = k + 1
	if (s == 1):
		emit_x64_opcode()
		emit_int8(0xc1)
		emit_int8(0xe0)
		emit_int8(k)
	else: imul_eax_int32(size)
	addr_form(base, 0, 1, 0)

# The register-resident base of A1: nothing was pushed, the index ran
# from index_start.
void subscript_reg_base(int r, int size, int index_start):
	if (addr_modes_disabled):
		if (size > 1): imul_eax_int32(size)
		add_eax_reg(r)
		return
	if (size < 1): size = 1
	if (index_is_constant(index_start, size)):
		int disp = index_disp
		peep_rollback(index_start)
		addr_form(r, -1, 1, disp)
		return
	if (index_is_register(index_start, size)):
		int reg = index_reg
		int rdisp = index_disp
		peep_rollback(index_start)
		addr_form(r, reg, size, rdisp)
		return
	subscript_index_eax(r, size)

# The base is parked on the stack (binary1 pushed it directly before
# index_start). A one-instruction index -- constant, register, 'R +/- c'
# or a word-sized local load (through ebx) -- rolls the push back and
# addresses from eax (the base) directly; otherwise the base is popped
# into ebx and the index in eax is the SIB index. Either way the base's
# stack word is gone when this returns (the caller drops it from
# stack_pos).
void subscript_stack_base(int size, int index_start):
	if (addr_modes_disabled):
		if (size > 1): imul_eax_int32(size)
		pop_ebx()
		alu_add()
		return
	if (size < 1): size = 1
	if ((push_note_end != 0) && (push_note_end == index_start) && (push_note_start < index_start)):
		int push_start = push_note_start
		if (index_is_constant(index_start, size)):
			int disp = index_disp
			peep_rollback(push_start)
			addr_form(0, -1, 1, disp)
			return
		if (index_is_register(index_start, size)):
			int reg = index_reg
			int rdisp = index_disp
			peep_rollback(push_start)
			addr_form(0, reg, size, rdisp)
			return
		if (index_is_local_load(index_start, size)):
			int ldisp = index_disp - word_size
			peep_rollback(push_start)
			mov_ebx_esp_plus(ldisp)
			addr_form(0, 3, size, 0)
			return
	pop_ebx()
	subscript_index_eax(3, size)

# --- stores ----------------------------------------------------------------
# mov [mem],eax at a width of 1, 2, 4 or word_size bytes.
void store_mem_eax(int size, int base, int index, int scale, int disp):
	if (size == 1): emit_mem_insn(0, 1, c"\x88", 0, base, index, scale, disp)
	elif (size == 2):
		emit(1, c"\x66")
		emit_mem_insn(0, 1, c"\x89", 0, base, index, scale, disp)
	elif (size == 4): emit_mem_insn(0, 1, c"\x89", 0, base, index, scale, disp)
	else: emit_mem_insn(word_size == 8, 1, c"\x89", 0, base, index, scale, disp)

# mov [mem],R: a byte store needs a byte register that the REX-free
# encoding can name (al, cl, dl, bl, r8b-r15b; esi/edi would read as
# dh/bh), so store_mem_reg_ok declines those.
int store_mem_reg_ok(int size, int r):
	if (size != 1): return 1
	return (r < 4) || (r >= 8)

void store_mem_reg(int size, int r, int base, int index, int scale, int disp):
	if (size == 1): emit_mem_insn(0, 1, c"\x88", r, base, index, scale, disp)
	elif (size == 2):
		emit(1, c"\x66")
		emit_mem_insn(0, 1, c"\x89", r, base, index, scale, disp)
	elif (size == 4): emit_mem_insn(0, 1, c"\x89", r, base, index, scale, disp)
	else: emit_mem_insn(word_size == 8, 1, c"\x89", r, base, index, scale, disp)

# mov [mem],imm: C6 /0 ib for a byte, 66 C7 /0 iw, C7 /0 id, REX.W C7 /0 id
# (sign-extended, so the word form takes a signed 32-bit value only:
# store_mem_imm_ok).
int store_mem_imm_ok(int size, int v):
	if (size < word_size): return 1
	if (word_size == 4): return 1
	return ((v >> 31) == 0) || ((v >> 31) == -1)

void store_mem_imm(int size, int v, int base, int index, int scale, int disp):
	if (size == 1):
		emit_mem_insn(0, 1, c"\xc6", 0, base, index, scale, disp)
		emit_int8(v)
	elif (size == 2):
		emit(1, c"\x66")
		emit_mem_insn(0, 1, c"\xc7", 0, base, index, scale, disp)
		emit_int8(v)
		emit_int8(v >> 8)
	elif (size == 4):
		emit_mem_insn(0, 1, c"\xc7", 0, base, index, scale, disp)
		emit_int32(v)
	else:
		emit_mem_insn(word_size == 8, 1, c"\xc7", 0, base, index, scale, disp)
		emit_int32(v)

# op [mem],imm / op [mem],R at the word width (ext as in emit_alu_reg_imm:
# 0 add, 1 or, 4 and, 5 sub, 6 xor, 7 cmp; never imul).
void alu_mem_imm_w(int w, int ext, int v, int base, int index, int scale, int disp):
	if ((v >= -128) && (v <= 127)):
		emit_mem_insn(w, 1, c"\x83", ext, base, index, scale, disp)
		emit_int8(v)
	else:
		emit_mem_insn(w, 1, c"\x81", ext, base, index, scale, disp)
		emit_int32(v)

void alu_mem_imm(int ext, int v, int base, int index, int scale, int disp):
	alu_mem_imm_w(word_size == 8, ext, v, base, index, scale, disp)

void alu_mem_reg(int ext, int r, int base, int index, int scale, int disp):
	char* op = c"\x01\x09\x11\x19\x21\x29\x31\x39" + ext
	emit_mem_insn(word_size == 8, 1, op, r, base, index, scale, disp)

# cmp byte [mem],imm8 (80 /7 ib)
void cmp_mem8_imm(int v, int base, int index, int scale, int disp):
	emit_mem_insn(0, 1, c"\x80", 7, base, index, scale, disp)
	emit_int8(v)

# cmp [mem],imm at width 1, 2, 4 or 8 (66 83/81 /7 for a word, 83/81 /7
# without REX.W for a dword on x64).
void cmp_mem_imm(int width, int v, int base, int index, int scale, int disp):
	if (width == 1): cmp_mem8_imm(v, base, index, scale, disp)
	elif (width == 2):
		emit(1, c"\x66")
		if ((v >= -128) && (v <= 127)):
			emit_mem_insn(0, 1, c"\x83", 7, base, index, scale, disp)
			emit_int8(v)
		else:
			emit_mem_insn(0, 1, c"\x81", 7, base, index, scale, disp)
			emit_int8(v)
			emit_int8(v >> 8)
	else: alu_mem_imm_w(width == 8, 7, v, base, index, scale, disp)

# The width at which 'cmp [mem],imm' reads the same as 'cmp rax,imm'
# after the noted load, or 0. Sign extension preserves both the signed
# and the unsigned order, so a sign-extending load (movsx, movsxd, the
# word load) folds for every condition and an immediate the narrow
# width holds; zero extension preserves only the unsigned order and
# equality, so a zero-extending load (movzx, the x64 dword load) folds
# for those conditions and an immediate in the width's unsigned range.
int memload_cmp_width(int setcc_opcode, int v):
	int unsigned_or_eq = (setcc_opcode == 0x94) || (setcc_opcode == 0x95) || (setcc_opcode == 0x92) || (setcc_opcode == 0x93) || (setcc_opcode == 0x96) || (setcc_opcode == 0x97)
	int first = memload_op[0] & 255
	if (memload_oplen == 2):
		if (first != 0x0f): return 0
		int second = memload_op[1] & 255
		if ((second == 0xbe) && (v >= -128) && (v <= 127)): return 1
		if ((second == 0xb6) && (v >= 0) && (v <= 255) && unsigned_or_eq): return 1
		if ((second == 0xbf) && (v >= -32768) && (v <= 32767)): return 2
		if ((second == 0xb7) && (v >= 0) && (v <= 65535) && unsigned_or_eq): return 2
		return 0
	if (memload_oplen != 1): return 0
	if (first == 0x8b):
		if (memload_is_word()): return word_size
		if ((v >= 0) && unsigned_or_eq): return 4
		return 0
	if (first == 0x63): return 4
	return 0

# --- the lvalue of a store (grammar/expression.w '=', grammar/increment.w
# 'op=' and '++'/'--', and their retained twins) -----------------------
# mem_lvalue_begin classifies what the accumulator holds right after the
# left side was parsed and returns the kind, copying the operand into
# mem_lv_* for the caller to keep in locals (a nested assignment on the
# right side runs this again):
#  0  no memory operand: the caller parks the address as before;
#  1  an address from registers alone ([R+R2*s+d], [esp+d] from the lea
#     note): nothing is parked, the right side runs with eax free and the
#     store addresses memory directly (tier A). An esp base is relative
#     to the stack depth at the '=' (mem_lv_pos, the caller's stack_pos):
#     the store re-adjusts the displacement by the words the right side
#     left parked;
#  2  an address that uses eax or ebx ([eax+d], [R+eax*s], [ebx+eax*s]):
#     the lea stays and is parked as before, but the store may still
#     roll back to it when the right side turned out to be one simple
#     instruction (mem_store_parked, tier B); mem_lv_start is where the
#     lea begins.
# The lvalue's registers are never written by the right side: a base or
# index name written there excludes itself from promotion
# (compiler/regalloc_scan.w, rs_store_line).
int mem_lv_base
int mem_lv_index
int mem_lv_scale
int mem_lv_disp
int mem_lv_pos
int mem_lv_start

int mem_lvalue_begin(int depth):
	if ((target_isa != 0) || addr_modes_disabled): return 0
	if ((lea_note_end != 0) && (lea_note_end == codepos)):
		mem_lv_base = 4
		mem_lv_index = -1
		mem_lv_scale = 1
		mem_lv_disp = lea_note_disp
		mem_lv_pos = depth
		peep_rollback(lea_note_start)
		return 1
	if ((addr_note_end == 0) || (addr_note_end != codepos)): return 0
	mem_lv_base = addr_note_base
	mem_lv_index = addr_note_index
	mem_lv_scale = addr_note_scale
	mem_lv_disp = addr_note_disp
	mem_lv_pos = depth
	mem_lv_start = addr_note_start
	if ((mem_lv_base == 0) || (mem_lv_index == 0) || (mem_lv_base == 3)): return 2
	peep_rollback(addr_note_start)
	addr_note_end = 0
	return 1

# Tier A, the load of the left value for a compound store: re-note the
# operand (nothing to emit) so promote() folds it into one load.
void mem_lvalue_renote(int base, int index, int scale, int disp):
	addr_note_start = codepos
	addr_note_end = codepos
	addr_note_base = base
	addr_note_index = index
	addr_note_scale = scale
	addr_note_disp = disp

# Tier A store of eax (the right side's value, already coerced) at
# 'size' bytes. In statement position (value_dead) a value that was just
# 'mov eax,R' or 'mov eax,imm' stores the register or the immediate
# itself. The esp-relative displacement follows the stack depth (pos at
# the '=', depth now).
void mem_store_eax(int size, int base, int index, int scale, int disp, int pos, int depth, int value_dead):
	if (base == 4): disp = disp + ((depth - pos) << word_size_log2)
	if (value_dead):
		if ((regload_note_end != 0) && (regload_note_end == codepos) && store_mem_reg_ok(size, regload_note_reg)):
			int r = regload_note_reg
			peep_rollback(regload_note_start)
			store_mem_reg(size, r, base, index, scale, disp)
			return
		if ((imm_note_end != 0) && (imm_note_end == codepos) && store_mem_imm_ok(size, imm_note_value)):
			int v = imm_note_value
			peep_rollback(imm_note_start)
			store_mem_imm(size, v, base, index, scale, disp)
			return
	store_mem_eax(size, base, index, scale, disp)

# Tier A compound store, statement position: eax was computed as
# '[mem] op X' -- the folded load directly followed by R3's register
# operand fold ('op eax,X', the binop note) -- so the whole sequence is
# one 'op [mem],X'. Returns 1 when it emitted that, 0 for the caller's
# mem_store_eax.
int mem_store_compound(int size, int base, int index, int scale, int disp, int pos, int depth):
	if (size != word_size): return 0
	if (base == 4): disp = disp + ((depth - pos) << word_size_log2)
	if ((binop_end == 0) || (binop_end != codepos)): return 0
	if ((binop_left_reg != 0) || (binop_op == 8) || (binop_kind == 2)): return 0
	if ((memload_end == 0) || (memload_end != binop_start) || (memload_is_word() == 0)): return 0
	if ((memload_base != base) || (memload_index != index) || (memload_scale != scale) || (memload_disp != disp)): return 0
	if ((binop_kind == 1) && (word_size == 8) && (((binop_value >> 31) != 0) && ((binop_value >> 31) != -1))): return 0
	int ext = binop_op
	int kind = binop_kind
	int value = binop_value
	int reg = binop_reg
	peep_rollback(memload_start)
	if (kind == 1): alu_mem_imm(ext, value, base, index, scale, disp)
	else: alu_mem_reg(ext, reg, base, index, scale, disp)
	return 1

# Tier B: the lea (from mem_lv_start) was parked by the push that ended
# at push_end, and the right side has run. When it was exactly one
# simple instruction after the push -- a constant, a register read or a
# word-sized local load -- roll everything back to the lea and store the
# value straight into the operand (eax still holds the index, ebx the
# popped base): 'mov [R+eax*8],R2'. A local load goes through ebx when
# the operand does not use it. keep_eax re-materializes the value when
# the expression's result is used. Returns 1 when it stored, 0 when the
# caller must pop the address and store through ebx as before.
int mem_store_parked(int size, int base, int index, int scale, int disp, int start, int push_end, int keep_eax):
	if ((push_note_end == 0) || (push_note_end != push_end)): return 0
	if ((regload_note_end != 0) && (regload_note_end == codepos) && (regload_note_start == push_end)):
		int r = regload_note_reg
		if (store_mem_reg_ok(size, r) == 0): return 0
		peep_rollback(start)
		store_mem_reg(size, r, base, index, scale, disp)
		if (keep_eax): mov_eax_reg(r)
		return 1
	if ((imm_note_end != 0) && (imm_note_end == codepos) && (imm_note_start == push_end)):
		int v = imm_note_value
		if (store_mem_imm_ok(size, v) == 0): return 0
		peep_rollback(start)
		store_mem_imm(size, v, base, index, scale, disp)
		if (keep_eax): mov_eax_int(v)
		return 1
	if ((load_note_end != 0) && (load_note_end == codepos) && (load_note_start == push_end) && (load_note_disp >= word_size)):
		if ((base == 3) || (index == 3)): return 0
		int word_load = 0
		if (word_size == 8):
			if ((load_note_oplen == 2) && ((load_note_op[0] & 255) == 0x48) && ((load_note_op[1] & 255) == 0x8b)): word_load = 1
		elif ((load_note_oplen == 1) && ((load_note_op[0] & 255) == 0x8b)): word_load = 1
		if (word_load == 0): return 0
		int ldisp = load_note_disp - word_size
		peep_rollback(start)
		mov_ebx_esp_plus(ldisp)
		store_mem_reg(size, 3, base, index, scale, disp)
		if (keep_eax):
			emit_x64_opcode()
			emit(2, c"\x89\xd8") /* mov eax,ebx */
		return 1
	return 0

######################## end of memory operands (A2) #########################


################################# x86 opcodes #################################
# Each helper dispatches to its AArch64 twin (code_generator/arm64.w) when
# target_isa == 1; the x86/x64 byte sequences below are otherwise unchanged,
# so those targets stay byte-identical.

/* push dword 0x12 */
void push_int8(int v):
	if (target_isa == 3): ptx_push_const(v)
	elif (target_isa == 2): wasm_push_const(v)
	elif (target_isa == 1): arm64_push_imm(v)
	else:
		emit_int8(106)
		emit_int8(v)


/* push dword op(0x12, 0x345678) */
void push_int32(int v):
	if (target_isa == 3): ptx_push_const(v)
	elif (target_isa == 2): wasm_push_const(v)
	elif (target_isa == 1): arm64_push_imm(v)
	else:
		emit_int8(104)
		emit_int32(v)


/* mov eax,[eax] */
void promote_eax():
	if (target_isa == 3): ptx_ld_ax(c".u64")
	elif (target_isa == 2): wasm_promote_eax_op(0x28)
	elif (target_isa == 1): arm64_promote_acc(op(0xf9, 0x400000))   # ldr x0,[x0]
	else:
		# A register-resident local: its "load" is a register move
		if ((reg_lvalue_end != 0) && (reg_lvalue_end == codepos)):
			mov_eax_reg(regalloc_note_take())
			return
		if ((lea_note_end != 0) && (lea_note_end == codepos)):
			if (word_size == 8): lea_load_fold(2, c"\x48\x8b")
			else: lea_load_fold(1, c"\x8b")
			return
		if ((addr_note_end != 0) && (addr_note_end == codepos)):
			addr_load_fold(word_size == 8, 1, c"\x8b")
			return
		plain_load(word_size == 8, 1, c"\x8b")


/* mov ebx,[ebx] */
void promote_ebx():
	if (target_isa == 3): ptx_promote_bx()
	elif (target_isa == 2): wasm_promote_ebx()
	elif (target_isa == 1): a64(op(0xf9, 0x400021))   # ldr x1,[x1]
	else:
		emit_x64_opcode()
		emit(2, c"\x8b\x1b")


/* movsx eax, byte [eax] */
void promote_int8_eax():
	if (target_isa == 3): ptx_ld_ax(c".s8")
	elif (target_isa == 2): wasm_promote_eax_op(0x2c)
	elif (target_isa == 1): arm64_promote_acc(op(0x39, 0x800000))   # ldrsb x0,[x0]
	else:
		if ((lea_note_end != 0) && (lea_note_end == codepos)):
			if (word_size == 8): lea_load_fold(3, c"\x48\x0f\xbe")
			else: lea_load_fold(2, c"\x0f\xbe")
			return
		if ((addr_note_end != 0) && (addr_note_end == codepos)):
			addr_load_fold(word_size == 8, 2, c"\x0f\xbe")
			return
		plain_load(word_size == 8, 2, c"\x0f\xbe")


/* movsx eax, word [eax] */
void promote_int16_eax():
	if (target_isa == 3): ptx_ld_ax(c".s16")
	elif (target_isa == 2): wasm_promote_eax_op(0x2e)
	elif (target_isa == 1): arm64_promote_acc(op(0x79, 0x800000))   # ldrsh x0,[x0]
	else:
		if ((lea_note_end != 0) && (lea_note_end == codepos)):
			if (word_size == 8): lea_load_fold(3, c"\x48\x0f\xbf")
			else: lea_load_fold(2, c"\x0f\xbf")
			return
		if ((addr_note_end != 0) && (addr_note_end == codepos)):
			addr_load_fold(word_size == 8, 2, c"\x0f\xbf")
			return
		plain_load(word_size == 8, 2, c"\x0f\xbf")


/* x86: mov eax,[eax] ; x64: movsxd rax, dword [rax] (4-byte int32 load) */
void promote_int32_eax():
	if (target_isa == 3): ptx_ld_ax(c".s32")
	elif (target_isa == 2): wasm_promote_eax_op(0x28)
	elif (target_isa == 1): arm64_promote_acc(op(0xb9, 0x800000))   # ldrsw x0,[x0]
	else:
		# x86-32: 'int' is the 4-byte word, so a promoted int reads here
		if ((reg_lvalue_end != 0) && (reg_lvalue_end == codepos)):
			mov_eax_reg(regalloc_note_take())
			return
		if ((lea_note_end != 0) && (lea_note_end == codepos)):
			if (word_size == 8): lea_load_fold(2, c"\x48\x63")
			else: lea_load_fold(1, c"\x8b")
			return
		if ((addr_note_end != 0) && (addr_note_end == codepos)):
			if (word_size == 8): addr_load_fold(1, 1, c"\x63")
			else: addr_load_fold(0, 1, c"\x8b")
			return
		if (word_size == 8): plain_load(1, 1, c"\x63")
		else: plain_load(0, 1, c"\x8b")


/* mov %eax,(%ebx) */
void store_ebx_int32():
	if (target_isa == 3): ptx_st_bx(c".u32")
	elif (target_isa == 2): wasm_store_ebx_op(0x36)
	elif (target_isa == 1): a64(op(0xb9, 0x000020))   # str w0,[x1]
	else: emit(2, c"\x89\x03")


/* mov [ebx],eax at the full word width (4 bytes on x86, 8 on x64) */
void store_ebx_word():
	if (target_isa == 3): ptx_st_bx(c".u64")
	elif (target_isa == 2): wasm_store_ebx_op(0x36)
	elif (target_isa == 1): a64(op(0xf9, 0x000020))   # str x0,[x1]
	else:
		emit_x64_opcode()
		emit(2, c"\x89\x03")


/* mov %ax,(%ebx) */
void store_ebx_int16():
	if (target_isa == 3): ptx_st_bx(c".u16")
	elif (target_isa == 2): wasm_store_ebx_op(0x3b)
	elif (target_isa == 1): a64(op(0x79, 0x000020))   # strh w0,[x1]
	else: emit(3, c"\x66\x89\x03")


/* mov %al,(%ebx) */
void store_ebx_int8():
	if (target_isa == 3): ptx_st_bx(c".u8")
	elif (target_isa == 2): wasm_store_ebx_op(0x3a)
	elif (target_isa == 1): a64(op(0x39, 0x000020))   # strb w0,[x1]
	else: emit(2, c"\x88\x03")


# Constant folding (docs/projects/optimization.md's v0 window, same shape
# as the cmp_fuse_* note further down). mov_eax_int notes where it put an
# immediate and what the value was; a consumer running while the note is
# still CURRENT -- nothing emitted since, so imm_note_end == codepos --
# rolls the materialization back and folds its own operand into it.
#
# Only mov_eax_int sets the note, which is what makes this safe: the other
# producer of a 'mov $imm32,%eax' is be_addr_slot_emit (code_generator/
# arm64.w), whose immediate is a backpatch slot rewritten later, and it
# emits its own bytes without coming through here. No mov_eax_int caller
# patches its immediate.
#
# Everything is fail-closed. Any emission the fold did not expect advances
# codepos, the == check stops matching, and the plain path runs.
#
# ARM64 also notes literal materializations for its operand shuttle.
# Its move-wide sequences have no external patches and can be re-emitted;
# wasm remains stateful and does not participate.
# (imm_note_*, push_imm_* and binfold_* are declared with the other
# notes at the top of the file: the A2 memory-operand helpers read them.)

# Invalidate every note. Must be called wherever codepos moves backward
# (REPL/wdbg checkpoint rollback), exactly like be_cmp_note_reset: a stale
# note aliasing a later codepos would let a fold roll back over bytes that
# are not a constant materialization.
void be_imm_note_reset():
	imm_note_end = 0
	push_imm_end = 0
	binfold_end = 0
	lea_note_end = 0
	load_note_end = 0
	push_note_end = 0
	reg_lvalue_end = 0
	regload_note_end = 0
	shuttle_end = 0
	binop_end = 0
	addr_note_end = 0
	memload_end = 0

# True when a * b does not overflow the compiler's own word. The fold has
# to produce the same constant whether this compiler is the 32-bit or the
# 64-bit self-host, or verify and verify_x64 stop agreeing, so a product
# that wraps here must fall back to the runtime imul. A target narrower
# than the host is not a hazard: mov_eax_int32 writes the low 32 bits,
# which is what a 32-bit imul would have produced anyway.
#
# -1 is rejected rather than checked: the division probe would have to
# evaluate INT_MIN / -1, which traps on x86 rather than wrapping.
int fold_mul_fits(int a, int b):
	if ((a == 0) || (b == 0)): return 1
	if ((a == -1) || (b == -1)): return 0
	int p = a * b
	if (p / b != a): return 0
	return p / a == b

# True when a + b does not overflow the compiler's own word, same reason.
int fold_add_fits(int a, int b):
	int sum = a + b
	if ((b > 0) && (sum < a)): return 0
	if ((b < 0) && (sum > a)): return 0
	return 1

# True when a - b does not overflow the compiler's own word, same reason.
int fold_sub_fits(int a, int b):
	int diff = a - b
	if ((b < 0) && (diff < a)): return 0
	if ((b > 0) && (diff > a)): return 0
	return 1

void mov_eax_int(int v);

# Consume an armed two-operand fold: roll back over the left constant, the
# push and the right constant, and put the result there instead. Callers
# test binfold_end themselves, so the common unarmed path costs two global
# reads and no call.
void binfold_emit(int folded):
	peep_rollback(binfold_start)
	mov_eax_int(folded)


# ARM64 uses the same adjacency and rollback barriers as the x86 folds.
# Its load note stores the A64 opcode in load_note_oplen (load_note_op
# is unused); no note survives a target change or compiler checkpoint.
void arm64_lea_note(int start, int k):
	lea_note_start = start
	lea_note_end = codepos
	lea_note_disp = k


int arm64_add_local_offset(int v):
	if ((lea_note_end == 0) || (lea_note_end != codepos)): return 0
	if (fold_add_fits(lea_note_disp, v) == 0): return 0
	int disp = lea_note_disp + v
	peep_rollback(lea_note_start)
	arm64_lea_eax_esp_plus(disp)
	return 1


# Scaled unsigned-offset loads preserve the original signed/unsigned
# load opcode. Unaligned, negative, or out-of-range addresses keep the
# ordinary address materialization and load through x0.
int arm64_load_offset_fits(int instruction, int disp):
	int scale = (instruction >> 30) & 3
	if (disp < 0): return 0
	if ((disp & ((1 << scale) - 1)) != 0): return 0
	return (disp >> scale) <= 4095


void arm64_emit_local_load(int instruction, int disp):
	load_note_start = codepos
	a64(instruction | (28 << 5) | ((disp >> ((instruction >> 30) & 3)) << 10))
	load_note_end = codepos
	load_note_disp = disp
	load_note_oplen = instruction


void arm64_promote_acc(int instruction):
	if ((lea_note_end != 0) && (lea_note_end == codepos)):
		int disp = lea_note_disp
		if (arm64_load_offset_fits(instruction, disp)):
			peep_rollback(lea_note_start)
			arm64_emit_local_load(instruction, disp)
			return
	a64(instruction)


void arm64_push_acc():
	push_note_start = codepos
	a64(op(0xf8, 0x1f8f80))   # str x0,[x28,#-8]!
	push_note_end = codepos


# Replace push; literal/local load; pop with mov x1,x0; RHS. Only
# the known RHS may be crossed: calls, nested pushes and labels stop
# matching. Removing the push lowers a local's displacement by 8.
void arm64_pop_secondary():
	if (push_note_end != 0):
		int kind = 0
		int value = imm_note_value
		int disp = load_note_disp - 8
		int instruction = load_note_oplen
		if ((imm_note_end != 0) && (imm_note_end == codepos) && (imm_note_start == push_note_end)): kind = 1
		elif ((load_note_end != 0) && (load_note_end == codepos) && (load_note_start == push_note_end) && (load_note_disp >= 8)): kind = 2
		if (kind != 0):
			peep_rollback(push_note_start)
			a64(op(0xaa, 0x0003e1))   # mov x1,x0
			if (kind == 1): arm64_mov_rax_int64(value)
			else: arm64_emit_local_load(instruction, disp)
			# The RHS is no longer adjacent to any outstanding push.
			imm_note_end = 0
			push_note_end = 0
			return
	a64(op(0xf8, 0x408781))   # ldr x1,[x28],#8


/* mov eax, op(0x12, 0x345678); zero is 'xor eax,eax' (A2: two bytes,
   zero-extends on x64; it clobbers the flags, which no emitter keeps live
   across a value materialization) */
void mov_eax_int32(int v):
	if (target_isa == 3): ptx_mov_ax_int(v)
	elif (target_isa == 2): wasm_mov_eax_int(v)
	elif (target_isa == 1): arm64_mov_eax_int32(v)
	elif ((v == 0) && (addr_modes_disabled == 0)): emit(2, c"\x31\xc0")
	else:
		emit(1, c"\xb8")
		emit_int32(v)


/* mov rax, 0x1234567890123456 */
void mov_rax_int64(int v):
	if (target_isa == 3): ptx_mov_ax_int(v)
	elif (target_isa == 1): arm64_mov_rax_int64(v)
	else:
		emit_x64_opcode()
		emit(1, c"\xb8")
		emit_int64(v)


/* mov rax, imm64 with the immediate given as two 32-bit halves. The
   compiler itself may run as a 32-bit process, where a single int cannot
   carry a full 64-bit pattern (e.g. float64 literal bits). */
void mov_rax_int64_halves(int lo, int hi):
	if (target_isa == 3): ptx_mov_ax_int64_halves(lo, hi)
	elif (target_isa == 1): arm64_mov_rax_int64_halves(lo, hi)
	else:
		emit(2, c"\x48\xb8")
		emit_int32(lo)
		emit_int32(hi)


/* xor eax, imm32; on x64 this also zeroes the upper half of rax */
void xor_eax_int32(int v):
	if (target_isa == 3): ptx_xor_ax_int32(v)
	elif (target_isa == 2): wasm_ax_op_const(0x73, v)
	elif (target_isa == 1):
		# Only w9's low 32 bits reach the eor, but the scratch load spills
		# v into an 8-byte literal, and a bit-31 value (the float sign
		# mask) folds positive on a 64-bit host and negative on the 32-bit
		# seed — breaking the arm64 self-host fixpoint. Canonicalize to
		# the sign-extended-32 form both hosts can represent.
		int high = (v >> 31) & 1
		v = v & 2147483647
		if (high): v = v - 2147483647 - 1
		arm64_load_scratch(9, v)
		a64(op(0x4a, 0x090000))   # eor w0,w0,w9 (zero-extends upper half)
	else:
		emit(1, c"\x35")
		emit_int32(v)


/* movzx eax, byte [eax]: a zero-extending 8-bit load, for uint8 */
void promote_uint8_eax():
	if (target_isa == 3): ptx_ld_ax(c".u8")
	elif (target_isa == 2): wasm_promote_eax_op(0x2d)
	elif (target_isa == 1): arm64_promote_acc(op(0x39, 0x400000))   # ldrb w0,[x0]
	else:
		if ((lea_note_end != 0) && (lea_note_end == codepos)):
			lea_load_fold(2, c"\x0f\xb6")
			return
		if ((addr_note_end != 0) && (addr_note_end == codepos)):
			addr_load_fold(0, 2, c"\x0f\xb6")
			return
		plain_load(0, 2, c"\x0f\xb6")


/* Zero-extending 32-bit load, for uint32: a plain 32-bit mov already
   zero-extends into rax on x64 (and is the full word on x86), where the
   promote_int32 path's movsxd would sign-extend a high-bit value. */
void promote_uint32_eax():
	if (target_isa == 3): ptx_ld_ax(c".u32")
	elif (target_isa == 2): wasm_promote_eax_op(0x28)
	elif (target_isa == 1): arm64_promote_acc(op(0xb9, 0x400000))   # ldr w0,[x0]
	else:
		if ((reg_lvalue_end != 0) && (reg_lvalue_end == codepos)):
			mov_eax_reg(regalloc_note_take())
			return
		if ((lea_note_end != 0) && (lea_note_end == codepos)):
			lea_load_fold(1, c"\x8b")
			return
		if ((addr_note_end != 0) && (addr_note_end == codepos)):
			addr_load_fold(0, 1, c"\x8b")
			return
		plain_load(0, 1, c"\x8b")


/* movzx eax, word [eax]: a zero-extending 16-bit load. The promote_int16
   path sign-extends, which would corrupt float16 bit patterns. */
void promote_uint16_eax():
	if (target_isa == 3): ptx_ld_ax(c".u16")
	elif (target_isa == 2): wasm_promote_eax_op(0x2f)
	elif (target_isa == 1): arm64_promote_acc(op(0x79, 0x400000))   # ldrh w0,[x0]
	else:
		if ((lea_note_end != 0) && (lea_note_end == codepos)):
			lea_load_fold(2, c"\x0f\xb7")
			return
		if ((addr_note_end != 0) && (addr_note_end == codepos)):
			addr_load_fold(0, 2, c"\x0f\xb7")
			return
		plain_load(0, 2, c"\x0f\xb7")


/* mov eax, imm32 -- on x64 too for a value in [0, 2^31), where the 32-bit
   write zero-extends into rax (5 bytes instead of the 10-byte movabs);
   anything else (negative, or past 2^31 on a 64-bit host) keeps the
   imm64 form. The test is host-independent: a 32-bit compiler cannot
   hold a value that the 64-bit one would classify differently, and the
   literals with bit 31 set are negative on both (CLAUDE.md). A negative
   value takes the 7-byte sign-extending simm32 form (REX.W C7 /0, A2;
   libs/asm decodes and re-encodes it byte-exact), the rest of the 64-bit
   range the movabs. */
void mov_eax_int(int v):
	if (target_isa == 2): wasm_mov_eax_int(v)
	elif (target_isa == 1):
		imm_note_start = codepos
		arm64_mov_rax_int64(v)
		imm_note_end = codepos
		imm_note_value = v
	else:
		int start = codepos
		if ((word_size == 8) && ((v >> 31) == -1) && (addr_modes_disabled == 0)):
			# mov rax,simm32 (REX.W C7 /0 id): 7 bytes for a negative
			# value instead of the 10-byte movabs (A2; libs/asm decodes
			# C7 /0 since the unit)
			emit(3, c"\x48\xc7\xc0")
			emit_int32(v)
		elif ((word_size == 8) && ((v >> 31) != 0)): mov_rax_int64(v)
		else: mov_eax_int32(v)
		# PTX also reaches here (it has no early return above) but does not
		# advance codepos, so note it only for the x86 family. Every consumer
		# already early-returns on the other ISAs; this keeps the invariant
		# true where it is stated rather than only where it is enforced.
		if (target_isa == 0):
			imm_note_start = start
			imm_note_end = codepos
			imm_note_value = v


void add_eax_int32(int v):
	if (target_isa == 3): ptx_add_ax_int(v)
	elif (target_isa == 2): wasm_ax_op_const(0x6a, v)
	elif (target_isa == 1): arm64_add_eax_int32(v)
	else:
		if ((imm_note_end != 0) && (imm_note_end == codepos)):
			if (fold_add_fits(imm_note_value, v)):
				int folded = imm_note_value + v
				peep_rollback(imm_note_start)
				mov_eax_int(folded)
				return
		# Adding zero is a no-op; emitting nothing also keeps a current lea
		# or constant note current for the load that usually follows.
		if (v == 0): return
		# A constant offset from a local's address: fold it into the lea.
		if ((lea_note_end != 0) && (lea_note_end == codepos)):
			if (fold_add_fits(lea_note_disp, v)):
				int disp = lea_note_disp + v
				peep_rollback(lea_note_start)
				lea_eax_esp_plus(disp)
				return
		# A2: an offset from an address the note describes ('p.a.b',
		# 'a[i].f') grows its displacement; from a register-resident
		# pointer ('p.f', 'mov eax,R' directly before) it is one lea;
		# anything else keeps 'add eax,off', noted as [eax+off].
		if (addr_modes_disabled):
			emit_x64_opcode()
			emit(1, c"\x05") /* \x2d add eax,... */
			emit_int32(v)
			return
		if ((addr_note_end != 0) && (addr_note_end == codepos)):
			if (fold_add_fits(addr_note_disp, v) && disp_fits(addr_note_disp + v)):
				int abase = addr_note_base
				int aindex = addr_note_index
				int ascale = addr_note_scale
				int adisp = addr_note_disp + v
				peep_rollback(addr_note_start)
				addr_form(abase, aindex, ascale, adisp)
				return
		if ((regload_note_end != 0) && (regload_note_end == codepos)):
			int r = regload_note_reg
			peep_rollback(regload_note_start)
			addr_form(r, -1, 1, v)
			return
		addr_form(0, -1, 1, v)


/* imul eax, eax, imm32 */
void imul_eax_int32(int v):
	if (target_isa == 3): ptx_mul_ax_int(v)
	elif (target_isa == 2): wasm_ax_op_const(0x6c, v)
	elif (target_isa == 1): arm64_imul_eax_int32(v)
	else:
		if ((imm_note_end != 0) && (imm_note_end == codepos)):
			if (fold_mul_fits(imm_note_value, v)):
				int folded = imm_note_value * v
				peep_rollback(imm_note_start)
				mov_eax_int(folded)
				return
		emit_x64_opcode()
		emit(2, c"\x69\xc0")
		emit_int32(v)


# Bumped once per machine call instruction actually emitted: by this
# function (every ordinary/indirect W call, and every builtin container
# op routed through grammar/stack_slot.w's rt_call_end, operator
# overload dispatch, generator resumption, or a 'new' allocation's
# implicit malloc — they all funnel through call_eax) and by
# code_generator/ffi.w's emit_ffi_call_inline (the one FFI call path
# that bypasses call_eax, used for variadic C imports). Declared here,
# ahead of grammar in the import order, so grammar/binary_op.w's
# operand_is_pure can read it: it snapshots this counter around an
# operand's parse to tell the '&'/'|' bool-bitwise condition hint
# whether the operand executed any call at all.
int emitted_call_count


void call_eax():
	if (target_isa == 3): error(c"gpu code cannot call functions")
	else:
		emitted_call_count = emitted_call_count + 1
		if (target_isa == 2):
			wasm_call_eax()
			return
		if (target_isa == 1):
			if (arm64_pac == 2):
				# pac=full: every W code pointer was paciza-signed at
				# materialization (be_code_ptr_sign), so authenticate and
				# branch. A forged pointer traps here on FPAC hardware.
				a64(op(0xd6, 0x3f081f))   # blraaz x0
				return
			a64(op(0xd6, 0x3f0000))   # blr x0
			return
		# Loop-owned caller-saved registers survive the callee through
		# their homes (R3); nothing is emitted when no loop owns any.
		inline_real_calls = inline_real_calls + 1
		regalloc_call_spill()
		emit(2, c"\xff\xd0") /* call *%eax */
		regalloc_call_reload()


void call_relative32(int v):
	emit(1, c"\xe8")
	emit_int32(v)


# Direct calls (docs/projects/codegen_gap_plan.md §2.4, unit A4): one
# `call rel32` to a W function whose arguments are already pushed, in
# place of call_eax's materialize/park/reload sequence. call_direct_to
# targets a code address that is known; call_direct_link leaves the
# displacement cell on a rel32 backpatch chain (the cell holds the
# previous cell's absolute address, code_offset ends the chain, exactly
# like the mov-imm chains of compiler/symbol_table.w) that
# rel_chain_patch resolves once the callee is defined. Both park the
# loop-owned registers around the call like call_eax and count for
# emitted_call_count. x86 family only: the callers check target_isa.
# Each returns the displacement cell -- its buffer offset for the known
# target, the new chain head (absolute) for the linked one -- so the
# REPL's late-binding registry can record it before the reload moves
# codepos on.
int call_direct_to(int v):
	emitted_call_count = emitted_call_count + 1
	inline_real_calls = inline_real_calls + 1
	regalloc_call_spill()
	call_relative32(v - (code_offset + codepos + 5))
	int slot = codepos - 4
	regalloc_call_reload()
	return slot


int call_direct_link(int head):
	if (head == 0): head = code_offset
	emitted_call_count = emitted_call_count + 1
	inline_real_calls = inline_real_calls + 1
	regalloc_call_spill()
	call_relative32(head)
	int slot = codepos + code_offset - 4
	regalloc_call_reload()
	return slot


void not_eax():
	if (target_isa == 3): ptx_not_ax()
	elif (target_isa == 2): wasm_not_eax()
	elif (target_isa == 1): a64(op(0xaa, 0x2003e0))   # mvn x0,x0
	else:
		emit_x64_opcode()
		emit(2, c"\xf7\xd0") /* not eax */


/* push eax */
void push_eax():
	if (target_isa == 3): ptx_push_ax()
	elif (target_isa == 2): wasm_push_eax()
	elif (target_isa == 1): arm64_push_acc()
	else:
		# Inlined rather than calling imm_note_current(): W has no inliner and
		# this is one of the hottest emitters in the compiler. target_isa == 0
		# is already established by the early returns above.
		int carried = 0
		if ((imm_note_end != 0) && (imm_note_end == codepos)): carried = 1
		int start = imm_note_start
		int value = imm_note_value
		# The pushed value came straight from a register-resident local
		# ('mov eax,R' is the instruction before the push): pop_ebx can
		# shuttle it as 'mov ebx,R' and an operator can read R itself.
		push_left_reg = 0
		if ((regload_note_end != 0) && (regload_note_end == codepos)):
			push_left_reg = regload_note_reg
			push_left_start = regload_note_start
		push_note_start = codepos
		emit(1, c"\x50")
		push_note_end = codepos
		push_imm_end = 0
		if (carried):
			push_imm_start = start
			push_imm_end = codepos
			push_imm_value = value


void push_ebx():
	if (target_isa == 3): ptx_push_bx()
	elif (target_isa == 2): wasm_push_ebx()
	elif (target_isa == 1): a64(op(0xf8, 0x1f8f81))   # str x1,[x28,#-8]!
	else: emit(1, c"\x53")


void pop_ebx():
	if (target_isa == 3): ptx_pop_bx()
	elif (target_isa == 2): wasm_pop_ebx()
	elif (target_isa == 1): arm64_pop_secondary()
	else:
		# Both operands constant, and the right one emitted EXACTLY one mov
		# directly after the push (push_imm_end == imm_note_start) -- so the
		# span from the left constant to here is mov, push, mov, and nothing
		# else can be hiding in it.
		int armed = 0
		if ((imm_note_end != 0) && (imm_note_end == codepos)):
			if ((push_imm_end != 0) && (push_imm_end == imm_note_start)): armed = 1
		int left = push_imm_value
		int right = imm_note_value
		int start = push_imm_start
		# Register shuttle: 'push eax; <one simple instruction>; pop ebx' --
		# the right operand a constant or a folded local load emitted directly
		# after the push -- becomes 'mov ebx,eax; <instruction>'. Without the
		# push the local's esp displacement shrinks by one word; a load of the
		# pushed temporary itself (disp < word_size) is left alone.
		if ((armed == 0) && (push_note_end != 0)):
			# Which simple right operand followed the push: 1 a constant
			# (one the x64 ALU immediate forms can carry: a signed
			# 32-bit value), 2 a local load, 3 a register read.
			int kind = 0
			int value = right
			int disp = load_note_disp - word_size
			int oplen = load_note_oplen
			char* op = load_note_op
			int reg = regload_note_reg
			if ((imm_note_end != 0) && (imm_note_end == codepos) && (imm_note_start == push_note_end)):
				kind = 1
			elif ((load_note_end != 0) && (load_note_end == codepos) && (load_note_start == push_note_end) && (load_note_disp >= word_size)):
				kind = 2
			elif ((regload_note_end != 0) && (regload_note_end == codepos) && (regload_note_start == push_note_end)):
				kind = 3
			if (kind != 0):
				int left_reg = push_left_reg
				int left_start = push_left_start
				peep_rollback(push_note_start)
				# The left operand read a register: shuttle it directly
				# (R3) instead of through the accumulator.
				if (left_reg != 0): peep_rollback(left_start)
				int start = codepos
				if (left_reg != 0): mov_ebx_reg(left_reg)
				else:
					emit_x64_opcode()
					emit(2, c"\x89\xc3") /* mov ebx,eax */
				if (kind == 1): mov_eax_int(value)
				elif (kind == 2): emit_esp_load(oplen, op, disp)
				else: mov_eax_reg(reg)
				imm_note_end = 0
				push_imm_end = 0
				binfold_end = 0
				shuttle_start = start
				shuttle_end = codepos
				shuttle_kind = kind
				shuttle_left_reg = left_reg
				shuttle_value = value
				shuttle_disp = disp
				shuttle_oplen = oplen
				shuttle_op = op
				shuttle_reg = reg
				# A 64-bit constant has no immediate ALU form
				if ((kind == 1) && (word_size == 8) && ((value >> 31) != 0) && ((value >> 31) != -1)): shuttle_end = 0
				# Only the word-sized load folds into an ALU operand
				if (kind == 2):
					if (word_size == 8):
						if ((oplen != 2) || ((op[0] & 255) != 0x48) || ((op[1] & 255) != 0x8b)): shuttle_end = 0
					elif ((oplen != 1) || ((op[0] & 255) != 0x8b)): shuttle_end = 0
				return
		emit(1, c"\x5b")
		imm_note_end = 0
		push_imm_end = 0
		binfold_end = 0
		if (armed):
			binfold_start = start
			binfold_end = codepos
			binfold_left = left
			binfold_right = right


void pop_eax():
	if (target_isa == 3): ptx_pop_ax()
	elif (target_isa == 2): wasm_pop_eax()
	elif (target_isa == 1): a64(op(0xf8, 0x408780))   # ldr x0,[x28],#8
	else: emit(1, c"\x58")


/* mov eax, ebx */
void mov_eax_ebx():
	if (target_isa == 3): ptx_mov_ax_bx()
	elif (target_isa == 2): wasm_mov_eax_ebx()
	elif (target_isa == 1): a64(op(0xaa, 0x0103e0))   # mov x0,x1
	else:
		emit_x64_opcode()
		emit(2, c"\x89\xd8")


/* lea eax,[esp+disp], disp8 when it fits (the loads that fold this lea
   already pick the short form through emit_eax_esp_disp). The note
   records positions, not a length, so lea_load_fold and the add_eax_int32
   re-emission are unaffected by the width. */
void lea_eax_esp_plus(int v):
	if (target_isa == 3): ptx_lea_ax_sp(v)
	elif (target_isa == 2): wasm_lea_eax_esp_plus(v)
	elif (target_isa == 1): arm64_lea_eax_esp_plus(v)
	else:
		int start = codepos
		emit_x64_opcode()
		emit(1, c"\x8d")
		emit_eax_esp_disp(v)
		lea_note_start = start
		lea_note_end = codepos
		lea_note_disp = v


/* mov eax,[esp+op(0x12, 0x345678)] */
void mov_eax_esp_plus(int v):
	if (target_isa == 3): ptx_ld_ax_sp(v)
	elif (target_isa == 2): wasm_mov_eax_esp_plus(v)
	elif (target_isa == 1): arm64_ldr_reg_wsp(0, v)
	else:
		# Noted like a folded local load, so a slot read as the right
		# operand of a binary operator (a range loop's end slot against
		# its loop variable, say) takes pop_ebx's register shuttle too.
		if (word_size == 8): emit_esp_load(2, c"\x48\x8b", v)
		else: emit_esp_load(1, c"\x8b", v)


/* mov ebx,[esp] */
void mov_ebx_esp():
	if (target_isa == 3): ptx_ld_bx_sp(0)
	elif (target_isa == 2): wasm_mov_ebx_esp()
	elif (target_isa == 1): a64(op(0xf9, 0x400381))   # ldr x1,[x28]
	else:
		emit_x64_opcode()
		emit(3, c"\x8b\x1c\x24")


/* mov ebx,[esp+op(0x12, 0x345678)] */
void mov_ebx_esp_plus(int v):
	if (target_isa == 3): ptx_ld_bx_sp(v)
	elif (target_isa == 2): wasm_mov_ebx_esp_plus(v)
	elif (target_isa == 1): arm64_ldr_reg_wsp(1, v)
	else:
		emit_x64_opcode()
		emit(3, c"\x8b\x9c\x24")
		emit_int(v)


/* add ebx, op(0x12, 0x345678) */
void add_ebx_int32(int v):
	if (target_isa == 3): ptx_add_bx_int(v)
	elif (target_isa == 2): wasm_add_ebx_int(v)
	elif (target_isa == 1): arm64_add_ebx_int32(v)
	else:
		emit_x64_opcode()
		emit(2, c"\x81\xc3")
		emit_int32(v)


/* push dword [eax+op(0x12, 0x345678)] */
void push_eax_plus(int v):
	if (target_isa == 3): ptx_push_ax_plus(v)
	elif (target_isa == 2): wasm_push_eax_plus(v)
	elif (target_isa == 1): arm64_push_eax_plus(v)
	else:
		emit(2, c"\xff\xb0")
		emit_int32(v)


/* mov [esp+op(0x12, 0x345678)], eax */
void store_stack_var(int variable_offset):
	if (target_isa == 3): ptx_st_sp_ax(variable_offset)
	elif (target_isa == 2): wasm_store_stack_var(variable_offset)
	elif (target_isa == 1): arm64_str_reg_wsp(0, variable_offset)
	else:
		emit_x64_opcode()
		emit(3, c"\x89\x84\x24")
		emit_int(variable_offset)


/* mov [esp+op(0x12, 0x345678)], ebx */
void store_ebx_stack_var(int variable_offset):
	if (target_isa == 3): ptx_st_sp_bx(variable_offset)
	elif (target_isa == 2): wasm_store_ebx_stack_var(variable_offset)
	elif (target_isa == 1): arm64_str_reg_wsp(1, variable_offset)
	else:
		emit_x64_opcode()
		emit(3, c"\x89\x9c\x24")
		emit_int(variable_offset)


/* add esp, (n * word_size). Popping nothing emits nothing: the block-end
   pop of a scope that held no locals was 'add esp,0' at 2.3% of the
   instructions in bin/wv3 (docs/projects/register_allocation_pgo.md
   §1.1, unit R1). The site may be a jump target, but an instruction that
   emits nothing only moves the label; the sp-relative notes above stay
   valid across it because the stack does not move. */
void be_pop(int n):
	if (n == 0): return
	if (target_isa == 3): ptx_be_pop(n)
	elif (target_isa == 2): wasm_be_pop(n)
	elif (target_isa == 1): arm64_be_pop(n)
	else:
		emit_x64_opcode()
		emit(6, c"\x81\xc4....")
		save_int(code + codepos - 4, n << word_size_log2)


void jmp_zero_int32(int v):
	if (target_isa == 1): arm64_emit_cbz(v)   # cbz x0, <link/placeholder>
	else:
		emit_x64_opcode()
		emit(4, c"\x85\xc0\x0f\x84") /* test %eax,%eax ; je ... */
		emit_int32(v)


void jmp_nonzero_int32(int v):
	if (target_isa == 1): arm64_emit_cbnz(v)   # cbnz x0, <link/placeholder>
	else:
		emit_x64_opcode()
		emit(4, c"\x85\xc0\x0f\x85") /* test %eax,%eax ; jne ... */
		emit_int32(v)


void jmp_int32(int v):
	if (target_isa == 1): arm64_emit_b(v)   # b <link/placeholder>
	else:
		emit(1, c"\xe9") /* jmp ... */
		emit_int32(v)


########################### inline data blob regions ##########################
# A blob region wraps grammar-side emission of raw data words through the
# ordinary code helpers (grammar/json_builtin.w's to_json/from_json
# descriptor blobs). On the native targets the blob stays in the
# instruction stream behind an unconditional jump — byte-identical to the
# classic jmp_int32 + be_branch_patch pair. On wasm code is not readable
# memory, so the region instead redirects the emission cursor into the RW
# data buffer (code_generator/wasm.w) and no jump exists at all. PIE
# uses the same cursor swap so descriptor pointers can be relocated;
# code_offset + codepos yields linear-memory addresses either way.

int be_blob_begin():
	if ((target_isa == 2) || elf_pie):
		be_notes_reset()
		wasm_blob_begin()
		return 0
	jmp_int32(1337030)
	return codepos


# A pointer word inside a descriptor blob. PIE blobs live in data;
# ordinary integers (lengths, kinds, offsets) must never be rebased.
void be_blob_pointer(int v):
	if (elf_pie && (v != 0)): rebase_note(code_offset + codepos)
	emit_target_word(v)


void be_blob_end(int p):
	if ((target_isa == 2) || elf_pie):
		wasm_blob_end()
		be_notes_reset()
	else:
		# The blob holds unaligned bytes; realign so the jump lands on an
		# instruction boundary (a no-op on x86).
		be_align_code()
		be_notes_reset()
		be_branch_patch(p, codepos)


###################### structured control-flow regions ########################
# The grammar's branch protocol (docs/projects/wasm_backend.md D3). Every
# forward jump the grammar emits targets the end of an enclosing region
# opened earlier, and every backward jump targets the start of an enclosing
# region — W has no goto, so this covers all of them. Expressing that
# structure explicitly is what lets a target without arbitrary branches
# (WebAssembly's block/loop/br) lower control flow at all; on x86/x64/arm64
# the helpers reproduce the original jump-and-patch bytes exactly, so those
# targets are unaffected.
#
# Protocol: be_ctrl_block() opens a forward-merge region whose branches land
# at its be_ctrl_end(); be_ctrl_loop() opens a backward region whose
# branches land at its start. be_br* branch to an open region by handle.
# Regions strictly nest: be_ctrl_end pops the most recently opened region
# (LIFO), which is what lets a wasm backend compute label depths at branch
# time. On x86/x64/arm64, block regions keep the classic patch chain
# (each site's displacement field holds the previous site's codepos, 0 ends
# the chain) resolved at be_ctrl_end; loop regions record their start and
# patch each branch immediately.

int* ctrl_kind_stack    # 0 = forward merge (block), 1 = backward (loop)
int* ctrl_val_stack     # block: patch-chain head; loop: start codepos
int* ctrl_tag_stack     # 0 = plain; 1 / 2 = a condition chain's false / true region (grammar/cond_branch.w)
int ctrl_stack_pos
int ctrl_stack_capacity

# Grown on demand so deeply nested control flow (an if whose body is
# another if, ...) is bounded by the tokenizer's nesting guard, not by a
# fixed array size. Entries are word-sized ints, so sizes use
# __word_size__ (not 4) -- the f13ab7f lesson: int-array byte counts halve
# a word-sized buffer on 64-bit hosts and corrupt the heap.
void ctrl_stack_reserve():
	if (ctrl_stack_capacity == 0):
		ctrl_stack_capacity = 256
		ctrl_kind_stack = cast(int*, malloc(ctrl_stack_capacity * __word_size__))
		ctrl_val_stack = cast(int*, malloc(ctrl_stack_capacity * __word_size__))
		ctrl_tag_stack = cast(int*, malloc(ctrl_stack_capacity * __word_size__))
		return
	if (ctrl_stack_pos >= ctrl_stack_capacity):
		int old = ctrl_stack_capacity * __word_size__
		ctrl_stack_capacity = ctrl_stack_capacity * 2
		int x = ctrl_stack_capacity * __word_size__
		ctrl_kind_stack = cast(int*, realloc(ctrl_kind_stack, old, x))
		ctrl_val_stack = cast(int*, realloc(ctrl_val_stack, old, x))
		ctrl_tag_stack = cast(int*, realloc(ctrl_tag_stack, old, x))

int be_ctrl_block():
	ctrl_stack_reserve()
	ctrl_kind_stack[ctrl_stack_pos] = 0
	ctrl_val_stack[ctrl_stack_pos] = 0
	ctrl_tag_stack[ctrl_stack_pos] = 0
	ctrl_stack_pos = ctrl_stack_pos + 1
	if (target_isa == 3):
		# The region's value is a PTX label id; its "Ln:" line lands at
		# the merge point in be_ctrl_end.
		ctrl_val_stack[ctrl_stack_pos - 1] = ptx_new_label()
	if (target_isa == 2): wasm_ctrl_block()
	return ctrl_stack_pos - 1

# A block region tagged for a condition chain (grammar/cond_branch.w):
# 1 collects the branches taken when the chain is false, 2 those taken
# when it is true. The consumer merges or ends it by the tag.
int be_ctrl_block_tagged(int tag):
	int h = be_ctrl_block()
	ctrl_tag_stack[h] = tag
	return h

int be_ctrl_loop():
	be_notes_reset()
	ctrl_stack_reserve()
	ctrl_kind_stack[ctrl_stack_pos] = 1
	ctrl_val_stack[ctrl_stack_pos] = codepos
	ctrl_tag_stack[ctrl_stack_pos] = 0
	ctrl_stack_pos = ctrl_stack_pos + 1
	if (target_isa == 3):
		# Backward region: the label is placed at the loop start, here.
		int ptx_loop_label = ptx_new_label()
		ctrl_val_stack[ctrl_stack_pos - 1] = ptx_loop_label
		ptx_place_label(ptx_loop_label)
	if (target_isa == 2): wasm_ctrl_loop()
	return ctrl_stack_pos - 1

# A branch site just emitted with region h's chain head in its displacement
# field becomes the new chain head (no-op for loop regions, which patch
# immediately). The bounds-check helpers below use this to thread their
# condition-coded branches through the same protocol.
void be_ctrl_link(int h):
	if (ctrl_kind_stack[h] == 0): ctrl_val_stack[h] = codepos

# The displacement field a new branch into region h starts with, and
# the bookkeeping once it is emitted: a loop region patches the branch to
# its start at once, a block region threads it into its patch chain.
int be_br_link(int h):
	if (ctrl_kind_stack[h]): return 0
	return ctrl_val_stack[h]

void be_br_linked(int h):
	if (ctrl_kind_stack[h]): be_branch_patch(codepos, ctrl_val_stack[h])
	else: be_ctrl_link(h)

# Branch to region h always (cond 0), or when the accumulator is zero
# (cond 1) or nonzero (cond 2).
void be_br_on(int cond, int h):
	if (target_isa == 3):
		if (cond == 0): ptx_bra(ctrl_val_stack[h])
		elif (cond == 1): ptx_bra_zero(ctrl_val_stack[h])
		else: ptx_bra_nonzero(ctrl_val_stack[h])
	elif (target_isa == 2): wasm_br_on(cond, ctrl_stack_pos - 1 - h)
	else:
		if (cond == 0): jmp_int32(be_br_link(h))
		elif (cond == 1): jmp_zero_int32(be_br_link(h))
		else: jmp_nonzero_int32(be_br_link(h))
		be_br_linked(h)

void be_br(int h):
	be_br_on(0, h)

void be_br_zero(int h):
	be_br_on(1, h)

void be_br_nonzero(int h):
	be_br_on(2, h)

# Comparison-branch fusion (docs/projects/optimization.md §1.3):
# alu_cmp_set notes where its setCC+movzx materialization begins and
# ends; a discard-context branch emitted while the note is current
# (nothing emitted in between) rolls the materialization back and
# branches on the cmp's flags directly — cmp;jCC instead of
# cmp;setCC;movzx;test;jCC on x86. ARM64 records its CSET instead,
# yielding CMP;B.cond rather than CMP;CSET;CBZ/CBNZ. Other ISAs take
# the plain path.
int cmp_fuse_start
int cmp_fuse_end
int cmp_fuse_cc

# Shared by the integer compare emitters; ARM64 records its CSET, x86
# records SETcc/MOVZX. The condition stays in the common setcc vocabulary.
void be_cmp_note_record(int start, int cc):
	cmp_fuse_start = start
	cmp_fuse_end = codepos
	cmp_fuse_cc = cc

# Invalidate the fusion note. Must be called wherever codepos moves
# backward (REPL/wdbg checkpoint rollback): a stale note aliasing a
# later codepos would otherwise let a discard branch roll back over
# bytes that are not a comparison.
void be_cmp_note_reset():
	cmp_fuse_end = 0

# Move codepos back to pos (a fold consuming the instructions after it)
# and drop every note that ended past pos: those notes described the
# bytes being discarded, and a stale end could otherwise alias a later
# codepos. Every fold's rollback goes through here.
void peep_rollback(int pos):
	codepos = pos
	if (imm_note_end > pos): imm_note_end = 0
	if (push_imm_end > pos): push_imm_end = 0
	if (binfold_end > pos): binfold_end = 0
	if (cmp_fuse_end > pos): cmp_fuse_end = 0
	if (lea_note_end > pos): lea_note_end = 0
	if (load_note_end > pos): load_note_end = 0
	if (push_note_end > pos): push_note_end = 0
	if (reg_lvalue_end > pos): reg_lvalue_end = 0
	if (direct_callee_end > pos): direct_callee_kind = 0
	if (regload_note_end > pos): regload_note_end = 0
	if (shuttle_end > pos): shuttle_end = 0
	if (binop_end > pos): binop_end = 0
	if (addr_note_end > pos): addr_note_end = 0
	if (memload_end > pos): memload_end = 0

# A jump target is about to be placed at codepos: no fold may reach back
# across it (a branch patched to land here would then point into, or
# past, the rewritten bytes).
void be_notes_reset():
	be_cmp_note_reset()
	be_imm_note_reset()

# jCC rel32 threading region h's chain protocol (the two cases of
# be_br_zero). x86 family only: callers have already checked target_isa.
void be_br_cc(int jcc_opcode, int h):
	emit_int8(15)
	emit_int8(jcc_opcode)
	emit_int32(be_br_link(h))
	be_br_linked(h)

# jCC condition codes pair via the low bit (0x84 je <-> 0x85 jne, ...)
int jcc_invert(int jcc_opcode):
	if (jcc_opcode & 1): return jcc_opcode - 1
	return jcc_opcode + 1

# A discard-context branch on a constant the immediately preceding
# mov_eax_int loaded ('while (1)', 'if (0)', the bottom test of a rotated
# constant-condition loop, docs/projects/codegen_gap_plan.md §2.5): the
# load is dropped and the branch becomes an unconditional jmp when the
# constant decides it is taken, or nothing at all when it never is. The
# accumulator is dead on both edges by the discard contract, so the
# dropped load is unobservable. x86 family only (the immediate note is),
# and part of unit A7: --no-loop-rotate keeps the test, so the opt-out
# emits exactly the pre-unit bytes. Returns 1 when it handled the branch.
int be_br_const_discard(int h, int on_nonzero):
	if ((target_isa != 0) || loop_rotate_disabled || (imm_note_end == 0) || (imm_note_end != codepos)): return 0
	int taken = (imm_note_value != 0) == on_nonzero
	peep_rollback(imm_note_start)
	imm_note_end = 0
	if (taken): be_br(h)
	return 1

# Discard-context twins of be_br_zero/be_br_nonzero for callers that
# never read the accumulator after the branch on either edge (if/while/
# for/switch/ternary conditions) — NOT &&/||, whose short-circuit edge
# carries the operand value in the accumulator to the booleanize step.
# When the accumulator holds a comparison materialized by the
# immediately preceding alu_cmp_set, drop the materialization and branch
# on the cmp's flags; a setCC opcode maps to its jCC twin by
# subtracting 0x10. ARM64 drops CSET and uses the same CMP flags in
# B.cond (the existing imm19 branch-link format).
void be_br_zero_discard(int h):
	if ((target_isa <= 1) && (cmp_fuse_end != 0) && (cmp_fuse_end == codepos)):
		int cc = cmp_fuse_cc
		peep_rollback(cmp_fuse_start)
		# this branch is taken when the condition is false: invert
		if (target_isa == 1):
			arm64_bounds_branch(jcc_invert(arm64_setcc_cond(cc)), be_br_link(h))
			be_br_linked(h)
		else: be_br_cc(jcc_invert(cc - 0x10), h)
		cmp_fuse_end = 0
		return
	if (be_br_const_discard(h, 0)): return
	be_br_zero(h)

void be_br_nonzero_discard(int h):
	if ((target_isa <= 1) && (cmp_fuse_end != 0) && (cmp_fuse_end == codepos)):
		int cc = cmp_fuse_cc
		peep_rollback(cmp_fuse_start)
		if (target_isa == 1):
			arm64_bounds_branch(arm64_setcc_cond(cc), be_br_link(h))
			be_br_linked(h)
		else: be_br_cc(cc - 0x10, h)
		cmp_fuse_end = 0
		return
	if (be_br_const_discard(h, 1)): return
	be_br_nonzero(h)

# A rotated loop (docs/projects/codegen_gap_plan.md §2.5, unit A7) enters
# by jumping over its body to the condition at the bottom: be_loop_entry
# emits the jump and returns its site, be_loop_entry_land resolves it to
# the current position, which is a jump target like any region end. The
# site is a plain forward branch outside the region protocol (it crosses
# the loop region, which the protocol's LIFO nesting cannot express).
# x86 family and arm64 only; the structured-control ISAs never rotate.
int be_loop_entry():
	jmp_int32(0)
	return codepos

void be_loop_entry_land(int site):
	be_notes_reset()
	be_branch_patch(site, codepos)

# Pop region h, which must be the top of the stack, and hand its
# pending branch sites to the open region target below it instead of
# resolving them here: a block target threads them into its own patch
# chain (they land wherever it ends), a loop target resolves them to
# its start now. This is how a condition chain's per-operand branches
# reach the enclosing if/while's false target (grammar/cond_branch.w).
# x86 family only: the chain lives in rel32 fields; the other ISAs never
# request a merge.
void be_ctrl_merge(int h, int target):
	if ((target_isa != 0) || (h != ctrl_stack_pos - 1) || (target >= h) || (target < 0)):
		error(c"internal error: be_ctrl_merge outside its protocol")
	ctrl_stack_pos = h
	int chain = ctrl_val_stack[h]
	if (chain == 0): return
	if (ctrl_kind_stack[target]):
		while (chain):
			int next_site = be_branch_link_get(chain)
			be_branch_patch(chain, ctrl_val_stack[target])
			chain = next_site
		return
	int tail = chain
	while (be_branch_link_get(tail)): tail = be_branch_link_get(tail)
	be_branch_link_set(tail, ctrl_val_stack[target])
	ctrl_val_stack[target] = chain

# Close the most recently opened region. Block regions resolve their patch
# chain to the current position (their merge point); loop regions have
# nothing to patch.
void be_ctrl_end(int h):
	be_notes_reset()
	ctrl_stack_pos = ctrl_stack_pos - 1
	if (target_isa == 3):
		# Forward regions place their merge label here; backward regions
		# placed theirs at the loop start.
		if (ctrl_kind_stack[h] == 0): ptx_place_label(ctrl_val_stack[h])
	elif (target_isa == 2): wasm_ctrl_end()
	else:
		if (ctrl_kind_stack[h]): return
		int chain = ctrl_val_stack[h]
		while (chain):
			int next_site = be_branch_link_get(chain)
			be_branch_patch(chain, codepos)
			chain = next_site


void inc_dword_esp_plus(int v):
	if (target_isa == 3): ptx_inc_sp_slot(v)
	elif (target_isa == 2): wasm_inc_dword_esp_plus(v)
	elif (target_isa == 1): arm64_inc_dword_esp_plus(v)
	else:
		emit_x64_opcode()
		emit(3, c"\xff\x84\x24") /* inc dword[esp+op(0x12, 0x345678)] */
		emit_int(v)


void neg_eax():
	if (target_isa == 3): ptx_neg_ax()
	elif (target_isa == 2): wasm_neg_eax()
	elif (target_isa == 1): a64(op(0xcb, 0x0003e0))   # neg x0,x0
	else:
		# 'mov eax,imm ; neg eax' is one negated constant (A2), which keeps
		# the immediate note for the folds after it. The host's most
		# negative value is its own negation on a 32-bit host but not on a
		# 64-bit one, so that value alone keeps the two instructions.
		if ((imm_note_end != 0) && (imm_note_end == codepos) && (addr_modes_disabled == 0)):
			int v = imm_note_value
			if (v != (0 - (1 << 31))):
				peep_rollback(imm_note_start)
				mov_eax_int(0 - v)
				return
		emit_x64_opcode()
		emit(2, c"\xf7\xd8") /* neg %eax */


void add_dword_esp_plus_eax(int v):
	if (target_isa == 3): ptx_add_sp_slot_ax(v)
	elif (target_isa == 2): wasm_add_dword_esp_plus_eax(v)
	elif (target_isa == 1): arm64_add_dword_esp_plus_eax(v)
	else:
		emit_x64_opcode()
		emit(3, c"\x01\x84\x24") /* add [esp+op(0x12, 0x345678)], eax */
		emit_int(v)


/* add word-sized [esp+offset], imm32 */
void add_stack_word_int32(int offset, int v):
	if (target_isa == 3): ptx_add_sp_slot_int(offset, v)
	elif (target_isa == 2): wasm_add_stack_word_int32(offset, v)
	elif (target_isa == 1): arm64_add_stack_word_int32(offset, v)
	else:
		emit_x64_opcode()
		emit(3, c"\x81\x84\x24")
		emit_int(offset)
		emit_int32(v)


############################ word-width ALU helpers ############################
# Each helper emits one binary operator's code at the target word width:
# emit_x64_opcode() prefixes REX.W so 64-bit pointers are not truncated.

# The register-operand fold (R3): an ALU operator (ext as in
# emit_alu_reg_imm) whose operands came through the shuttle note rolls
# 'mov ebx,<left>; mov eax,X' back and emits '[mov eax,R_left;] op eax,X',
# noting the sequence for regalloc_reg_store. Returns 1 when it emitted
# the operator, 0 when the note is not current (the caller emits
# 'op eax,ebx'). x86 family only; callers have established target_isa.
int shuttle_alu(int ext):
	if ((shuttle_end == 0) || (shuttle_end != codepos)): return 0
	int kind = shuttle_kind
	int left_reg = shuttle_left_reg
	int value = shuttle_value
	int disp = shuttle_disp
	int reg = shuttle_reg
	peep_rollback(shuttle_start)
	int start = codepos
	if (left_reg != 0): mov_eax_reg(left_reg)
	emit_alu_reg_x(ext, 0, kind, value, disp, reg)
	binop_start = start
	binop_end = codepos
	binop_op = ext
	binop_left_reg = left_reg
	binop_kind = kind
	binop_value = value
	binop_disp = disp
	binop_reg = reg
	return 1

# The compare twin: 'cmp eax,X', or 'cmp R_left,X' when the left operand
# is a register (its value need not pass through eax at all). Emits the
# cmp only; the caller materializes or fuses the flags, and passes the
# setCC byte it will use (alu_cmp_set): a load directly before the
# shuttle compared against a constant becomes 'cmp [mem],imm' at the
# load's width (A2, memload_cmp_width) — the compared value is dead
# after the compare, since the setCC or the fused branch is all that
# reads the flags.
int shuttle_cmp(int setcc_opcode):
	if ((shuttle_end == 0) || (shuttle_end != codepos)): return 0
	int kind = shuttle_kind
	int left_reg = shuttle_left_reg
	int value = shuttle_value
	int disp = shuttle_disp
	int reg = shuttle_reg
	if ((kind == 1) && (left_reg == 0) && (memload_end != 0) && (memload_end == shuttle_start) && (addr_modes_disabled == 0)):
		int width = memload_cmp_width(setcc_opcode, value)
		if (width != 0):
			int base = memload_base
			int index = memload_index
			int scale = memload_scale
			int mdisp = memload_disp
			peep_rollback(memload_start)
			cmp_mem_imm(width, value, base, index, scale, mdisp)
			return 1
	peep_rollback(shuttle_start)
	emit_alu_reg_x(7, left_reg, kind, value, disp, reg)
	return 1

# A store into register-resident local r of the accumulator (R3's
# consumer of the binop note): when eax was just computed as 'r op X'
# (or 'X op r' for a commutative op), the sequence becomes 'op r,X' in
# place; keep_eax asks for 'mov eax,r' after it (the expression's value
# is used), a statement-position store leaves eax dead. Otherwise the
# plain 'mov r,eax'. x86 family only.
void regalloc_reg_store(int r, int keep_eax):
	int kind = regalloc_reg_kind(r)
	if ((imm_note_end != 0) && (imm_note_end == codepos) && (keep_eax == 0) && (addr_modes_disabled == 0)):
		# 'mov eax,imm ; mov R,eax' with eax dead: 'mov R,imm' (A2). The
		# 32-bit form zero-extends on x64; a negative value takes the
		# sign-extending REX.W C7 /0 form, a wider one keeps the detour.
		# A uint32 register (A8) takes the 32-bit form for every value:
		# its low 32 bits, zero-extended, are what the memory path's
		# store and load would leave; an int32 register keeps the two
		# word rules, which already sign-extend the low 32 bits.
		int v = imm_note_value
		if ((word_size == 4) || (kind == 1) || ((v >> 31) == 0)):
			peep_rollback(imm_note_start)
			if (r >= 8): emit(1, c"\x41")
			emit_int8(0xb8 | (r & 7))
			emit_int32(v)
			return
		if ((v >> 31) == -1):
			peep_rollback(imm_note_start)
			emit_rex_w_b(r)
			emit(1, c"\xc7")
			emit_int8(0xc0 | (r & 7))
			emit_int32(v)
			return
	if ((regload_note_end != 0) && (regload_note_end == codepos) && (keep_eax == 0) && (addr_modes_disabled == 0)):
		# 'mov eax,R2 ; mov R,eax' with eax dead: one register move
		# (A8: 'hh = g' in the sha256 round). The narrow forms extend
		# the source's low half exactly as a store from eax would.
		int src = regload_note_reg
		peep_rollback(regload_note_start)
		if (kind == 2):
			emit_rex(1, r, src)
			emit(1, c"\x63")
			emit_int8(0xc0 | ((r & 7) << 3) | (src & 7))
			return
		emit_rex(kind == 0, src, r)
		emit(1, c"\x89")
		emit_int8(0xc0 | ((src & 7) << 3) | (r & 7))
		return
	if ((binop_end != 0) && (binop_end == codepos)):
		# A narrow register (A8) runs the operation at 32 bits -- the
		# truncation the memory path's store did -- and an int32 one
		# re-extends the result (movsxd R,R32), so the register again
		# holds the promoted value every reader expects
		int ext = binop_op
		int commutative = (ext == 0) || (ext == 1) || (ext == 4) || (ext == 6) || (ext == 8)
		if (binop_left_reg == r):
			peep_rollback(binop_start)
			emit_alu_reg_x_w(kind == 0, ext, r, binop_kind, binop_value, binop_disp, binop_reg)
			if (kind == 2): regalloc_reg_sx(r)
			if (keep_eax): mov_eax_reg(r)
			return
		if (commutative && (binop_kind == 3) && (binop_reg == r)):
			peep_rollback(binop_start)
			if (binop_left_reg != 0): emit_alu_reg_reg_w(kind == 0, ext, r, binop_left_reg)
			else: emit_alu_reg_reg_w(kind == 0, ext, r, 0)
			if (kind == 2): regalloc_reg_sx(r)
			if (keep_eax): mov_eax_reg(r)
			return
	mov_reg_eax(r)

/* add %ebx,%eax */
void alu_add():
	if (target_isa == 3): ptx_alu_ax_bx(c"add.s64")
	elif (target_isa == 2): wasm_ax_op_bx(0x6a)
	elif (target_isa == 1): a64(op(0x8b, 0x010000))   # add x0,x0,x1
	else:
		if (shuttle_alu(0)): return
		if ((binfold_end != 0) && (binfold_end == codepos)):
			if (fold_add_fits(binfold_left, binfold_right)):
				binfold_emit(binfold_left + binfold_right)
				return
		emit_x64_opcode()
		emit(2, c"\x01\xd8")


/* sub %eax,%ebx ; mov %ebx,%eax */
void alu_sub():
	if (target_isa == 3): ptx_alu_sub()
	elif (target_isa == 2): wasm_bx_op_ax(0x6b)
	elif (target_isa == 1): a64(op(0xcb, 0x000020))   # sub x0,x1,x0
	else:
		if (shuttle_alu(5)): return
		if ((binfold_end != 0) && (binfold_end == codepos)):
			if (fold_sub_fits(binfold_left, binfold_right)):
				binfold_emit(binfold_left - binfold_right)
				return
		emit_x64_opcode()
		emit(2, c"\x29\xc3")
		emit_x64_opcode()
		emit(2, c"\x89\xd8")


/* imul %ebx,%eax */
void alu_imul():
	if (target_isa == 3): ptx_alu_ax_bx(c"mul.lo.s64")
	elif (target_isa == 2): wasm_ax_op_bx(0x6c)
	elif (target_isa == 1): a64(op(0x9b, 0x017c00))   # mul x0,x0,x1
	else:
		if (shuttle_alu(8)): return
		if ((binfold_end != 0) && (binfold_end == codepos)):
			if (fold_mul_fits(binfold_left, binfold_right)):
				binfold_emit(binfold_left * binfold_right)
				return
		emit_x64_opcode()
		emit(3, c"\x0f\xaf\xc3")


/* mov %eax,%ebx ; pop %eax ; cdq/cqo ; idiv %ebx (quotient in eax) */
void alu_idiv():
	if (target_isa == 3): ptx_alu_pop(c"div.s64")
	elif (target_isa == 2): wasm_pop_op_ax(0x6d)
	elif (target_isa == 1):
		a64(op(0xf8, 0x408789))   # ldr x9,[x28],#8   (pop left operand)
		a64(op(0x9a, 0xc00d20))   # sdiv x0,x9,x0
	else:
		emit_x64_opcode()
		emit(2, c"\x89\xc3")
		emit(1, c"\x58")
		emit_x64_opcode()
		emit(1, c"\x99")
		emit_x64_opcode()
		emit(2, c"\xf7\xfb")


/* idiv, then mov %edx,%eax to keep the remainder */
void alu_imod():
	if (target_isa == 3): ptx_alu_pop(c"rem.s64")
	elif (target_isa == 2): wasm_pop_op_ax(0x6f)
	elif (target_isa == 1):
		a64(op(0xf8, 0x408789))   # ldr x9,[x28],#8   (pop left operand)
		a64(op(0x9a, 0xc00d2a))   # sdiv x10,x9,x0
		a64(op(0x9b, 0x00a540))   # msub x0,x10,x0,x9  (x0 = x9 - x10*x0)
	else:
		alu_idiv()
		emit_x64_opcode()
		emit(2, c"\x89\xd0")


/* mov %eax,%ebx ; pop %eax ; xor %edx,%edx ; div %ebx: the unsigned
   twin of alu_idiv, for an unsigned word operand
   (grammar/binary_op.w, unsigned_word_operand) */
void alu_udiv():
	if (target_isa == 3): ptx_alu_pop(c"div.u64")
	elif (target_isa == 2): wasm_pop_op_ax(0x6e)   # i32.div_u
	elif (target_isa == 1):
		a64(op(0xf8, 0x408789))   # ldr x9,[x28],#8   (pop left operand)
		a64(op(0x9a, 0xc00920))   # udiv x0,x9,x0
	else:
		emit_x64_opcode()
		emit(2, c"\x89\xc3")
		emit(1, c"\x58")
		# xor %edx,%edx: a 32-bit write zero-extends into rdx on x64
		emit(2, c"\x31\xd2")
		emit_x64_opcode()
		emit(2, c"\xf7\xf3")


/* div, then mov %edx,%eax to keep the unsigned remainder */
void alu_umod():
	if (target_isa == 3): ptx_alu_pop(c"rem.u64")
	elif (target_isa == 2): wasm_pop_op_ax(0x70)   # i32.rem_u
	elif (target_isa == 1):
		a64(op(0xf8, 0x408789))   # ldr x9,[x28],#8   (pop left operand)
		a64(op(0x9a, 0xc0092a))   # udiv x10,x9,x0
		a64(op(0x9b, 0x00a540))   # msub x0,x10,x0,x9  (x0 = x9 - x10*x0)
	else:
		alu_udiv()
		emit_x64_opcode()
		emit(2, c"\x89\xd0")


# Shift by a constant: 'push eax; mov eax,imm; mov ecx,eax; pop eax;
# shX eax,cl' becomes 'shX eax,imm8' when the count's mov directly
# follows the push. The count is masked by the hardware exactly as cl
# would be (5 bits, 6 with REX.W), so the low byte is all that matters.
# A count of 1 uses the two-byte 0xd1 form.
# modrm_ext is the ModRM byte selecting the operation on eax (0xe0 shl,
# 0xe8 shr, 0xf8 sar).
int shift_imm_fold(int modrm_ext):
	if ((imm_note_end == 0) || (imm_note_end != codepos)): return 0
	if ((push_note_end == 0) || (push_note_end != imm_note_start)): return 0
	int count = imm_note_value & 255
	peep_rollback(push_note_start)
	emit_x64_opcode()
	if (count == 1):
		# The shorter by-one form (0xd1), which is also what the in-tree
		# assembler (libs/asm) picks for a count of 1.
		emit_int8(0xd1)
		emit_int8(modrm_ext)
		return 1
	emit_int8(0xc1)
	emit_int8(modrm_ext)
	emit_int8(count)
	return 1


/* mov %eax,%ecx ; pop %eax ; shl %cl,%eax */
void alu_shl():
	if (target_isa == 3): ptx_alu_shift(c"shl.b64")
	elif (target_isa == 2): wasm_pop_op_ax(0x74)
	elif (target_isa == 1):
		a64(op(0xf8, 0x408789))   # ldr x9,[x28],#8
		a64(op(0x9a, 0xc02120))   # lslv x0,x9,x0
	else:
		if (shift_imm_fold(0xe0)): return
		emit(2, c"\x89\xc1")
		emit(1, c"\x58")
		emit_x64_opcode()
		emit(2, c"\xd3\xe0")


/* mov %eax,%ecx ; pop %eax ; sar %cl,%eax */
void alu_sar():
	if (target_isa == 3): ptx_alu_shift(c"shr.s64")
	elif (target_isa == 2): wasm_pop_op_ax(0x75)
	elif (target_isa == 1):
		a64(op(0xf8, 0x408789))   # ldr x9,[x28],#8
		a64(op(0x9a, 0xc02920))   # asrv x0,x9,x0
	else:
		if (shift_imm_fold(0xf8)): return
		emit(2, c"\x89\xc1")
		emit(1, c"\x58")
		emit_x64_opcode()
		emit(2, c"\xd3\xf8")


/* mov %eax,%ecx ; pop %eax ; shr %cl,%eax: the logical (unsigned) twin
   of alu_sar, for an unsigned word left operand */
void alu_shr():
	if (target_isa == 3): ptx_alu_shift(c"shr.u64")
	elif (target_isa == 2): wasm_pop_op_ax(0x76)   # i32.shr_u
	elif (target_isa == 1):
		a64(op(0xf8, 0x408789))   # ldr x9,[x28],#8
		a64(op(0x9a, 0xc02520))   # lsrv x0,x9,x0
	else:
		if (shift_imm_fold(0xe8)): return
		emit(2, c"\x89\xc1")
		emit(1, c"\x58")
		emit_x64_opcode()
		emit(2, c"\xd3\xe8")


/* and %ebx,%eax */
void alu_and():
	if (target_isa == 3): ptx_alu_ax_bx(c"and.b64")
	elif (target_isa == 2): wasm_ax_op_bx(0x71)
	elif (target_isa == 1): a64(op(0x8a, 0x010000))   # and x0,x0,x1
	else:
		if (shuttle_alu(4)): return
		if ((binfold_end != 0) && (binfold_end == codepos)):
			binfold_emit(binfold_left & binfold_right)
			return
		emit_x64_opcode()
		emit(2, c"\x21\xd8")


/* or %ebx,%eax */
void alu_or():
	if (target_isa == 3): ptx_alu_ax_bx(c"or.b64")
	elif (target_isa == 2): wasm_ax_op_bx(0x72)
	elif (target_isa == 1): a64(op(0xaa, 0x010000))   # orr x0,x0,x1
	else:
		if (shuttle_alu(1)): return
		if ((binfold_end != 0) && (binfold_end == codepos)):
			binfold_emit(binfold_left | binfold_right)
			return
		emit_x64_opcode()
		emit(2, c"\x09\xd8")


/* xor %ebx,%eax */
void alu_xor():
	if (target_isa == 3): ptx_alu_ax_bx(c"xor.b64")
	elif (target_isa == 2): wasm_ax_op_bx(0x73)
	elif (target_isa == 1): a64(op(0xca, 0x010000))   # eor x0,x0,x1
	else:
		if (shuttle_alu(6)): return
		if ((binfold_end != 0) && (binfold_end == codepos)):
			binfold_emit(binfold_left ^ binfold_right)
			return
		emit_x64_opcode()
		emit(2, c"\x31\xd8")


/* cmp %eax,%ebx ; setCC %al ; movzbl %al,%eax
   setcc_opcode is the second setCC byte: 0x9c setl, 0x9d setge, 0x9e setle,
   0x9f setg, 0x94 sete, 0x95 setne, and the unsigned 0x92 setb, 0x93 setae,
   0x96 setbe, 0x97 seta (grammar/binary_op.w, setcc_unsigned) */
void alu_cmp_set(int setcc_opcode):
	if (target_isa == 3): ptx_alu_cmp_set(setcc_opcode)
	elif (target_isa == 2): wasm_alu_cmp_set(setcc_opcode)
	elif (target_isa == 1): arm64_alu_cmp_set(setcc_opcode)
	else:
		if (shuttle_cmp(setcc_opcode) == 0):
			emit_x64_opcode()
			emit(2, c"\x39\xc3")
		cmp_fuse_start = codepos
		emit_int8(15)
		emit_int8(setcc_opcode)
		emit(4, c"\xc0\x0f\xb6\xc0")
		cmp_fuse_end = codepos
		cmp_fuse_cc = setcc_opcode


/* booleanize: test %eax,%eax ; setCC %al ; movzbl %al,%eax
   setcc_opcode: 0x94 sete (logical not), 0x95 setne (truth value) */
void alu_test_set(int setcc_opcode):
	if (target_isa == 3): ptx_alu_test_set(setcc_opcode)
	elif (target_isa == 2): wasm_alu_test_set(setcc_opcode)
	elif (target_isa == 1): arm64_alu_test_set(setcc_opcode)
	else:
		emit_x64_opcode()
		emit(2, c"\x85\xc0")
		emit_int8(15)
		emit_int8(setcc_opcode)
		emit(4, c"\xc0\x0f\xb6\xc0")


########################## 32-bit limb intrinsics ##########################
# Lowering for mul_hi/mul_wide/add_carry (grammar/limb_builtin.w, #213).
# All three read only the operands' low 32 bits, as unsigned, and produce
# results whose low 32 bits are the meaningful pattern (zero-extended on
# the 64-bit targets, like a `& mask32` result). On x86/x64 the 32-bit
# MUL/ADD forms are emitted without a REX.W prefix on purpose: they read
# only the low halves and their 32-bit register writes zero-extend on
# x64, so one byte sequence serves both word sizes. Only the operations
# touching the result pointer are word-sized. The device (PTX) twins in
# code_generator/ptx.w keep the same contract via 64-bit masked
# arithmetic.

/* mov ecx, eax at the full word width (a pointer operand) */
void mov_ecx_eax():
	if (target_isa == 3): ptx_mov_cx_ax()
	elif (target_isa == 2): wasm_mov_ecx_eax()
	elif (target_isa == 1): a64(op(0xaa, 0x0003e2))   # mov x2,x0
	else:
		emit_x64_opcode()
		emit(2, c"\x89\xc1")


/* mul %ebx (edx:eax = eax*ebx, unsigned 32x32) ; mov %edx,%eax */
void alu_mul_hi():
	if (target_isa == 3): ptx_alu_mul_hi()
	elif (target_isa == 2): wasm_alu_mul_hi()
	elif (target_isa == 1):
		a64(op(0x9b, 0xa07c20))   # umull x0,w1,w0
		a64(op(0xd3, 0x60fc00))   # lsr x0,x0,#32
	else:
		emit(2, c"\xf7\xe3")
		emit(2, c"\x89\xd0")


/* mul %ebx ; mov [ecx],edx: low product half stays in eax, the high half
   is stored word-sized through the pointer in ecx */
void alu_mul_wide():
	if (target_isa == 3): ptx_alu_mul_wide()
	elif (target_isa == 2): wasm_alu_mul_wide()
	elif (target_isa == 1):
		a64(op(0x9b, 0xa07c20))   # umull x0,w1,w0
		a64(op(0xd3, 0x60fc09))   # lsr x9,x0,#32
		a64(op(0xf9, 0x000049))   # str x9,[x2]
		a64(op(0x2a, 0x0003e0))   # mov w0,w0 (zero-extend the low half)
	else:
		emit(2, c"\xf7\xe3")
		emit_x64_opcode()
		emit(2, c"\x89\x11")


/* add %ebx,%eax (32-bit: CF = carry out of bit 31) ; mov edx,0 (flags
   preserved) ; adc edx,0 ; the carry is stored word-sized through the
   pointer in ecx and the wrapped sum stays in eax */
void alu_add_carry():
	if (target_isa == 3): ptx_alu_add_carry()
	elif (target_isa == 2): wasm_alu_add_carry()
	elif (target_isa == 1):
		a64(op(0x2a, 0x0003e0))   # mov w0,w0 (zero-extend the operands:
		a64(op(0x2a, 0x0103e1))   # mov w1,w1  the sum then fits 33 bits)
		a64(op(0x8b, 0x000020))   # add x0,x1,x0
		a64(op(0xd3, 0x60fc09))   # lsr x9,x0,#32
		a64(op(0xf9, 0x000049))   # str x9,[x2]
		a64(op(0x2a, 0x0003e0))   # mov w0,w0 (keep the wrapped low half)
	else:
		emit(2, c"\x01\xd8")
		emit(1, c"\xba")
		emit_int32(0)
		emit(3, c"\x83\xd2\x00")
		emit_x64_opcode()
		emit(2, c"\x89\x11")

####################### end of 32-bit limb intrinsics ######################

########################### host atomic intrinsics ###########################
# Lowering for the host-side atomic_add/atomic_cas forms
# (grammar/atomic_builtin.w, docs/projects/threads.md): lock-prefixed
# x86 read-modify-writes at the FULL word width. Unlike the limb
# intrinsics above, these do take REX.W on x64 — an int is the word
# size, and a 4-byte form would update only half the pointee. The LOCK
# prefix (which precedes REX) makes each a full barrier on x86/x64.
# Other ISAs never reach these emitters: the grammar rejects host
# atomics for target_isa != 0 until the arm64 (LSE/ll-sc) and wasm
# (threads proposal) ports land, at which point they grow the same
# target_isa dispatch as the limb intrinsics.

/* lock xadd [ebx],eax: eax = old *ebx, *ebx += eax's value; the
   fetched pre-update value is the intrinsic's result */
void alu_atomic_add():
	emit(1, c"\xf0")
	emit_x64_opcode()
	emit(3, c"\x0f\xc1\x03")


/* lock cmpxchg [ebx],ecx with eax = expected: *ebx == expected swaps
   in ecx (desired); eax ends holding the pre-update *ebx value either
   way (unchanged on success, reloaded on failure), which is the
   intrinsic's result */
void alu_atomic_cas():
	emit(1, c"\xf0")
	emit_x64_opcode()
	emit(3, c"\x0f\xb1\x0b")

####################### end of host atomic intrinsics ######################

######################## 32-bit bit-manipulation intrinsics ########################
# Lowering for shr/rotl/rotr/popcount/clz/ctz (grammar/bit_builtin.w, #249).
# All six read only the operands' low 32 bits, as unsigned, and produce
# results whose low 32 bits are the meaningful pattern (zero-extended on
# the 64-bit targets, like a `& mask32` result). Shift/rotate counts are
# masked to 5 bits (count mod 32) — the hardware behavior of the 32-bit
# x86 shifts and the A64 w-register LSRV/RORV. On x86/x64 every form is
# emitted without a REX.W prefix on purpose: the 32-bit register writes
# zero-extend on x64, so one byte sequence serves both word sizes.
# BSR/BSF are baseline ISA; POPCNT/LZCNT/TZCNT are not, so popcount is
# the classic SWAR reduction and the clz/ctz zero case (both defined to
# return 32) is an explicit branch around the undefined-on-zero BSR/BSF.
# The device (PTX) twins in code_generator/ptx.w use the native
# popc/clz/brev/shf forms.

/* two-operand entry: mov %eax,%ecx ; mov %ebx,%eax puts the value (from
   the popped left operand in ebx) into eax and the count into cl */
void alu_bit_operands():
	emit(2, c"\x89\xc1")
	emit(2, c"\x89\xd8")


# A constant count (unit A8, docs/projects/codegen_gap_plan.md §2.7):
# the operands arrived through pop_ebx's register shuttle as
# 'mov ebx,<left> ; mov eax,imm' (shuttle kind 1), so the five-
# instruction form above collapses to '[mov eax,R ;] rol/ror/shr
# eax,imm8' (C1 /0, /1, /5 ib, the count mod 32 as the hardware
# would take it), the value staying in eax where the shuttle's left
# operand was or coming from its register. Returns 1 when it emitted
# the operation, 0 when the note is not current (the caller emits the
# cl form). x86 family only.
int alu_bit_shuttle_imm(int ext):
	if ((shuttle_end == 0) || (shuttle_end != codepos)): return 0
	if (shuttle_kind != 1): return 0
	int left_reg = shuttle_left_reg
	int count = shuttle_value & 31
	peep_rollback(shuttle_start)
	if (left_reg != 0): mov_eax_reg(left_reg)
	emit(1, c"\xc1")
	emit_int8(0xc0 | (ext << 3))
	emit_int8(count)
	return 1


/* value in ebx, count in eax: shr %cl,%eax (logical right shift) */
void alu_shr32():
	if (target_isa == 3): ptx_alu_shr32()
	elif (target_isa == 2): wasm_alu_shr32()
	elif (target_isa == 1): a64(op(0x1a, 0xc02420))   # lsrv w0,w1,w0 (count mod 32, zero-extends)
	else:
		if (alu_bit_shuttle_imm(5)): return
		alu_bit_operands()
		emit(2, c"\xd3\xe8")


/* value in ebx, count in eax: rol %cl,%eax */
void alu_rotl32():
	if (target_isa == 3): ptx_alu_rotl32()
	elif (target_isa == 2): wasm_alu_rotl32()
	elif (target_isa == 1):
		# A64 has no rotate-left: rotl(a,n) == rotr(a, (-n) mod 32)
		a64(op(0x4b, 0x0003e9))   # neg w9,w0
		a64(op(0x1a, 0xc92c20))   # rorv w0,w1,w9
	else:
		if (alu_bit_shuttle_imm(0)): return
		alu_bit_operands()
		emit(2, c"\xd3\xc0")


/* value in ebx, count in eax: ror %cl,%eax */
void alu_rotr32():
	if (target_isa == 3): ptx_alu_rotr32()
	elif (target_isa == 2): wasm_alu_rotr32()
	elif (target_isa == 1): a64(op(0x1a, 0xc02c20))   # rorv w0,w1,w0
	else:
		if (alu_bit_shuttle_imm(1)): return
		alu_bit_operands()
		emit(2, c"\xd3\xc8")


/* set-bit count of the low 32 bits of eax, via the SWAR reduction
   v -= (v>>1) & 0x55555555
   v = (v & 0x33333333) + ((v>>2) & 0x33333333)
   v = (v + (v>>4)) & 0x0f0f0f0f
   v = (v * 0x01010101) >> 24
   (POPCNT is not baseline ISA; the masks have bit 31 clear, so they are
   plain immediates) */
void alu_popcount32():
	if (target_isa == 3): ptx_alu_popcount32()
	elif (target_isa == 2): wasm_alu_popcount32()
	elif (target_isa == 1):
		a64(op(0x53, 0x017c09))   # lsr w9,w0,#1
		arm64_load_scratch(10, 0x55555555)
		a64(op(0x0a, 0x0a0129))   # and w9,w9,w10
		a64(op(0x4b, 0x090000))   # sub w0,w0,w9
		arm64_load_scratch(10, 0x33333333)
		a64(op(0x0a, 0x0a0009))   # and w9,w0,w10
		a64(op(0x53, 0x027c00))   # lsr w0,w0,#2
		a64(op(0x0a, 0x0a0000))   # and w0,w0,w10
		a64(op(0x0b, 0x090000))   # add w0,w0,w9
		a64(op(0x53, 0x047c09))   # lsr w9,w0,#4
		a64(op(0x0b, 0x090000))   # add w0,w0,w9
		arm64_load_scratch(10, 0x0f0f0f0f)
		a64(op(0x0a, 0x0a0000))   # and w0,w0,w10
		arm64_load_scratch(9, 0x01010101)
		a64(op(0x1b, 0x097c00))   # mul w0,w0,w9
		a64(op(0x53, 0x187c00))   # lsr w0,w0,#24 (zero-extends)
	else:
		emit(2, c"\x89\xc2")          # mov %eax,%edx
		emit(3, c"\xc1\xea\x01")      # shr $1,%edx
		emit(2, c"\x81\xe2")          # and $0x55555555,%edx
		emit_int32(0x55555555)
		emit(2, c"\x29\xd0")          # sub %edx,%eax
		emit(2, c"\x89\xc2")          # mov %eax,%edx
		emit(3, c"\xc1\xea\x02")      # shr $2,%edx
		emit(1, c"\x25")              # and $0x33333333,%eax
		emit_int32(0x33333333)
		emit(2, c"\x81\xe2")          # and $0x33333333,%edx
		emit_int32(0x33333333)
		emit(2, c"\x01\xd0")          # add %edx,%eax
		emit(2, c"\x89\xc2")          # mov %eax,%edx
		emit(3, c"\xc1\xea\x04")      # shr $4,%edx
		emit(2, c"\x01\xd0")          # add %edx,%eax
		emit(1, c"\x25")              # and $0x0f0f0f0f,%eax
		emit_int32(0x0f0f0f0f)
		emit(2, c"\x69\xc0")          # imul $0x01010101,%eax,%eax
		emit_int32(0x01010101)
		emit(3, c"\xc1\xe8\x18")      # shr $24,%eax


/* leading-zero count of the low 32 bits of eax; clz(0) == 32.
   BSR leaves ZF set (and the destination undefined) on zero input, so
   the zero case branches over the 31-index conversion */
void alu_clz32():
	if (target_isa == 3): ptx_alu_clz32()
	elif (target_isa == 2): wasm_alu_clz32()
	elif (target_isa == 1): a64(op(0x5a, 0xc01000))   # clz w0,w0 (clz(0) == 32 in hardware)
	else:
		emit(3, c"\x0f\xbd\xd0")      # bsr %eax,%edx (ZF=1 when eax==0)
		emit(1, c"\xb8")              # mov $32,%eax (flags preserved)
		emit_int32(32)
		emit(2, c"\x74\x05")          # jz +5 (zero input: keep the 32)
		emit(3, c"\x83\xf2\x1f")      # xor $31,%edx (31 - highest set index)
		emit(2, c"\x89\xd0")          # mov %edx,%eax


/* trailing-zero count of the low 32 bits of eax; ctz(0) == 32.
   BSF is undefined on zero input the same way BSR is */
void alu_ctz32():
	if (target_isa == 3): ptx_alu_ctz32()
	elif (target_isa == 2): wasm_alu_ctz32()
	elif (target_isa == 1):
		a64(op(0x5a, 0xc00000))   # rbit w0,w0
		a64(op(0x5a, 0xc01000))   # clz w0,w0
	else:
		emit(3, c"\x0f\xbc\xd0")      # bsf %eax,%edx (ZF=1 when eax==0)
		emit(1, c"\xb8")              # mov $32,%eax (flags preserved)
		emit_int32(32)
		emit(2, c"\x74\x02")          # jz +2 (zero input: keep the 32)
		emit(2, c"\x89\xd0")          # mov %edx,%eax

#################### end of 32-bit bit-manipulation intrinsics ####################


void int3():
	if (target_isa == 3): ptx_trap()
	elif (target_isa == 2): wasm_int3()
	elif (target_isa == 1): a64(op(0xd4, 0x200000))   # brk #0
	else: emit(1, c"\xcc") /* int3 */


/* Bounds checks (issue #228): each helper emits a compare plus a
   conditional branch into control region h (a be_ctrl_block, threaded
   through the same patch-chain protocol be_br uses). The grammar layer
   (bounds_trap_call in grammar/postfix_expr.w) opens a region ending at a
   trap block that calls the runtime diagnostic helper for the
   bounds_branch_* sites, and a region past it for the bounds_skip_* sites,
   so a failed check reports the offending index and length instead of dying
   on a bare int3/brk #0. The in-bounds fall-through path clobbers only
   flags, like the old compare + skip + int3 form. */

void be_bounds_branch(int kind, int limit, int h):
	if (target_isa == 2):
		wasm_bounds_branch(kind, limit, ctrl_stack_pos - 1 - h)
		return
	if (target_isa == 1): arm64_bounds_branch_kind(kind, limit, ctrl_val_stack[h])
	else:
		emit_x64_opcode()
		if (kind == BOUNDS_EAX_NEG): emit(2, c"\x85\xc0") /* test eax,eax */
		elif (kind == BOUNDS_EBX_NEG): emit(2, c"\x85\xdb") /* test ebx,ebx */
		elif (kind == BOUNDS_EAX_LE_LIMIT):
			emit(1, c"\x3d") /* cmp imm32,eax */
			emit_int32(limit)
		else: emit(2, c"\x39\xc3") /* cmp eax,ebx */
		# js / js / jg / jl / jle / jle rel32 (chain link)
		emit(2, c"\x0f\x88\x0f\x88\x0f\x8f\x0f\x8c\x0f\x8e\x0f\x8e" + 2 * kind)
		emit_int32(ctrl_val_stack[h])
	be_ctrl_link(h)

void nop():
	if (target_isa == 3): return
	if (target_isa == 2): wasm_nop()
	elif (target_isa == 1): a64(op(0xd5, 0x03201f))   # nop
	else: emit(1, c"\x90") /* nop */


void ret():
	if (target_isa == 3): ptx_ret()
	elif (target_isa == 2): wasm_ret()
	elif (target_isa == 1):
		a64(op(0xf8, 0x40879e))   # ldr x30,[x28],#8  (pop the return-address slot)
		if (arm64_pac): a64(op(0xda, 0xc1139e))   # autia x30, x28
		a64(op(0xd6, 0x5f03c0))   # ret
	else: emit(1, c"\xc3") /* ret */

# Framed arm64 return: x28 = x29 drops the body's words, the pair pop
# restores the caller's x29 and the return address and leaves x28 as it
# was at entry, which is the modifier the prologue signed x30 with.
void be_arm64_frame_return():
	a64(op(0xaa, 0x1d03fc))   # mov x28, x29
	a64(op(0xa8, 0xc17b9d))   # ldp x29, x30, [x28], #16
	if (arm64_pac): a64(op(0xda, 0xc1139e))   # autia x30, x28
	a64(op(0xd6, 0x5f03c0))   # ret


void dwarf_leave_note();   /* dwarf.w: CFI for the framed return */
void be_frame_teardown();


# Function return from a body holding stack_words W stack words above
# the return-address slot: a framed function unwinds through its frame
# pointer ('leave' on x86/x64, be_arm64_frame_return on arm64), exact
# whatever stack_words is; everything else pops the words, as before
# frame pointers.
void be_return(int stack_words):
	if (be_frame_active && (target_isa == 1)):
		be_arm64_frame_return()
		return
	if ((target_isa == 0) && be_frame_active): be_frame_teardown()
	else: be_pop(stack_words)
	ret()


# x86/x64 frame teardown: 'leave', or, when the prologue pushed promoted
# registers, 'lea esp,[ebp-W*saved] ; pop ... ; pop ebp' (the CFI note
# marks the pop of the frame pointer in both shapes).
void be_frame_teardown():
	if (regalloc_epilogue_emit()):
		dwarf_leave_note()
		emit(1, c"\x5d") /* pop ebp */
	else:
		dwarf_leave_note()
		emit(1, c"\xc9") /* leave */


# Return from a body that holds nothing on the W stack beyond its
# frame: 'leave ; ret' in a framed x86/x64 function, the frame return on
# arm64, a bare ret otherwise (function fall-through ends, synthesized
# accessors).
void be_return_bare():
	if (be_frame_active && (target_isa == 1)):
		be_arm64_frame_return()
		return
	if ((target_isa == 0) && be_frame_active): be_frame_teardown()
	ret()

############################## end of x86 opcodes ##############################
