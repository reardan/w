/*
WebAssembly (wasm32) instruction emitter — the wasm twin of
code_generator/x86.w (docs/projects/wasm_backend.md D2/D3).

The cc500 stack-machine model is preserved with wasm module globals in
place of registers:

  global 0 = $sp  the W evaluation-stack pointer (linear memory offset)
  global 1 = $ax  accumulator            (the x86 backend's eax)
  global 2 = $bx  secondary operand      (ebx)
  global 3 = $cx  scratch                (ecx)

The W stack lives in linear memory (wasm locals cannot have their address
taken, and W takes addresses of locals everywhere): pushes are
"$sp -= 4; [$sp] = v", locals and arguments are loads/stores at [$sp + k],
so the stack_pos bookkeeping and sym_get_value offset math are unchanged
(4-byte words, word_size_log2 = 2 — the same layout as the x86 target).

Every W function has the single wasm type [] -> [] (type index 0):
arguments travel on the W stack and the return value in $ax, exactly as on
the native targets. All calls are call_indirect through the one funcref
table, so a function's "address" (its symbol value) is its table index —
assigned in definition order by be_function_define — and the classic
backpatch chains thread through i32.const address slots unchanged. Each
function body's prologue reserves one W-stack slot so the callee sees the
same [return-slot | args...] layout the x86 backend's hardware `call`
produces; ret() releases it.

wasm has no arbitrary branches: the be_ctrl / be_br control regions
(code_generator/x86.w) lower to block/loop/br_if here, with the branch
depth computed from the shared control stack at emission time.

Everything backpatchable — function body sizes, address-slot immediates —
is emitted as PADDED 5-byte LEB128 (spec-legal non-minimal encodings), so
the single-pass emit-then-patch model works exactly as on the native
targets. Plain constants use canonical encodings.

This file is compiled by the committed seed, so it uses only seed-known
syntax. Emission is gated on target_isa == 2, which the x86.w helpers
branch on, so every existing target's output stays byte-identical.
*/

import code_generator.code_emitter

# Number of W functions defined so far (entry stub included). Table index
# N is the N-th defined function (index 0 is the reserved null function
# pointer); the module writer emits the identity element segment and the
# matching function/table/code section counts from this.
int wasm_func_count

# Buffer offset of the current function body's 5-byte size placeholder;
# patched by wasm_function_end.
int wasm_body_size_pos

# Function names by table index, for the emitted "name" custom section
# (engine stack traces show W function names). Best-effort debug info.
char** wasm_func_names
int wasm_func_names_cap

void wasm_func_name_note(int table_index, char* name):
	if (table_index >= wasm_func_names_cap):
		int new_cap = wasm_func_names_cap * 2
		if (new_cap < 256):
			new_cap = 256
		if (new_cap <= table_index):
			new_cap = table_index + 256
		wasm_func_names = cast(char**, realloc(cast(char*, wasm_func_names), wasm_func_names_cap * 4, new_cap * 4))
		wasm_func_names_cap = new_cap
	char* copy = malloc(strlen(name) + 1)
	strcpy(copy, name)
	wasm_func_names[table_index] = copy

################################ LEB128 #######################################

# Canonical unsigned LEB128.
void wasm_leb(int v):
	while (1):
		int b = v & 0x7f
		# Logical shift: W's >> is arithmetic, so mask after shifting.
		v = (v >> 7) & 0x1ffffff
		if (v):
			emit_int8(b | 0x80)
		else:
			emit_int8(b)
			return

# Padded 5-byte LEB128 for a 32-bit value; both the unsigned and signed
# readings of the encoding reproduce the value's 32-bit pattern, so one
# form serves size fields (u32) and i32.const immediates (s33) alike:
# the top byte's bit 3 (value bit 31) is sign-extended through bits 4-6
# so the signed decoding agrees.
void wasm_leb5(int v):
	emit_int8((v & 0x7f) | 0x80)
	emit_int8(((v >> 7) & 0x7f) | 0x80)
	emit_int8(((v >> 14) & 0x7f) | 0x80)
	emit_int8(((v >> 21) & 0x7f) | 0x80)
	int top = (v >> 28) & 0x0f
	if (top & 0x08):
		top = top | 0x70
	emit_int8(top)

# Overwrite the padded 5-byte LEB128 at buffer offset pos with v.
void wasm_leb5_patch(int pos, int v):
	code[pos] = (v & 0x7f) | 0x80
	code[pos + 1] = ((v >> 7) & 0x7f) | 0x80
	code[pos + 2] = ((v >> 14) & 0x7f) | 0x80
	code[pos + 3] = ((v >> 21) & 0x7f) | 0x80
	int top = (v >> 28) & 0x0f
	if (top & 0x08):
		top = top | 0x70
	code[pos + 4] = top

# Read the 32-bit value stored in a padded 5-byte LEB128 at buffer offset
# pos (the inverse of wasm_leb5_patch; used by the address-slot chain
# walkers).
int wasm_leb5_read(int pos):
	int v = code[pos] & 0x7f
	v = v | ((code[pos + 1] & 0x7f) << 7)
	v = v | ((code[pos + 2] & 0x7f) << 14)
	v = v | ((code[pos + 3] & 0x7f) << 21)
	v = v | ((code[pos + 4] & 0x0f) << 28)
	return v

############################ core emission helpers ############################

void wasm_op(int opcode):
	emit_int8(opcode)

# i32.const with a canonical signed-LEB immediate (plain constants).
void wasm_i32_const(int v):
	emit_int8(0x41)
	while (1):
		int b = v & 0x7f
		v = v >> 7   # arithmetic shift: sign propagates
		if (((v == 0) & ((b & 0x40) == 0)) | ((v == -1) & ((b & 0x40) == 0x40))):
			emit_int8(b)
			return
		emit_int8(b | 0x80)

# i32.const with a padded 5-byte immediate (patchable slots).
void wasm_i32_const_slot(int v):
	emit_int8(0x41)
	wasm_leb5(v)

void wasm_global_get(int g):
	emit_int8(0x23)
	wasm_leb(g)

void wasm_global_set(int g):
	emit_int8(0x24)
	wasm_leb(g)

# Loads/stores: [opcode, align(log2), offset]. The align field is a hint;
# unaligned addresses still work, so word accesses use align=2 safely.
void wasm_load_op(int opcode, int align, int offset):
	emit_int8(opcode)
	wasm_leb(align)
	wasm_leb(offset)

void wasm_get_ax():
	wasm_global_get(1)

void wasm_set_ax():
	wasm_global_set(1)

void wasm_get_bx():
	wasm_global_get(2)

void wasm_set_bx():
	wasm_global_set(2)

########################### W-stack (shadow stack) ############################

# $sp += bytes (negative to grow the stack).
void wasm_sp_add(int bytes):
	wasm_global_get(0)
	wasm_i32_const(bytes)
	wasm_op(0x6a)   # i32.add
	wasm_global_set(0)

# Push the value of global g onto the W stack.
void wasm_push_global(int g):
	wasm_sp_add(0 - 4)
	wasm_global_get(0)
	wasm_global_get(g)
	wasm_load_op(0x36, 2, 0)   # i32.store

void wasm_push_eax():
	wasm_push_global(1)

void wasm_push_ebx():
	wasm_push_global(2)

# Pop the W stack top into global g.
void wasm_pop_global(int g):
	wasm_global_get(0)
	wasm_load_op(0x28, 2, 0)   # i32.load
	wasm_global_set(g)
	wasm_sp_add(4)

void wasm_pop_eax():
	wasm_pop_global(1)

void wasm_pop_ebx():
	wasm_pop_global(2)

# Pop the W stack top into $cx (the left operand of pop-style ALU ops).
void wasm_pop_ecx():
	wasm_pop_global(3)

void wasm_push_const(int v):
	wasm_sp_add(0 - 4)
	wasm_global_get(0)
	wasm_i32_const(v)
	wasm_load_op(0x36, 2, 0)

# push word [$ax + v]
void wasm_push_eax_plus(int v):
	wasm_sp_add(0 - 4)
	wasm_global_get(0)
	wasm_get_ax()
	wasm_load_op(0x28, 2, v)
	wasm_load_op(0x36, 2, 0)

void wasm_be_pop(int n):
	wasm_sp_add(n << 2)

########################### accumulator operations ############################

void wasm_mov_eax_int(int v):
	wasm_i32_const(v)
	wasm_set_ax()

void wasm_mov_eax_ebx():
	wasm_get_bx()
	wasm_set_ax()

void wasm_mov_ecx_eax():
	wasm_get_ax()
	wasm_global_set(3)

# $ax = $ax OP v for a binary opcode taking (ax, const)
void wasm_ax_op_const(int opcode, int v):
	wasm_get_ax()
	wasm_i32_const(v)
	wasm_op(opcode)
	wasm_set_ax()

# $ax = $ax OP $bx
void wasm_ax_op_bx(int opcode):
	wasm_get_ax()
	wasm_get_bx()
	wasm_op(opcode)
	wasm_set_ax()

# $ax = $bx OP $ax (subtraction-style operand order)
void wasm_bx_op_ax(int opcode):
	wasm_get_bx()
	wasm_get_ax()
	wasm_op(opcode)
	wasm_set_ax()

# pop lhs into $cx, then $ax = $cx OP $ax (division/shift operand order)
void wasm_pop_op_ax(int opcode):
	wasm_pop_ecx()
	wasm_global_get(3)
	wasm_get_ax()
	wasm_op(opcode)
	wasm_set_ax()

void wasm_add_ebx_int(int v):
	wasm_get_bx()
	wasm_i32_const(v)
	wasm_op(0x6a)
	wasm_set_bx()

void wasm_neg_eax():
	wasm_i32_const(0)
	wasm_get_ax()
	wasm_op(0x6b)   # i32.sub
	wasm_set_ax()

void wasm_not_eax():
	wasm_ax_op_const(0x73, 0 - 1)   # i32.xor -1

############################# loads and stores ################################

# $ax = load of the given width at [$ax] (promote family)
void wasm_promote_eax_op(int load_opcode):
	wasm_get_ax()
	int align = 2
	if (load_opcode != 0x28):
		align = 0
		if ((load_opcode == 0x2e) | (load_opcode == 0x2f)):
			align = 1
	wasm_load_op(load_opcode, align, 0)
	wasm_set_ax()

# same for $bx
void wasm_promote_ebx():
	wasm_get_bx()
	wasm_load_op(0x28, 2, 0)
	wasm_set_bx()

# store $ax at [$bx] with the given width
void wasm_store_ebx_op(int store_opcode):
	wasm_get_bx()
	wasm_get_ax()
	int align = 2
	if (store_opcode == 0x3a):
		align = 0
	if (store_opcode == 0x3b):
		align = 1
	wasm_load_op(store_opcode, align, 0)

# $ax = $sp + v
void wasm_lea_eax_esp_plus(int v):
	wasm_global_get(0)
	wasm_i32_const(v)
	wasm_op(0x6a)
	wasm_set_ax()

# $ax = [$sp + v]
void wasm_mov_eax_esp_plus(int v):
	wasm_global_get(0)
	wasm_load_op(0x28, 2, v)
	wasm_set_ax()

# $bx = [$sp] — the x86 helper is 'mov ebx,[esp]' (8b 1c 24), a LOAD of
# the W stack top (always a pointer at its call sites), not the stack
# pointer itself. The constructor/array-descriptor paths depend on the
# load; a '$bx = $sp' reading corrupts the W stack.
void wasm_mov_ebx_esp():
	wasm_global_get(0)
	wasm_load_op(0x28, 2, 0)
	wasm_set_bx()

# $bx = [$sp + v]
void wasm_mov_ebx_esp_plus(int v):
	wasm_global_get(0)
	wasm_load_op(0x28, 2, v)
	wasm_set_bx()

# [$sp + v] = $ax
void wasm_store_stack_var(int v):
	wasm_global_get(0)
	wasm_get_ax()
	wasm_load_op(0x36, 2, v)

# [$sp + v] = $bx
void wasm_store_ebx_stack_var(int v):
	wasm_global_get(0)
	wasm_get_bx()
	wasm_load_op(0x36, 2, v)

# [$sp + v] += 1
void wasm_inc_dword_esp_plus(int v):
	wasm_global_get(0)
	wasm_global_get(0)
	wasm_load_op(0x28, 2, v)
	wasm_i32_const(1)
	wasm_op(0x6a)
	wasm_load_op(0x36, 2, v)

# [$sp + v] += $ax
void wasm_add_dword_esp_plus_eax(int v):
	wasm_global_get(0)
	wasm_global_get(0)
	wasm_load_op(0x28, 2, v)
	wasm_get_ax()
	wasm_op(0x6a)
	wasm_load_op(0x36, 2, v)

# [$sp + offset] += v
void wasm_add_stack_word_int32(int offset, int v):
	wasm_global_get(0)
	wasm_global_get(0)
	wasm_load_op(0x28, 2, offset)
	wasm_i32_const(v)
	wasm_op(0x6a)
	wasm_load_op(0x36, 2, offset)

############################### comparisons ###################################

# Map an x86 setcc opcode to the i32 comparison with (left, right) operand
# order; alu_cmp_set applies it as (bx CC ax), alu_test_set as (ax CC 0).
int wasm_cmp_opcode(int setcc_opcode):
	if (setcc_opcode == 0x94):
		return 0x46   # sete  -> i32.eq
	if (setcc_opcode == 0x95):
		return 0x47   # setne -> i32.ne
	if (setcc_opcode == 0x9c):
		return 0x48   # setl  -> i32.lt_s
	if (setcc_opcode == 0x9d):
		return 0x4e   # setge -> i32.ge_s
	if (setcc_opcode == 0x9e):
		return 0x4c   # setle -> i32.le_s
	if (setcc_opcode == 0x9f):
		return 0x4a   # setg  -> i32.gt_s
	if (setcc_opcode == 0x92):
		return 0x49   # setb  -> i32.lt_u
	if (setcc_opcode == 0x93):
		return 0x4f   # setae -> i32.ge_u
	if (setcc_opcode == 0x96):
		return 0x4d   # setbe -> i32.le_u
	return 0x4b       # seta (0x97) -> i32.gt_u

# $ax = ($bx CC $ax) as 0/1
void wasm_alu_cmp_set(int setcc_opcode):
	wasm_get_bx()
	wasm_get_ax()
	wasm_op(wasm_cmp_opcode(setcc_opcode))
	wasm_set_ax()

# $ax = ($ax CC 0) as 0/1
void wasm_alu_test_set(int setcc_opcode):
	wasm_get_ax()
	wasm_i32_const(0)
	wasm_op(wasm_cmp_opcode(setcc_opcode))
	wasm_set_ax()

############################## limb intrinsics ################################
# 32-bit unsigned multi-precision helpers (grammar/limb_builtin.w): the
# 64-bit intermediates use wasm's native i64 value type, which is available
# in any wasm32 module (only the language-level int64 needs word_size 8).

# $ax = high 32 bits of unsigned $bx * $ax
void wasm_alu_mul_hi():
	wasm_get_bx()
	wasm_op(0xad)   # i64.extend_i32_u
	wasm_get_ax()
	wasm_op(0xad)
	wasm_op(0x7e)   # i64.mul
	wasm_i32_const(32)
	wasm_op(0xac)   # i64.extend_i32_s
	wasm_op(0x88)   # i64.shr_u
	wasm_op(0xa7)   # i32.wrap_i64
	wasm_set_ax()

# mul_wide: $ax = low half of unsigned $bx * $ax, high half stored to [$cx]
# (the grammar moves the high-half pointer into $cx before the call, the
# same convention as x86's ecx). Global 4 is the i64 scratch ($t64).
void wasm_alu_mul_wide():
	wasm_get_bx()
	wasm_op(0xad)
	wasm_get_ax()
	wasm_op(0xad)
	wasm_op(0x7e)   # i64.mul -> full 64-bit product on the operand stack
	# store high half: [cx] = wrap(product >> 32); keep product in $ax low
	wasm_global_set(4)   # spill the product to $t64 (i64 scratch)
	wasm_global_get(3)
	wasm_global_get(4)
	wasm_i32_const(32)
	wasm_op(0xac)
	wasm_op(0x88)   # i64.shr_u
	wasm_op(0xa7)   # i32.wrap
	wasm_load_op(0x36, 2, 0)
	wasm_global_get(4)
	wasm_op(0xa7)   # i32.wrap: low half
	wasm_set_ax()

# add_carry: $ax = ($bx + $ax) mod 2^32, carry-out stored to [$cx]
void wasm_alu_add_carry():
	wasm_get_bx()
	wasm_op(0xad)
	wasm_get_ax()
	wasm_op(0xad)
	wasm_op(0x7c)   # i64.add
	wasm_global_set(4)
	wasm_global_get(3)
	wasm_global_get(4)
	wasm_i32_const(32)
	wasm_op(0xac)
	wasm_op(0x88)
	wasm_op(0xa7)   # carry (0/1)
	wasm_load_op(0x36, 2, 0)
	wasm_global_get(4)
	wasm_op(0xa7)
	wasm_set_ax()

############################## bit intrinsics #################################
# shr/rotl/rotr/popcount/clz/ctz (grammar/bit_builtin.w): all direct wasm
# opcodes with the same zero-case semantics (i32.clz(0) == i32.ctz(0) == 32)
# and mod-32 shift counts. Operands arrive as ($bx = value, $ax = count)
# via alu_bit_operands on x86; here the same convention applies.

# $ax = unsigned $bx >> $ax
void wasm_alu_shr32():
	wasm_bx_op_ax(0x76)   # i32.shr_u

void wasm_alu_rotl32():
	wasm_bx_op_ax(0x77)   # i32.rotl

void wasm_alu_rotr32():
	wasm_bx_op_ax(0x78)   # i32.rotr

void wasm_alu_popcount32():
	wasm_get_ax()
	wasm_op(0x69)   # i32.popcnt
	wasm_set_ax()

void wasm_alu_clz32():
	wasm_get_ax()
	wasm_op(0x67)   # i32.clz
	wasm_set_ax()

void wasm_alu_ctz32():
	wasm_get_ax()
	wasm_op(0x68)   # i32.ctz
	wasm_set_ax()

############################### float32 ######################################
# Float bits ride the integer pipeline in $ax/$bx (docs/projects/float.md);
# the virtual xmm0/xmm1 pair maps to the f32 globals 5/6 ($f0/$f1), with
# reinterpret casts as the movd transfers. Only the float32 family exists
# here: float64 is rejected on word_size-4 targets before codegen.

# $f<xmm> = f32.reinterpret_i32($ax or $bx)
void wasm_movd_xmm(int xmm, int reg):
	wasm_global_get(1 + reg)
	wasm_op(0xbe)   # f32.reinterpret_i32
	wasm_global_set(5 + xmm)

# $ax = i32.reinterpret_f32($f0)
void wasm_movd_eax_xmm0():
	wasm_global_get(5)
	wasm_op(0xbc)   # i32.reinterpret_f32
	wasm_set_ax()

# $f0 = $f0 OP $f1
void wasm_f32_arith(int opcode):
	wasm_global_get(5)
	wasm_global_get(6)
	wasm_op(opcode)
	wasm_global_set(5)

# The x86 model splits compare (ucomiss: flags) from materialization
# (setcc); wasm compares produce the 0/1 directly, so ucomiss emits
# nothing and setcc emits the comparison. The unsigned condition codes
# map to the unordered-false wasm comparisons exactly (NaN yields 0 for
# seta/setae/sete and 1 for setne, matching ucomiss flag semantics).
void wasm_setcc_f32(int setcc_opcode):
	wasm_global_get(5)
	wasm_global_get(6)
	if (setcc_opcode == 0x94):
		wasm_op(0x5b)   # sete  -> f32.eq
	else if (setcc_opcode == 0x95):
		wasm_op(0x5c)   # setne -> f32.ne
	else if (setcc_opcode == 0x92):
		wasm_op(0x5d)   # setb  -> f32.lt
	else if (setcc_opcode == 0x96):
		wasm_op(0x5f)   # setbe -> f32.le
	else if (setcc_opcode == 0x93):
		wasm_op(0x60)   # setae -> f32.ge
	else:
		wasm_op(0x5e)   # seta (0x97) -> f32.gt
	wasm_set_ax()

# $f<xmm> = f32.convert_i32_s($ax or $bx)
void wasm_cvtsi2ss(int xmm, int reg):
	wasm_global_get(1 + reg)
	wasm_op(0xb2)   # f32.convert_i32_s
	wasm_global_set(5 + xmm)

# $ax = trunc($f0), saturating (x86 gives INT_MIN on overflow/NaN, the
# saturating form clamps and maps NaN to 0 — the trap-free choice)
void wasm_cvttss2si():
	wasm_global_get(5)
	emit_int8(0xfc)   # i32.trunc_sat_f32_s
	wasm_leb(0)
	wasm_set_ax()

######################### structured control flow #############################
# The wasm lowering of the be_ctrl_*/be_br* regions (x86.w): blocks and
# loops are void-typed (all values travel in the globals / the W stack, so
# no operand-stack values ever cross a label) and branch depths fall out of
# the shared control stack: region h sits (ctrl_stack_pos - 1 - h) labels
# out from the innermost one.

void wasm_ctrl_block():
	emit_int8(0x02)
	emit_int8(0x40)   # void block type

void wasm_ctrl_loop():
	emit_int8(0x03)
	emit_int8(0x40)

void wasm_ctrl_end():
	emit_int8(0x0b)

void wasm_br(int depth):
	emit_int8(0x0c)
	wasm_leb(depth)

# br_if on ($ax == 0) / ($ax != 0)
void wasm_br_zero(int depth):
	wasm_get_ax()
	wasm_op(0x45)   # i32.eqz
	emit_int8(0x0d)
	wasm_leb(depth)

void wasm_br_nonzero(int depth):
	wasm_get_ax()
	emit_int8(0x0d)
	wasm_leb(depth)

# Bounds checks: compare + br_if into region h at the given depth.
void wasm_bounds_br_if(int depth):
	emit_int8(0x0d)
	wasm_leb(depth)

void wasm_bounds_branch_eax_negative(int depth):
	wasm_get_ax()
	wasm_i32_const(0)
	wasm_op(0x48)   # i32.lt_s
	wasm_bounds_br_if(depth)

void wasm_bounds_branch_ebx_negative(int depth):
	wasm_get_bx()
	wasm_i32_const(0)
	wasm_op(0x48)
	wasm_bounds_br_if(depth)

void wasm_bounds_branch_ebx_greater_eax(int depth):
	wasm_get_bx()
	wasm_get_ax()
	wasm_op(0x4a)   # i32.gt_s
	wasm_bounds_br_if(depth)

void wasm_bounds_skip_ebx_less_eax(int depth):
	wasm_get_bx()
	wasm_get_ax()
	wasm_op(0x48)   # i32.lt_s
	wasm_bounds_br_if(depth)

void wasm_bounds_skip_ebx_less_equal_eax(int depth):
	wasm_get_bx()
	wasm_get_ax()
	wasm_op(0x4c)   # i32.le_s
	wasm_bounds_br_if(depth)

void wasm_bounds_skip_eax_less_equal_int32(int limit, int depth):
	wasm_get_ax()
	wasm_i32_const(limit)
	wasm_op(0x4c)   # i32.le_s
	wasm_bounds_br_if(depth)

########################## functions and address slots ########################

# Begin a function body unit in the code section: a padded 5-byte body-size
# placeholder (patched by wasm_function_end) and an empty local-declaration
# vector, then the prologue that reserves the W-stack return-address slot
# so argument offsets match the native targets.
void wasm_function_begin():
	wasm_func_count = wasm_func_count + 1
	wasm_body_size_pos = codepos
	wasm_leb5(0)
	emit_int8(0)   # no locals
	wasm_sp_add(0 - 4)

# Close the current function body: the final `end` opcode, then patch the
# size prefix. Every W body ends in ret() (grammar/program.w emits one
# unconditionally), so the code before `end` never falls through.
void wasm_function_end():
	emit_int8(0x0b)
	wasm_leb5_patch(wasm_body_size_pos, codepos - (wasm_body_size_pos + 5))

# ret(): release the prologue's return-address slot and return.
void wasm_ret():
	wasm_sp_add(4)
	emit_int8(0x0f)   # return

# call through the accumulator: every W call site. The callee's "address"
# in $ax is its table index; type 0 is the universal [] -> [] W type.
void wasm_call_eax():
	wasm_get_ax()
	emit_int8(0x11)   # call_indirect
	wasm_leb(0)       # type index 0
	wasm_leb(0)       # table index 0

# Address slot: i32.const with a padded immediate, then $ax = it. The
# patchable cell convention matches the native targets: callers address the
# slot as codepos - 4 right after emission, so the 5 immediate bytes sit at
# [pos - 3, pos + 2).
void wasm_addr_slot_emit():
	wasm_i32_const_slot(0)
	wasm_set_ax()

void wasm_addr_slot_write(int pos, int v):
	wasm_leb5_patch(pos - 3, v)

int wasm_addr_slot_read(int pos):
	return wasm_leb5_read(pos - 3)

void wasm_int3():
	emit_int8(0x00)   # unreachable (a bare `debugger` dies, like int3 does)

void wasm_nop():
	emit_int8(0x01)
