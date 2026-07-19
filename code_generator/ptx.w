/*
PTX text emitter (docs/projects/cuda.md Stage 2, option A1). Kernel bodies
compile with target_isa == 3: the emit helpers in x86.w/sse.w dispatch to
the ptx_* twins below, which append PTX text to a side buffer instead of
machine bytes to `code`, so the host image is untouched while a device
body parses. The device model mirrors the x86 stack machine one-to-one:

  %ax/%bx/%cx (.b64)  eax/ebx/scratch — the accumulator convention
  %w0 (.b32)          32-bit staging (special registers, shift counts,
                      float32 bit transfers)
  %fa/%fb (.f32)      xmm0/xmm1 at float32 width
  %da/%db (.f64)      xmm0/xmm1 at float64 width
  %p (.pred)          comparison results, conditional branches
  %sp/%bp (.b64)      the W evaluation stack, a .local byte array
                      converted to a generic address once in the prologue
                      (so every ld/st below is a plain generic access and
                      &local keeps working)

W int is .s64 and pointers are .u64 (the cuda path implies the x64 host:
libcuda.so is 64-bit only), float32 is .f32, float64 is .f64. Sub-word
loads use PTX's widening ld.s8/.s16/.s32/.u16 forms; stores truncate.

Every kernel of a program lands in ONE module (.version/.target header +
kernels, NUL-terminated). ptx_finish_module() embeds it in the host image
behind a synthesized `char* __w_ptx_module()` and optionally dumps it to
the --ptx=<path> file, so the emitter is testable without a GPU.

This file is compiled by the committed seed: only seed-understood syntax.
*/

void error(char *s);                    /* compiler/tokenizer.w */
int sym_lookup(char *s);                /* compiler/symbol_table.w */
int be_function_define_declare(char* name);   /* code_generator/arm64.w */
void be_function_prologue();
void be_function_epilogue();
void ret();                             /* code_generator/x86.w */
void be_emit_inline_cstr(int len, char* s);   /* grammar/string_literal.w */


# The finished module: header + every completed kernel, in program order.
char* ptx_module_buf
int ptx_module_size
int ptx_module_pos

# The current kernel's body scratch. Bodies build here first because a
# 'gpu for' kernel's parameter count (its capture set) is only known
# after the body has parsed; ptx_kernel_end stitches header + body.
char* ptx_body_buf
int ptx_body_size
int ptx_body_pos

# 1 once any kernel was emitted: gates ptx_finish_module.
int ptx_used

# Name of the kernel being emitted (owned copy; freed by ptx_kernel_end).
char* ptx_kernel_name

# Monotonic label allocator; PTX labels are function-local but globally
# unique names keep the emitter stateless across kernels.
int ptx_label_count

# Pending float compare width recorded by ucomiss/ucomisd (1 = f32,
# 2 = f64) and consumed by the following setcc_movzx_eax.
int ptx_pending_fcmp

# --ptx=<path>: dump the finished module text here (compiler/compiler.w).
char* ptx_dump_path


############################ text buffer plumbing #############################

# 0 = append to the body scratch, 1 = append to the module buffer.
int ptx_emit_to_module

void ptx_reserve(int n):
	if (ptx_emit_to_module):
		if (ptx_module_size <= ptx_module_pos + n):
			int x = (ptx_module_pos + n) << 1
			if (x < 4096):
				x = 4096
			ptx_module_buf = realloc(ptx_module_buf, ptx_module_size, x)
			ptx_module_size = x
	else:
		if (ptx_body_size <= ptx_body_pos + n):
			int y = (ptx_body_pos + n) << 1
			if (y < 4096):
				y = 4096
			ptx_body_buf = realloc(ptx_body_buf, ptx_body_size, y)
			ptx_body_size = y


void ptx_emit_char(int ch):
	ptx_reserve(1)
	if (ptx_emit_to_module):
		ptx_module_buf[ptx_module_pos] = ch
		ptx_module_pos = ptx_module_pos + 1
	else:
		ptx_body_buf[ptx_body_pos] = ch
		ptx_body_pos = ptx_body_pos + 1


void ptx_emit(char* s):
	int i = 0
	while (s[i] != 0):
		ptx_emit_char(s[i])
		i = i + 1


void ptx_emit_int(int v):
	ptx_emit(itoa(v))


# One instruction (or directive) per line.
void ptx_line(char* s):
	ptx_emit(s)
	ptx_emit_char(10)


# Append v's low 32 bits as exactly 8 hex digits. Used for 64-bit
# immediates given as two halves: the compiler may itself be a 32-bit
# process, where a single int cannot carry the full pattern.
void ptx_emit_hex32(int v):
	int shift = 28
	while (shift >= 0):
		int d = (v >> shift) & 15
		if (d < 10):
			ptx_emit_char('0' + d)
		else:
			ptx_emit_char('a' + d - 10)
		shift = shift - 4


############################## register model ################################

# W-stack push/pop: the x86 push/pop twins at word width.
void ptx_push_ax():
	ptx_line(c"sub.u64 %sp, %sp, 8;")
	ptx_line(c"st.u64 [%sp], %ax;")


void ptx_push_bx():
	ptx_line(c"sub.u64 %sp, %sp, 8;")
	ptx_line(c"st.u64 [%sp], %bx;")


void ptx_pop_ax():
	ptx_line(c"ld.u64 %ax, [%sp];")
	ptx_line(c"add.u64 %sp, %sp, 8;")


void ptx_pop_bx():
	ptx_line(c"ld.u64 %bx, [%sp];")
	ptx_line(c"add.u64 %sp, %sp, 8;")


# push_int8/push_int32: push a constant without touching the accumulator.
void ptx_push_const(int v):
	ptx_emit(c"mov.s64 %cx, ")
	ptx_emit_int(v)
	ptx_line(c";")
	ptx_line(c"sub.u64 %sp, %sp, 8;")
	ptx_line(c"st.u64 [%sp], %cx;")


void ptx_mov_ax_int(int v):
	ptx_emit(c"mov.s64 %ax, ")
	ptx_emit_int(v)
	ptx_line(c";")


# mov rax, imm64 given as two 32-bit halves (float64 literal bits).
void ptx_mov_ax_int64_halves(int lo, int hi):
	ptx_emit(c"mov.u64 %ax, 0x")
	ptx_emit_hex32(hi)
	ptx_emit_hex32(lo)
	ptx_line(c";")


# Widening loads through the address in %ax (the promote_* family).
# suffix is the PTX type: ".u64", ".s32", ".s16", ".u16" or ".s8".
void ptx_ld_ax(char* suffix):
	ptx_emit(c"ld")
	ptx_emit(suffix)
	ptx_line(c" %ax, [%ax];")


# mov ebx,[ebx]
void ptx_promote_bx():
	ptx_line(c"ld.u64 %bx, [%bx];")


# Truncating stores through the address in %bx (the store_ebx_* family).
void ptx_st_bx(char* suffix):
	ptx_emit(c"st")
	ptx_emit(suffix)
	ptx_line(c" [%bx], %ax;")


# Loads/stores/lea against the W stack at a byte offset from %sp.
void ptx_ld_ax_sp(int off):
	ptx_emit(c"ld.u64 %ax, [%sp+")
	ptx_emit_int(off)
	ptx_line(c"];")


void ptx_ld_bx_sp(int off):
	ptx_emit(c"ld.u64 %bx, [%sp+")
	ptx_emit_int(off)
	ptx_line(c"];")


void ptx_st_sp_ax(int off):
	ptx_emit(c"st.u64 [%sp+")
	ptx_emit_int(off)
	ptx_line(c"], %ax;")


void ptx_st_sp_bx(int off):
	ptx_emit(c"st.u64 [%sp+")
	ptx_emit_int(off)
	ptx_line(c"], %bx;")


void ptx_lea_ax_sp(int off):
	ptx_emit(c"add.u64 %ax, %sp, ")
	ptx_emit_int(off)
	ptx_line(c";")


# Address of the capture slot at `off` bytes below %bp (the 'gpu for'
# outlining layout: capture k lives at [%bp - (k+1)*8], a fixed offset
# that stays valid however deep %sp has grown mid-body).
void ptx_lea_ax_bp_minus(int off):
	ptx_emit(c"sub.u64 %ax, %bp, ")
	ptx_emit_int(off)
	ptx_line(c";")


# push dword [eax+off]
void ptx_push_ax_plus(int off):
	ptx_emit(c"ld.u64 %cx, [%ax+")
	ptx_emit_int(off)
	ptx_line(c"];")
	ptx_line(c"sub.u64 %sp, %sp, 8;")
	ptx_line(c"st.u64 [%sp], %cx;")


# add esp, n*word_size
void ptx_be_pop(int n):
	ptx_emit(c"add.u64 %sp, %sp, ")
	ptx_emit_int(n << 3)
	ptx_line(c";")


void ptx_ld_cx_sp(int off):
	ptx_emit(c"ld.u64 %cx, [%sp+")
	ptx_emit_int(off)
	ptx_line(c"];")


void ptx_st_sp_cx(int off):
	ptx_emit(c"st.u64 [%sp+")
	ptx_emit_int(off)
	ptx_line(c"], %cx;")


# inc qword [esp+off]
void ptx_inc_sp_slot(int off):
	ptx_ld_cx_sp(off)
	ptx_line(c"add.s64 %cx, %cx, 1;")
	ptx_st_sp_cx(off)


# add [esp+off], eax
void ptx_add_sp_slot_ax(int off):
	ptx_ld_cx_sp(off)
	ptx_line(c"add.s64 %cx, %cx, %ax;")
	ptx_st_sp_cx(off)


# add qword [esp+off], imm32
void ptx_add_sp_slot_int(int off, int v):
	ptx_ld_cx_sp(off)
	ptx_emit(c"add.s64 %cx, %cx, ")
	ptx_emit_int(v)
	ptx_line(c";")
	ptx_st_sp_cx(off)


void ptx_mov_ax_bx():
	ptx_line(c"mov.b64 %ax, %bx;")


void ptx_add_ax_int(int v):
	ptx_emit(c"add.s64 %ax, %ax, ")
	ptx_emit_int(v)
	ptx_line(c";")


void ptx_mul_ax_int(int v):
	ptx_emit(c"mul.lo.s64 %ax, %ax, ")
	ptx_emit_int(v)
	ptx_line(c";")


void ptx_add_bx_int(int v):
	ptx_emit(c"add.s64 %bx, %bx, ")
	ptx_emit_int(v)
	ptx_line(c";")


# xor eax, imm32 (32-bit form: the write zero-extends, like x64)
void ptx_xor_ax_int32(int v):
	ptx_line(c"cvt.u32.u64 %w0, %ax;")
	ptx_emit(c"xor.b32 %w0, %w0, 0x")
	ptx_emit_hex32(v)
	ptx_line(c";")
	ptx_line(c"cvt.u64.u32 %ax, %w0;")


void ptx_not_ax():
	ptx_line(c"not.b64 %ax, %ax;")


void ptx_neg_ax():
	ptx_line(c"neg.s64 %ax, %ax;")


####################### limb/bit intrinsics (device) #########################
# Device twins of the 32-bit limb/bit lowering in x86.w. Same contract:
# operands' LOW 32 BITS AS UNSIGNED, results zero-extended, shift/rotate
# counts mod 32. Most ops mask into 64-bit arithmetic; popcount/clz/ctz
# use the native PTX b32 forms and the rotates use the sm_32+ funnel
# shifts (shf.*.wrap masks the count itself). PTX CLAMPS oversized
# shift counts instead of masking them, so the explicit 'and ..., 31'
# below is load-bearing.

# mov ecx, eax (the result-pointer operand of mul_wide/add_carry)
void ptx_mov_cx_ax():
	ptx_line(c"mov.b64 %cx, %ax;")


# mul %ebx unsigned 32x32; high half -> accumulator
void ptx_alu_mul_hi():
	ptx_line(c"and.b64 %ax, %ax, 0xffffffff;")
	ptx_line(c"and.b64 %bx, %bx, 0xffffffff;")
	ptx_line(c"mul.lo.s64 %ax, %bx, %ax;")
	ptx_line(c"shr.u64 %ax, %ax, 32;")


# low product half -> accumulator, high half stored word-sized via %cx
void ptx_alu_mul_wide():
	ptx_line(c"and.b64 %ax, %ax, 0xffffffff;")
	ptx_line(c"and.b64 %bx, %bx, 0xffffffff;")
	ptx_line(c"mul.lo.s64 %ax, %bx, %ax;")
	ptx_line(c"shr.u64 %bx, %ax, 32;")
	ptx_line(c"st.u64 [%cx], %bx;")
	ptx_line(c"and.b64 %ax, %ax, 0xffffffff;")


# wrapped 32-bit sum -> accumulator, carry (0/1) stored via %cx
void ptx_alu_add_carry():
	ptx_line(c"and.b64 %ax, %ax, 0xffffffff;")
	ptx_line(c"and.b64 %bx, %bx, 0xffffffff;")
	ptx_line(c"add.s64 %ax, %ax, %bx;")
	ptx_line(c"shr.u64 %bx, %ax, 32;")
	ptx_line(c"st.u64 [%cx], %bx;")
	ptx_line(c"and.b64 %ax, %ax, 0xffffffff;")


# value in %bx, count in %ax: 32-bit logical right shift
void ptx_alu_shr32():
	ptx_line(c"and.b64 %cx, %bx, 0xffffffff;")
	ptx_line(c"and.b64 %ax, %ax, 31;")
	ptx_line(c"cvt.u32.u64 %w0, %ax;")
	ptx_line(c"shr.u64 %ax, %cx, %w0;")


# value in %bx, count in %ax: rotate via the funnel shift with both
# sources the same register (shf.l.wrap: (x << c) | (x >> (32-c)))
void ptx_alu_rotl32():
	ptx_line(c"cvt.u32.u64 %w0, %bx;")
	ptx_line(c"cvt.u32.u64 %w1, %ax;")
	ptx_line(c"shf.l.wrap.b32 %w0, %w0, %w0, %w1;")
	ptx_line(c"cvt.u64.u32 %ax, %w0;")


void ptx_alu_rotr32():
	ptx_line(c"cvt.u32.u64 %w0, %bx;")
	ptx_line(c"cvt.u32.u64 %w1, %ax;")
	ptx_line(c"shf.r.wrap.b32 %w0, %w0, %w0, %w1;")
	ptx_line(c"cvt.u64.u32 %ax, %w0;")


void ptx_alu_popcount32():
	ptx_line(c"cvt.u32.u64 %w0, %ax;")
	ptx_line(c"popc.b32 %w0, %w0;")
	ptx_line(c"cvt.u64.u32 %ax, %w0;")


# clz.b32 returns 32 on zero input, matching the W contract
void ptx_alu_clz32():
	ptx_line(c"cvt.u32.u64 %w0, %ax;")
	ptx_line(c"clz.b32 %w0, %w0;")
	ptx_line(c"cvt.u64.u32 %ax, %w0;")


# ctz(x) == clz(brev(x)); brev(0) == 0 -> 32, matching the W contract
void ptx_alu_ctz32():
	ptx_line(c"cvt.u32.u64 %w0, %ax;")
	ptx_line(c"brev.b32 %w0, %w0;")
	ptx_line(c"clz.b32 %w0, %w0;")
	ptx_line(c"cvt.u64.u32 %ax, %w0;")


############################### integer ALU ##################################

# Two-operand forms with the left operand in %bx (alu_add/sub/imul and
# the bitwise family): op is the full PTX mnemonic with type.
void ptx_alu_ax_bx(char* mnemonic):
	ptx_emit(mnemonic)
	ptx_line(c" %ax, %ax, %bx;")


# sub %eax,%ebx; mov %ebx,%eax: result = left - right
void ptx_alu_sub():
	ptx_line(c"sub.s64 %ax, %bx, %ax;")


# Division-family forms that pop the left operand off the W stack
# themselves (alu_idiv/alu_imod): result = popped OP %ax.
void ptx_alu_pop(char* mnemonic):
	ptx_line(c"ld.u64 %cx, [%sp];")
	ptx_line(c"add.u64 %sp, %sp, 8;")
	ptx_emit(mnemonic)
	ptx_line(c" %ax, %cx, %ax;")


# Shifts pop the value; the count is %ax's low 32 bits (PTX shift counts
# are .u32, matching the x86 cl convention).
void ptx_alu_shift(char* mnemonic):
	ptx_line(c"cvt.u32.u64 %w0, %ax;")
	ptx_line(c"ld.u64 %cx, [%sp];")
	ptx_line(c"add.u64 %sp, %sp, 8;")
	ptx_emit(mnemonic)
	ptx_line(c" %ax, %cx, %w0;")


# setCC-opcode -> PTX comparison name (the x86 second setCC byte).
char* ptx_cc_name(int setcc_opcode):
	if (setcc_opcode == 0x9c):
		return c"lt"
	if (setcc_opcode == 0x9d):
		return c"ge"
	if (setcc_opcode == 0x9e):
		return c"le"
	if (setcc_opcode == 0x9f):
		return c"gt"
	if (setcc_opcode == 0x94):
		return c"eq"
	if (setcc_opcode == 0x95):
		return c"ne"
	# Unsigned forms, used after float compares: seta/setae/setb/setbe
	if (setcc_opcode == 0x97):
		return c"gt"
	if (setcc_opcode == 0x93):
		return c"ge"
	if (setcc_opcode == 0x92):
		return c"lt"
	if (setcc_opcode == 0x96):
		return c"le"
	error(c"gpu: unsupported comparison")
	return c"eq"


# cmp %eax,%ebx ; setCC ; movzx: compares left (%bx) against right (%ax).
void ptx_alu_cmp_set(int setcc_opcode):
	ptx_emit(c"setp.")
	ptx_emit(ptx_cc_name(setcc_opcode))
	ptx_line(c".s64 %p, %bx, %ax;")
	ptx_line(c"selp.b64 %ax, 1, 0, %p;")


# test %eax,%eax ; setCC ; movzx (0x94 sete / 0x95 setne).
void ptx_alu_test_set(int setcc_opcode):
	ptx_emit(c"setp.")
	ptx_emit(ptx_cc_name(setcc_opcode))
	ptx_line(c".s64 %p, %ax, 0;")
	ptx_line(c"selp.b64 %ax, 1, 0, %p;")


############################## control flow ##################################

int ptx_new_label():
	ptx_label_count = ptx_label_count + 1
	return ptx_label_count


void ptx_emit_label_ref(int label):
	ptx_emit(c"L")
	ptx_emit_int(label)


# The label definition line "Ln:".
void ptx_place_label(int label):
	ptx_emit_label_ref(label)
	ptx_line(c":")


void ptx_bra(int label):
	ptx_emit(c"bra ")
	ptx_emit_label_ref(label)
	ptx_line(c";")


void ptx_bra_zero(int label):
	ptx_line(c"setp.eq.s64 %p, %ax, 0;")
	ptx_emit(c"@%p bra ")
	ptx_emit_label_ref(label)
	ptx_line(c";")


void ptx_bra_nonzero(int label):
	ptx_line(c"setp.ne.s64 %p, %ax, 0;")
	ptx_emit(c"@%p bra ")
	ptx_emit_label_ref(label)
	ptx_line(c";")


void ptx_ret():
	ptx_line(c"ret;")


void ptx_trap():
	ptx_line(c"trap;")


################################## floats ####################################

# GPR -> f32 register transfer (movd xmm<xmm>, eax/ebx): the float bits
# ride the integer pipeline's low 32 bits, like the host convention.
void ptx_movd_xmm(int xmm, int reg):
	if (reg == 0):
		ptx_line(c"cvt.u32.u64 %w0, %ax;")
	else:
		ptx_line(c"cvt.u32.u64 %w0, %bx;")
	if (xmm == 0):
		ptx_line(c"mov.b32 %fa, %w0;")
	else:
		ptx_line(c"mov.b32 %fb, %w0;")


void ptx_movd_ax_f0():
	ptx_line(c"mov.b32 %w0, %fa;")
	ptx_line(c"cvt.u64.u32 %ax, %w0;")


void ptx_movq_xmm(int xmm, int reg):
	if (xmm == 0):
		if (reg == 0):
			ptx_line(c"mov.b64 %da, %ax;")
		else:
			ptx_line(c"mov.b64 %da, %bx;")
	else:
		if (reg == 0):
			ptx_line(c"mov.b64 %db, %ax;")
		else:
			ptx_line(c"mov.b64 %db, %bx;")


void ptx_movq_ax_d0():
	ptx_line(c"mov.b64 %ax, %da;")


# ucomiss/ucomisd record the width; the following setcc emits the
# ordered setp (NaN compares false — same divergence model as wasm).
void ptx_fcmp_pending(int kind):
	ptx_pending_fcmp = kind


void ptx_setcc_fcmp(int setcc_opcode):
	ptx_emit(c"setp.")
	ptx_emit(ptx_cc_name(setcc_opcode))
	if (ptx_pending_fcmp == 2):
		ptx_line(c".f64 %p, %da, %db;")
	else:
		ptx_line(c".f32 %p, %fa, %fb;")
	ptx_pending_fcmp = 0
	ptx_line(c"selp.b64 %ax, 1, 0, %p;")


void ptx_cvtsi2ss(int xmm, int reg):
	if (xmm == 0):
		if (reg == 0):
			ptx_line(c"cvt.rn.f32.s64 %fa, %ax;")
		else:
			ptx_line(c"cvt.rn.f32.s64 %fa, %bx;")
	else:
		if (reg == 0):
			ptx_line(c"cvt.rn.f32.s64 %fb, %ax;")
		else:
			ptx_line(c"cvt.rn.f32.s64 %fb, %bx;")


void ptx_cvtsi2sd(int xmm, int reg):
	if (xmm == 0):
		if (reg == 0):
			ptx_line(c"cvt.rn.f64.s64 %da, %ax;")
		else:
			ptx_line(c"cvt.rn.f64.s64 %da, %bx;")
	else:
		if (reg == 0):
			ptx_line(c"cvt.rn.f64.s64 %db, %ax;")
		else:
			ptx_line(c"cvt.rn.f64.s64 %db, %bx;")


void ptx_cvttss2si():
	ptx_line(c"cvt.rzi.s64.f32 %ax, %fa;")


void ptx_cvttsd2si():
	ptx_line(c"cvt.rzi.s64.f64 %ax, %da;")


void ptx_cvtss2sd(int xmm):
	if (xmm == 0):
		ptx_line(c"cvt.f64.f32 %da, %fa;")
	else:
		ptx_line(c"cvt.f64.f32 %db, %fb;")


void ptx_cvtsd2ss():
	ptx_line(c"cvt.rn.f32.f64 %fa, %da;")


# btc rax,63: flip the float64 sign bit.
void ptx_btc_63():
	ptx_line(c"xor.b64 %ax, %ax, 0x8000000000000000;")


################################# atomics ####################################
# atomic_add/atomic_min/atomic_max (grammar/atomic_builtin.w): pointer in
# %bx, value in %ax, the OLD value comes back in the accumulator. The
# space-less atom form uses generic addressing, matching the all-generic
# model — the pointer must reference device-accessible global memory
# (gpu_alloc/gpu_device_alloc), never a .local stack slot.

# kind: 1 add, 2 min, 3 max. atom.add has no .s64 form; two's-complement
# addition makes .u64 exact. min/max are signed, matching W int.
void ptx_atomic_int(int kind):
	if (kind == 1):
		ptx_line(c"atom.add.u64 %ax, [%bx], %ax;")
	else if (kind == 2):
		ptx_line(c"atom.min.s64 %ax, [%bx], %ax;")
	else:
		ptx_line(c"atom.max.s64 %ax, [%bx], %ax;")


# float32 add (atom.add.f32, sm_20+; float64 atomics need sm_60 and are
# rejected at parse time). Value bits ride the low 32 of %ax, the host
# convention.
void ptx_atomic_add_f32():
	ptx_line(c"cvt.u32.u64 %w0, %ax;")
	ptx_line(c"mov.b32 %fa, %w0;")
	ptx_line(c"atom.add.f32 %fa, [%bx], %fa;")
	ptx_line(c"mov.b32 %w0, %fa;")
	ptx_line(c"cvt.u64.u32 %ax, %w0;")


############################ transcendentals ##################################
# gpu_exp/gpu_log (grammar/gpu_math_builtin.w): value bits ride the low
# 32 of %ax on entry and exit, the same host-bits convention as
# ptx_atomic_add_f32. Both use the hardware .approx forms (ML-precision,
# not IEEE-correct — the same tradeoff CUDA's fast-math makes) plus a
# base-change multiply; %fb is scratch for the constant, matching the
# xmm1-as-right-operand convention the rest of the float ops use.

# e^x = 2^(x * log2(e)); ex2.approx.f32 computes the base-2 power.
void ptx_gpu_exp():
	ptx_line(c"cvt.u32.u64 %w0, %ax;")
	ptx_line(c"mov.b32 %fa, %w0;")
	ptx_line(c"mov.f32 %fb, 0f3FB8AA3B;")
	ptx_line(c"mul.f32 %fa, %fa, %fb;")
	ptx_line(c"ex2.approx.f32 %fa, %fa;")
	ptx_line(c"mov.b32 %w0, %fa;")
	ptx_line(c"cvt.u64.u32 %ax, %w0;")


# ln(x) = log2(x) * ln(2); lg2.approx.f32 computes the base-2 logarithm.
void ptx_gpu_log():
	ptx_line(c"cvt.u32.u64 %w0, %ax;")
	ptx_line(c"mov.b32 %fa, %w0;")
	ptx_line(c"lg2.approx.f32 %fa, %fa;")
	ptx_line(c"mov.f32 %fb, 0f3F317218;")
	ptx_line(c"mul.f32 %fa, %fa, %fb;")
	ptx_line(c"mov.b32 %w0, %fa;")
	ptx_line(c"cvt.u64.u32 %ax, %w0;")


############################ shared memory ###################################
# gpu_shared_f32/gpu_barrier (grammar/gpu_shared_builtin.w).

# Monotonic name counter for .shared arrays. Module-global (not reset
# per kernel) so the emitter stays stateless across kernels, matching
# ptx_label_count; each call site gets its own array.
int ptx_shared_count

# Declares an elements-long f32 .shared array in the current kernel
# body (PTX allows declarations anywhere in a body before first use)
# and leaves its generic address in %ax — cvta.shared folds the array
# into the all-generic ld/st model, so ordinary W pointer indexing
# reads and writes it from there on.
void ptx_shared_f32(int elements):
	ptx_emit(c".shared .align 4 .b8 __w_shared")
	ptx_emit_int(ptx_shared_count)
	ptx_emit(c"[")
	ptx_emit_int(elements * 4)
	ptx_line(c"];")
	ptx_emit(c"mov.u64 %ax, __w_shared")
	ptx_emit_int(ptx_shared_count)
	ptx_line(c";")
	ptx_line(c"cvta.shared.u64 %ax, %ax;")
	ptx_shared_count = ptx_shared_count + 1


# Block-wide barrier. The caller contract (all threads reach it) is
# documented at the builtin; the emitter just names barrier 0.
void ptx_barrier():
	ptx_line(c"bar.sync 0;")


############################ special registers ###############################

# thread_idx()/block_idx()/block_dim()/grid_dim() (x dimension), widened
# to the W int convention. kind: 1 tid, 2 ctaid, 3 ntid, 4 nctaid.
void ptx_special_reg(int kind):
	if (kind == 1):
		ptx_line(c"mov.u32 %w0, %tid.x;")
	else if (kind == 2):
		ptx_line(c"mov.u32 %w0, %ctaid.x;")
	else if (kind == 3):
		ptx_line(c"mov.u32 %w0, %ntid.x;")
	else:
		ptx_line(c"mov.u32 %w0, %nctaid.x;")
	ptx_line(c"cvt.u64.u32 %ax, %w0;")


########################### kernel/module assembly ###########################

# ld.param.u64 %ax, [p<i>]: a kernel parameter, about to be pushed as an
# ordinary local by the kernel grammar.
void ptx_param_load(int i):
	ptx_emit(c"ld.param.u64 %ax, [p")
	ptx_emit_int(i)
	ptx_line(c"];")


####################### peephole (cuda.md A2, step 1) ########################
# Post-pass over a finished kernel body: every push/pop pair whose whole
# span sits inside one basic block becomes a pair of register moves
# through a virtual register, deleting the pair's four .local
# stack-traffic instructions. This recovers most of what the A1
# stack-machine model loses on expression temporaries — the driver JIT
# cannot do it itself because the eval stack is accessed through
# generic addresses it must assume alias user pointers — while leaving
# the grammar's accumulator contract untouched (full A2 would change
# every promote()/push_eax() call site).
#
# The subtlety is that deleting a pushed word moves %sp for every line
# between the push and the pop, so [%sp+K] slot references in the span
# must be rewritten — but only those reaching slots OLDER than the
# eliminated word (K decreases by 8); references to slots pushed after
# it keep their distance to %sp. Slot identity is resolved by
# simulating the stack depth line by line: a reference at depth d with
# offset K targets the slot pushed d - K/8 - 1 pushes above the body's
# base.
#
# Virtual registers are reused by nesting depth (%v<depth-at-push>), so
# the declaration count stays small. Anything the scanner does not
# recognize as well-formed (a pop with no open push, a scope pop wider
# than the tracked stack) abandons the pass for that kernel — the
# untransformed body is always correct.

# Vreg count used by the most recent ptx_peephole run (0 = none/bailed);
# ptx_kernel_end reads it to emit the .reg %v declaration.
int ptx_peep_vregs


int ptx_peep_starts(char* b, int pos, int end, char* pat):
	int i = 0
	while (pat[i]):
		if (pos + i >= end):
			return 0
		if (b[pos + i] != pat[i]):
			return 0
		i = i + 1
	return 1


int ptx_peep_num(char* b, int pos):
	int n = 0
	while ((b[pos] >= '0') && (b[pos] <= '9')):
		n = (n << 3) + (n << 1) + b[pos] - '0'
		pos = pos + 1
	return n


# Append the C string s to out at outp; returns the new position.
int ptx_peep_put(char* out, int outp, char* s):
	int i = 0
	while (s[i]):
		out[outp] = s[i]
		outp = outp + 1
		i = i + 1
	return outp


# Index of "[%sp+" within the line, or -1.
int ptx_peep_find_spref(char* b, int ls, int le):
	int i = ls
	while (i + 5 <= le):
		if (ptx_peep_starts(b, i, le, c"[%sp+")):
			return i
		i = i + 1
	return 0 - 1


# Rewrites ptx_body_buf in place (via a fresh buffer). See the header
# comment above for the model.
void ptx_peephole():
	ptx_peep_vregs = 0
	char* b = ptx_body_buf
	int n = ptx_body_pos
	if (n == 0):
		return

	# Count lines, then record each line's start offset.
	int lines = 0
	int i = 0
	while (i < n):
		if (b[i] == 10):
			lines = lines + 1
		i = i + 1
	if (lines == 0):
		return
	int* ls = cast(int*, malloc(lines * __word_size__))
	int* kind = cast(int*, malloc(lines * __word_size__))
	int* val = cast(int*, malloc(lines * __word_size__))    # K, N, or reg char
	int* sloti = cast(int*, malloc(lines * __word_size__))  # kinds 5/6: slot index
	int* shift = cast(int*, malloc(lines * __word_size__))
	int* action = cast(int*, malloc(lines * __word_size__)) # 0 copy, 1 del, 2 mov-to-v, 3 mov-from-v
	int* vreg = cast(int*, malloc(lines * __word_size__))
	int L = 0
	int start = 0
	i = 0
	while (i < n):
		if (b[i] == 10):
			ls[L] = start
			L = L + 1
			start = i + 1
		i = i + 1

	# Classify. Kinds: 0 other, 1 push-sub, 2 push-st, 3 pop-ld,
	# 4 sp-add (N in val), 5 [%sp+K] reference, 6 lea %ax,%sp,K,
	# 7 label, 8 branch.
	L = 0
	while (L < lines):
		int s = ls[L]
		int e = n - 1
		if (L + 1 < lines):
			e = ls[L + 1] - 1
		kind[L] = 0
		val[L] = 0
		sloti[L] = 0
		shift[L] = 0
		action[L] = 0
		vreg[L] = 0
		if (ptx_peep_starts(b, s, e, c"sub.u64 %sp, %sp, 8;")):
			kind[L] = 1
		else if (ptx_peep_starts(b, s, e, c"st.u64 [%sp], %")):
			kind[L] = 2
			val[L] = b[s + 15]
		else if (ptx_peep_starts(b, s, e, c"ld.u64 %") && ptx_peep_starts(b, s + 9, e, c"x, [%sp];")):
			kind[L] = 3
			val[L] = b[s + 8]
		else if (ptx_peep_starts(b, s, e, c"add.u64 %sp, %sp, ")):
			kind[L] = 4
			val[L] = ptx_peep_num(b, s + 18)
		else if (ptx_peep_starts(b, s, e, c"add.u64 %ax, %sp, ")):
			kind[L] = 6
			val[L] = ptx_peep_num(b, s + 18)
		else if (ptx_peep_starts(b, s, e, c"bra ") || ptx_peep_starts(b, s, e, c"@%p bra ")):
			kind[L] = 8
		else if ((e > s) && (b[e - 1] == ':')):
			kind[L] = 7
		else:
			int at = ptx_peep_find_spref(b, s, e)
			if (at >= 0):
				kind[L] = 5
				val[L] = ptx_peep_num(b, at + 5)
		L = L + 1

	# Scan: simulate depth, track open pushes, match pairs.
	int* op_st = cast(int*, malloc(lines * __word_size__))   # push-st line
	int* op_slot = cast(int*, malloc(lines * __word_size__))
	int* op_conv = cast(int*, malloc(lines * __word_size__))
	int top = 0
	int depth = 0
	int pr_count = 0
	int* pr_st = cast(int*, malloc(lines * __word_size__))
	int* pr_ld = cast(int*, malloc(lines * __word_size__))
	int* pr_j = cast(int*, malloc(lines * __word_size__))
	int ok = 1
	int maxv = 0
	L = 0
	while ((L < lines) && ok):
		int k = kind[L]
		if (k == 1):
			# A push is sub immediately followed by st; anything else
			# is unexpected.
			if ((L + 1 < lines) && (kind[L + 1] == 2)):
				op_st[top] = L + 1
				op_slot[top] = depth
				op_conv[top] = 1
				top = top + 1
				depth = depth + 1
				L = L + 2
			else:
				ok = 0
		else if (k == 3):
			if ((L + 1 < lines) && (kind[L + 1] == 4) && (val[L + 1] == 8)):
				# A pop: match the newest open push.
				if (top == 0):
					ok = 0
				else:
					top = top - 1
					depth = depth - 1
					if (op_conv[top]):
						pr_st[pr_count] = op_st[top]
						pr_ld[pr_count] = L
						pr_j[pr_count] = op_slot[top]
						if (op_slot[top] + 1 > maxv):
							maxv = op_slot[top] + 1
						pr_count = pr_count + 1
					L = L + 2
			else:
				# Bare peek of the top word: an ordinary reference to
				# slot depth-1.
				kind[L] = 5
				val[L] = 0
				sloti[L] = depth - 1
				L = L + 1
		else if (k == 4):
			# Scope pop: discards the top N/8 words without reading.
			int words = val[L] / 8
			if (words > top):
				ok = 0
			else:
				int w = 0
				while (w < words):
					top = top - 1
					op_conv[top] = 0
					w = w + 1
				depth = depth - words
				L = L + 1
		else if ((k == 7) || (k == 8)):
			# Basic-block boundary: no open push may convert across it.
			int q = 0
			while (q < top):
				op_conv[q] = 0
				q = q + 1
			L = L + 1
		else:
			if ((k == 5) || (k == 6)):
				sloti[L] = depth - val[L] / 8 - 1
			L = L + 1

	if (ok && (pr_count > 0)):
		# Offset rewrites: a reference inside a pair's span reaching a
		# slot older than the eliminated word sits 8 bytes closer to
		# %sp once that word is gone.
		int p = 0
		while (p < pr_count):
			int q2 = pr_st[p] + 1
			while (q2 < pr_ld[p]):
				if ((kind[q2] == 5) || (kind[q2] == 6)):
					if (sloti[q2] < pr_j[p]):
						shift[q2] = shift[q2] + 8
				q2 = q2 + 1
			# Mark the pair's four lines: delete sub/add, replace st/ld
			# with moves through the pair's depth-indexed vreg.
			action[pr_st[p] - 1] = 1
			action[pr_st[p]] = 2
			vreg[pr_st[p]] = pr_j[p]
			action[pr_ld[p]] = 3
			vreg[pr_ld[p]] = pr_j[p]
			action[pr_ld[p] + 1] = 1
			p = p + 1

		# Rebuild the body into a fresh scratch buffer.
		int cap = n * 2 + 128
		char* out = malloc(cap)
		int outp = 0
		L = 0
		while (L < lines):
			int s2 = ls[L]
			int e2 = n - 1
			if (L + 1 < lines):
				e2 = ls[L + 1] - 1
			if (action[L] == 1):
				L = L + 1
			else if (action[L] == 2):
				outp = ptx_peep_put(out, outp, c"mov.u64 %v")
				outp = ptx_peep_put(out, outp, itoa(vreg[L]))
				outp = ptx_peep_put(out, outp, c", %")
				out[outp] = val[L]
				outp = outp + 1
				outp = ptx_peep_put(out, outp, c"x;")
				out[outp] = 10
				outp = outp + 1
				L = L + 1
			else if (action[L] == 3):
				outp = ptx_peep_put(out, outp, c"mov.u64 %")
				out[outp] = val[L]
				outp = outp + 1
				outp = ptx_peep_put(out, outp, c"x, %v")
				outp = ptx_peep_put(out, outp, itoa(vreg[L]))
				out[outp] = ';'
				out[outp + 1] = 10
				outp = outp + 2
				L = L + 1
			else if ((kind[L] == 6) && (shift[L] > 0)):
				outp = ptx_peep_put(out, outp, c"add.u64 %ax, %sp, ")
				outp = ptx_peep_put(out, outp, itoa(val[L] - shift[L]))
				out[outp] = ';'
				out[outp + 1] = 10
				outp = outp + 2
				L = L + 1
			else if ((kind[L] == 5) && (shift[L] > 0)):
				int at2 = ptx_peep_find_spref(b, s2, e2)
				int cp = s2
				while (cp < at2 + 5):
					out[outp] = b[cp]
					outp = outp + 1
					cp = cp + 1
				outp = ptx_peep_put(out, outp, itoa(val[L] - shift[L]))
				while ((b[cp] >= '0') && (b[cp] <= '9')):
					cp = cp + 1
				while (cp < e2):
					out[outp] = b[cp]
					outp = outp + 1
					cp = cp + 1
				out[outp] = 10
				outp = outp + 1
				L = L + 1
			else:
				int cp2 = s2
				while (cp2 < e2):
					out[outp] = b[cp2]
					outp = outp + 1
					cp2 = cp2 + 1
				out[outp] = 10
				outp = outp + 1
				L = L + 1
		free(ptx_body_buf)
		ptx_body_buf = out
		ptx_body_size = cap
		ptx_body_pos = outp
		ptx_peep_vregs = maxv

	free(ls)
	free(kind)
	free(val)
	free(sloti)
	free(shift)
	free(action)
	free(vreg)
	free(op_st)
	free(op_slot)
	free(op_conv)
	free(pr_st)
	free(pr_ld)
	free(pr_j)


#################### local promotion (cuda.md A2, step 2) ####################
# Second post-pass, run over the raw body BEFORE ptx_peephole: every
# stack slot — a declared local, a kernel-parameter spill, or a
# 'gpu for' capture cell — whose every appearance is a recognized load
# or store becomes a virtual register %l<N>, deleting its .local
# traffic entirely. The pass understands three access shapes:
#
#   lea+deref    add.u64 %ax, %sp, K  (or sub.u64 %ax, %bp, K)
#                ld.SFX %ax, [%ax];
#   carrier      the assignment shape: the lea'd address is pushed,
#                the RHS evaluates, then pop %bx / st.SFX [%bx], %ax
#   direct       ld.u64 %Rx, [%sp+K]; / st.u64 [%sp+K], %Rx;
#
# The register mirrors what a load of the slot would return: stores
# re-widen the stored bits with the slot's observed load suffix
# (shl + shr.s64 for signed widths, shr.u64 for unsigned, a plain mov
# at word width), so sub-word truncate-then-widen semantics survive
# promotion bit for bit. A slot with mismatched load suffixes, or a
# store narrower than its loads, simply stays in memory.
#
# Any stack address that escapes these shapes (&local fed to an
# intrinsic, an aggregate base offset later, an unrecognized [%sp+K]
# form) abandons the pass for the whole kernel — once an address is
# loose, no slot's deadness can be trusted. The untransformed body is
# always correct.
#
# Deleting a promoted slot's push moves %sp for its whole live range,
# so [%sp+K] references to OLDER slots inside that range shrink by 8
# and the scope pop that discarded the slot shrinks by 8 — the same
# offset model as ptx_peephole, over a longer span. Registers live
# across basic blocks (unlike step 1's pairs): the register write sits
# exactly where the memory write did, so every path reaching a load
# saw the same stores memory would have seen.

# %l registers allocated by the most recent ptx_promote (0 = bailed or
# nothing promotable); ptx_kernel_end reads it for the .reg declaration.
int ptx_prom_lregs

# Promoted 'gpu for' captures: per capture slot k the %l id (or -1) and
# the load suffix, consumed by ptx_kernel_end's prologue to seed the
# register from the parameter value. Null when no captures promoted.
int* ptx_prom_capreg
int* ptx_prom_capsfx
int ptx_prom_ncap

# Suffix codes: 1 .u64, 2 .s32, 3 .s16, 4 .u16, 5 .s8, 6 .u32, 7 .u8.
int ptx_prom_width(int sfxc):
	if (sfxc == 1):
		return 8
	if ((sfxc == 2) || (sfxc == 6)):
		return 4
	if ((sfxc == 3) || (sfxc == 4)):
		return 2
	return 1


# "ld.SFX %ax, [%ax];" -> suffix code, else 0.
int ptx_prom_load_sfx(char* b, int s, int e):
	if (ptx_peep_starts(b, s, e, c"ld.u64 %ax, [%ax];")):
		return 1
	if (ptx_peep_starts(b, s, e, c"ld.s32 %ax, [%ax];")):
		return 2
	if (ptx_peep_starts(b, s, e, c"ld.s16 %ax, [%ax];")):
		return 3
	if (ptx_peep_starts(b, s, e, c"ld.u16 %ax, [%ax];")):
		return 4
	if (ptx_peep_starts(b, s, e, c"ld.s8 %ax, [%ax];")):
		return 5
	if (ptx_peep_starts(b, s, e, c"ld.u32 %ax, [%ax];")):
		return 6
	if (ptx_peep_starts(b, s, e, c"ld.u8 %ax, [%ax];")):
		return 7
	return 0


# "st.SFX [%bx], %ax;" -> suffix code, else 0.
int ptx_prom_store_sfx(char* b, int s, int e):
	if (ptx_peep_starts(b, s, e, c"st.u64 [%bx], %ax;")):
		return 1
	if (ptx_peep_starts(b, s, e, c"st.u32 [%bx], %ax;")):
		return 6
	if (ptx_peep_starts(b, s, e, c"st.u16 [%bx], %ax;")):
		return 4
	if (ptx_peep_starts(b, s, e, c"st.u8 [%bx], %ax;")):
		return 7
	return 0


# Does the [s, e) line contain the pattern anywhere?
int ptx_prom_has(char* b, int s, int e, char* pat):
	int i = s
	while (i < e):
		if (ptx_peep_starts(b, i, e, pat)):
			return 1
		i = i + 1
	return 0


# Emit (into the rebuild buffer) the store of %<src>x into %l<lr> for a
# slot whose loads use suffix lsfx: re-widen the stored bits exactly as
# a store-then-reload through memory would.
int ptx_prom_widen(char* out, int outp, int lr, int src, int lsfx):
	if ((lsfx == 0) || (lsfx == 1)):
		outp = ptx_peep_put(out, outp, c"mov.u64 %l")
		outp = ptx_peep_put(out, outp, itoa(lr))
		outp = ptx_peep_put(out, outp, c", %")
		out[outp] = src
		outp = outp + 1
		outp = ptx_peep_put(out, outp, c"x;")
		out[outp] = 10
		return outp + 1
	int amt = 32
	if ((lsfx == 3) || (lsfx == 4)):
		amt = 48
	else if ((lsfx == 5) || (lsfx == 7)):
		amt = 56
	outp = ptx_peep_put(out, outp, c"shl.b64 %l")
	outp = ptx_peep_put(out, outp, itoa(lr))
	outp = ptx_peep_put(out, outp, c", %")
	out[outp] = src
	outp = outp + 1
	outp = ptx_peep_put(out, outp, c"x, ")
	outp = ptx_peep_put(out, outp, itoa(amt))
	outp = ptx_peep_put(out, outp, c";")
	out[outp] = 10
	outp = outp + 1
	if ((lsfx == 2) || (lsfx == 3) || (lsfx == 5)):
		outp = ptx_peep_put(out, outp, c"shr.s64 %l")
	else:
		outp = ptx_peep_put(out, outp, c"shr.u64 %l")
	outp = ptx_peep_put(out, outp, itoa(lr))
	outp = ptx_peep_put(out, outp, c", %l")
	outp = ptx_peep_put(out, outp, itoa(lr))
	outp = ptx_peep_put(out, outp, c", ")
	outp = ptx_peep_put(out, outp, itoa(amt))
	outp = ptx_peep_put(out, outp, c";")
	out[outp] = 10
	return outp + 1


# The prologue twin of ptx_prom_widen: seed a promoted capture's
# register from %cx (which holds the just-loaded parameter value).
void ptx_prom_cap_init(int lr, int lsfx):
	if ((lsfx == 0) || (lsfx == 1)):
		ptx_emit(c"mov.u64 %l")
		ptx_emit_int(lr)
		ptx_line(c", %cx;")
		return;
	int amt = 32
	if ((lsfx == 3) || (lsfx == 4)):
		amt = 48
	else if ((lsfx == 5) || (lsfx == 7)):
		amt = 56
	ptx_emit(c"shl.b64 %l")
	ptx_emit_int(lr)
	ptx_emit(c", %cx, ")
	ptx_emit_int(amt)
	ptx_line(c";")
	if ((lsfx == 2) || (lsfx == 3) || (lsfx == 5)):
		ptx_emit(c"shr.s64 %l")
	else:
		ptx_emit(c"shr.u64 %l")
	ptx_emit_int(lr)
	ptx_emit(c", %l")
	ptx_emit_int(lr)
	ptx_emit(c", ")
	ptx_emit_int(amt)
	ptx_line(c";")


# Rewrites ptx_body_buf in place (via a fresh buffer). See the section
# comment above for the model.
void ptx_promote():
	ptx_prom_lregs = 0
	ptx_prom_ncap = 0
	char* b = ptx_body_buf
	int n = ptx_body_pos
	if (n == 0):
		return

	# Count lines, record each line's start offset.
	int lines = 0
	int i = 0
	while (i < n):
		if (b[i] == 10):
			lines = lines + 1
		i = i + 1
	if (lines == 0):
		return
	int* ls = cast(int*, malloc(lines * __word_size__))
	int L = 0
	int start = 0
	i = 0
	while (i < n):
		if (b[i] == 10):
			ls[L] = start
			L = L + 1
			start = i + 1
		i = i + 1

	# Classify. Kinds: 0 other, 1 push-sub, 2 push-st, 3 pop/peek-ld,
	# 4 sp-add (N in val), 6 lea %ax,%sp,K, 7 label, 8 branch,
	# 9 lea %ax,%bp,-K, 10 deref load, 11 store via %bx,
	# 50/51/52 direct [%sp+K] unknown/load/store.
	int* kind = cast(int*, malloc(lines * __word_size__))
	int* val = cast(int*, malloc(lines * __word_size__))
	int* lreg2 = cast(int*, malloc(lines * __word_size__))  # reg char per line
	int* lsfx2 = cast(int*, malloc(lines * __word_size__))  # suffix per line
	int* sloti = cast(int*, malloc(lines * __word_size__))
	int* shift = cast(int*, malloc(lines * __word_size__))
	int* dec = cast(int*, malloc(lines * __word_size__))
	int* act = cast(int*, malloc(lines * __word_size__))    # 1 del, 2 load-mov, 3 store-widen
	int* tgt = cast(int*, malloc(lines * __word_size__))
	int s = 0
	int e = 0
	L = 0
	while (L < lines):
		s = ls[L]
		e = n - 1
		if (L + 1 < lines):
			e = ls[L + 1] - 1
		kind[L] = 0
		val[L] = 0
		lreg2[L] = 0
		lsfx2[L] = 0
		sloti[L] = 0
		shift[L] = 0
		dec[L] = 0
		act[L] = 0
		tgt[L] = 0 - 1
		if (ptx_peep_starts(b, s, e, c"sub.u64 %sp, %sp, 8;")):
			kind[L] = 1
		else if (ptx_peep_starts(b, s, e, c"st.u64 [%sp], %")):
			kind[L] = 2
			lreg2[L] = b[s + 15]
		else if (ptx_peep_starts(b, s, e, c"ld.u64 %") && ptx_peep_starts(b, s + 9, e, c"x, [%sp];")):
			kind[L] = 3
			lreg2[L] = b[s + 8]
		else if (ptx_peep_starts(b, s, e, c"ld.u64 %") && ptx_peep_starts(b, s + 9, e, c"x, [%sp+")):
			kind[L] = 51
			lreg2[L] = b[s + 8]
			val[L] = ptx_peep_num(b, s + 17)
		else if (ptx_peep_starts(b, s, e, c"st.u64 [%sp+")):
			kind[L] = 52
			val[L] = ptx_peep_num(b, s + 12)
			i = s + 12
			while ((b[i] >= '0') && (b[i] <= '9')):
				i = i + 1
			lreg2[L] = b[i + 4]
		else if (ptx_peep_starts(b, s, e, c"add.u64 %sp, %sp, ")):
			kind[L] = 4
			val[L] = ptx_peep_num(b, s + 18)
		else if (ptx_peep_starts(b, s, e, c"add.u64 %ax, %sp, ")):
			kind[L] = 6
			val[L] = ptx_peep_num(b, s + 18)
		else if (ptx_peep_starts(b, s, e, c"sub.u64 %ax, %bp, ")):
			kind[L] = 9
			val[L] = ptx_peep_num(b, s + 18)
		else if (ptx_peep_starts(b, s, e, c"bra ") || ptx_peep_starts(b, s, e, c"@%p bra ")):
			kind[L] = 8
		else if ((e > s) && (b[e - 1] == ':')):
			kind[L] = 7
		else:
			i = ptx_prom_load_sfx(b, s, e)
			if (i):
				kind[L] = 10
				lsfx2[L] = i
			else:
				i = ptx_prom_store_sfx(b, s, e)
				if (i):
					kind[L] = 11
					lsfx2[L] = i
				else if (ptx_peep_find_spref(b, s, e) >= 0):
					kind[L] = 50
					val[L] = ptx_peep_num(b, ptx_peep_find_spref(b, s, e) + 5)
		L = L + 1

	# Slot instances: created by pushes and (lazily) by capture leas.
	int cap_max = 520
	int imax = lines + cap_max + 1
	int* cap2inst = cast(int*, malloc(cap_max * __word_size__))
	i = 0
	while (i < cap_max):
		cap2inst[i] = 0 - 1
		i = i + 1
	int* ipush = cast(int*, malloc(imax * __word_size__))
	int* ikill = cast(int*, malloc(imax * __word_size__))
	int* islot = cast(int*, malloc(imax * __word_size__))
	int* iprom = cast(int*, malloc(imax * __word_size__))
	int* ilsfx = cast(int*, malloc(imax * __word_size__))   # load suffix seen
	int* isw = cast(int*, malloc(imax * __word_size__))     # narrowest store width
	int* ivpop = cast(int*, malloc(imax * __word_size__))   # closed by a value pop
	int* icap = cast(int*, malloc(imax * __word_size__))    # capture slot or -1
	int* ctgt = cast(int*, malloc(imax * __word_size__))    # carrier: target inst
	int* clea = cast(int*, malloc(imax * __word_size__))    # carrier: lea line
	int* cpop = cast(int*, malloc(imax * __word_size__))    # carrier: pop line
	int* ilreg = cast(int*, malloc(imax * __word_size__))
	i = 0
	while (i < imax):
		ipush[i] = 0 - 1
		ikill[i] = 0 - 1
		islot[i] = 0
		iprom[i] = 1
		ilsfx[i] = 0
		isw[i] = 8
		ivpop[i] = 0
		icap[i] = 0 - 1
		ctgt[i] = 0 - 1
		clea[i] = 0 - 1
		cpop[i] = 0 - 1
		ilreg[i] = 0 - 1
		i = i + 1
	int ninst = 0
	int ncap = 0
	int* stk = cast(int*, malloc(lines * __word_size__))
	int depth = 0
	int ok = 1

	# Scan: simulate depth, resolve every reference to its slot
	# instance, record the access or bail.
	int t = 0
	int w = 0
	L = 0
	while ((L < lines) && ok):
		int k = kind[L]
		if ((k == 6) || (k == 9)):
			t = 0 - 1
			if (k == 6):
				sloti[L] = depth - val[L] / 8 - 1
				if ((sloti[L] >= 0) && (sloti[L] < depth)):
					t = stk[sloti[L]]
				else:
					ok = 0
			else:
				i = val[L] / 8 - 1
				if ((i < 0) || (i >= cap_max)):
					ok = 0
				else:
					t = cap2inst[i]
					if (t < 0):
						t = ninst
						ninst = ninst + 1
						icap[t] = i
						cap2inst[i] = t
						if (i + 1 > ncap):
							ncap = i + 1
			if (ok && (t >= 0) && (ctgt[t] >= 0)):
				# a reference to a held address-carrier word
				ok = 0
			if (ok):
				if ((L + 1 < lines) && (kind[L + 1] == 10)):
					# lea+deref load
					if (ilsfx[t] == 0):
						ilsfx[t] = lsfx2[L + 1]
					else if (ilsfx[t] != lsfx2[L + 1]):
						iprom[t] = 0
					act[L] = 1
					tgt[L] = t
					act[L + 1] = 2
					tgt[L + 1] = t
					lreg2[L + 1] = 'a'
					L = L + 2
				else if ((L + 2 < lines) && (kind[L + 1] == 1) && (kind[L + 2] == 2) && (lreg2[L + 2] == 'a')):
					# the address rides the stack to an assignment
					w = ninst
					ninst = ninst + 1
					ctgt[w] = t
					clea[w] = L
					ipush[w] = L + 1
					islot[w] = depth
					stk[depth] = w
					depth = depth + 1
					L = L + 3
				else:
					# the address escapes: no slot is provably dead
					ok = 0
		else if (k == 1):
			if ((L + 1 < lines) && (kind[L + 1] == 2)):
				w = ninst
				ninst = ninst + 1
				ipush[w] = L
				islot[w] = depth
				stk[depth] = w
				depth = depth + 1
				act[L] = 1
				tgt[L] = w
				act[L + 1] = 3
				tgt[L + 1] = w
				L = L + 2
			else:
				ok = 0
		else if (k == 2):
			# a store to [%sp] with no preceding push: unexpected
			ok = 0
		else if (k == 3):
			if ((L + 1 < lines) && (kind[L + 1] == 4) && (val[L + 1] == 8)):
				# a value pop
				if (depth == 0):
					ok = 0
				else:
					depth = depth - 1
					w = stk[depth]
					if (ctgt[w] >= 0):
						t = ctgt[w]
						if ((lreg2[L] == 'b') && (L + 2 < lines) && (kind[L + 2] == 11)):
							if (icap[t] >= 0):
								# a captured pointer reassigned
								iprom[t] = 0
							i = ptx_prom_width(lsfx2[L + 2])
							if (i < isw[t]):
								isw[t] = i
							act[clea[w]] = 1
							tgt[clea[w]] = t
							act[ipush[w]] = 1
							tgt[ipush[w]] = t
							act[ipush[w] + 1] = 1
							tgt[ipush[w] + 1] = t
							act[L] = 1
							tgt[L] = t
							act[L + 1] = 1
							tgt[L + 1] = t
							act[L + 2] = 3
							tgt[L + 2] = t
							lreg2[L + 2] = 'a'
							cpop[w] = L
							L = L + 3
						else:
							# the held address is consumed some other way
							ok = 0
					else:
						ivpop[w] = 1
						L = L + 2
			else:
				# bare peek of the top word
				if (depth == 0):
					ok = 0
				else:
					t = stk[depth - 1]
					if (ctgt[t] >= 0):
						ok = 0
					else:
						if (ilsfx[t] == 0):
							ilsfx[t] = 1
						else if (ilsfx[t] != 1):
							iprom[t] = 0
						act[L] = 2
						tgt[L] = t
						L = L + 1
		else if (k == 4):
			w = val[L] / 8
			if (w > depth):
				ok = 0
			else:
				i = 0
				while (i < w):
					depth = depth - 1
					ikill[stk[depth]] = L
					if (ctgt[stk[depth]] >= 0):
						ok = 0
					i = i + 1
				L = L + 1
		else if ((k == 50) || (k == 51) || (k == 52)):
			sloti[L] = depth - val[L] / 8 - 1
			t = 0 - 1
			if ((sloti[L] >= 0) && (sloti[L] < depth)):
				t = stk[sloti[L]]
			if (t < 0):
				ok = 0
			else if (ctgt[t] >= 0):
				ok = 0
			else if (k == 51):
				if (ilsfx[t] == 0):
					ilsfx[t] = 1
				else if (ilsfx[t] != 1):
					iprom[t] = 0
				act[L] = 2
				tgt[L] = t
				L = L + 1
			else if (k == 52):
				act[L] = 3
				tgt[L] = t
				L = L + 1
			else:
				iprom[t] = 0
				L = L + 1
		else if ((k == 7) || (k == 8)):
			L = L + 1
		else:
			if (k == 0):
				s = ls[L]
				e = n - 1
				if (L + 1 < lines):
					e = ls[L + 1] - 1
				if (ptx_prom_has(b, s, e, c"%sp") || ptx_prom_has(b, s, e, c"%bp")):
					# an unrecognized line touching the stack registers
					ok = 0
			L = L + 1
	if (ok):
		# an address carrier still open at the end of the body
		i = 0
		while (i < depth):
			if (ctgt[stk[i]] >= 0):
				ok = 0
			i = i + 1

	# Decide the promoted set and allocate %l registers.
	int nl = 0
	if (ok):
		i = 0
		while (i < ninst):
			t = iprom[i]
			if (ctgt[i] >= 0):
				t = 0
			if (ivpop[i]):
				t = 0
			if ((ilsfx[i] != 0) && (ptx_prom_width(ilsfx[i]) > isw[i])):
				t = 0
			iprom[i] = t
			if (t):
				ilreg[i] = nl
				nl = nl + 1
			i = i + 1

	if (ok && (nl > 0)):
		# Promoted captures: hand the prologue their register + suffix.
		if (ncap > 0):
			ptx_prom_ncap = ncap
			ptx_prom_capreg = cast(int*, malloc(ncap * __word_size__))
			ptx_prom_capsfx = cast(int*, malloc(ncap * __word_size__))
			i = 0
			while (i < ncap):
				ptx_prom_capreg[i] = 0 - 1
				ptx_prom_capsfx[i] = 0
				i = i + 1
			i = 0
			while (i < ninst):
				if ((icap[i] >= 0) && iprom[i]):
					ptx_prom_capreg[icap[i]] = ilreg[i]
					ptx_prom_capsfx[icap[i]] = ilsfx[i]
				i = i + 1

		# Offset rewrites: each deleted stack word moves %sp over its
		# live range, so [%sp+K] references to older slots shrink by 8
		# and the scope pop that covered the word shrinks by 8.
		int rk = 0
		i = 0
		while (i < ninst):
			if (iprom[i] && (icap[i] < 0)):
				t = ipush[i] + 2
				w = lines
				if (ikill[i] >= 0):
					w = ikill[i]
					dec[w] = dec[w] + 8
				while (t < w):
					rk = kind[t]
					if ((rk == 6) || (rk == 50) || (rk == 51) || (rk == 52)):
						if (sloti[t] < islot[i]):
							shift[t] = shift[t] + 8
					t = t + 1
			i = i + 1
		i = 0
		while (i < ninst):
			if ((ctgt[i] >= 0) && (cpop[i] >= 0) && iprom[ctgt[i]]):
				t = ipush[i] + 2
				while (t < cpop[i]):
					rk = kind[t]
					if ((rk == 6) || (rk == 50) || (rk == 51) || (rk == 52)):
						if (sloti[t] < islot[i]):
							shift[t] = shift[t] + 8
					t = t + 1
			i = i + 1

		# Rebuild the body into a fresh scratch buffer.
		int cap2 = n * 2 + 256
		char* out = malloc(cap2)
		int outp = 0
		int ap = 0
		L = 0
		while (L < lines):
			s = ls[L]
			e = n - 1
			if (L + 1 < lines):
				e = ls[L + 1] - 1
			ap = 0
			if ((act[L] > 0) && (tgt[L] >= 0)):
				if (iprom[tgt[L]]):
					ap = act[L]
			if (ap == 1):
				L = L + 1
			else if (ap == 2):
				outp = ptx_peep_put(out, outp, c"mov.u64 %")
				out[outp] = lreg2[L]
				outp = outp + 1
				outp = ptx_peep_put(out, outp, c"x, %l")
				outp = ptx_peep_put(out, outp, itoa(ilreg[tgt[L]]))
				out[outp] = ';'
				out[outp + 1] = 10
				outp = outp + 2
				L = L + 1
			else if (ap == 3):
				outp = ptx_prom_widen(out, outp, ilreg[tgt[L]], lreg2[L], ilsfx[tgt[L]])
				L = L + 1
			else if ((kind[L] == 4) && (dec[L] > 0)):
				outp = ptx_peep_put(out, outp, c"add.u64 %sp, %sp, ")
				outp = ptx_peep_put(out, outp, itoa(val[L] - dec[L]))
				out[outp] = ';'
				out[outp + 1] = 10
				outp = outp + 2
				L = L + 1
			else if ((kind[L] == 6) && (shift[L] > 0)):
				outp = ptx_peep_put(out, outp, c"add.u64 %ax, %sp, ")
				outp = ptx_peep_put(out, outp, itoa(val[L] - shift[L]))
				out[outp] = ';'
				out[outp + 1] = 10
				outp = outp + 2
				L = L + 1
			else if (((kind[L] == 50) || (kind[L] == 51) || (kind[L] == 52)) && (shift[L] > 0)):
				i = ptx_peep_find_spref(b, s, e)
				t = s
				while (t < i + 5):
					out[outp] = b[t]
					outp = outp + 1
					t = t + 1
				outp = ptx_peep_put(out, outp, itoa(val[L] - shift[L]))
				while ((b[t] >= '0') && (b[t] <= '9')):
					t = t + 1
				while (t < e):
					out[outp] = b[t]
					outp = outp + 1
					t = t + 1
				out[outp] = 10
				outp = outp + 1
				L = L + 1
			else:
				t = s
				while (t < e):
					out[outp] = b[t]
					outp = outp + 1
					t = t + 1
				out[outp] = 10
				outp = outp + 1
				L = L + 1
		free(ptx_body_buf)
		ptx_body_buf = out
		ptx_body_size = cap2
		ptx_body_pos = outp
		ptx_prom_lregs = nl

	free(ls)
	free(kind)
	free(val)
	free(lreg2)
	free(lsfx2)
	free(sloti)
	free(shift)
	free(dec)
	free(act)
	free(tgt)
	free(cap2inst)
	free(ipush)
	free(ikill)
	free(islot)
	free(iprom)
	free(ilsfx)
	free(isw)
	free(ivpop)
	free(icap)
	free(ctgt)
	free(clea)
	free(cpop)
	free(ilreg)
	free(stk)


# Open a kernel: the module header is written once, body scratch resets.
# name is an owned copy; ptx_kernel_end frees it.
void ptx_kernel_begin(char* name):
	if (ptx_used == 0):
		ptx_used = 1
		ptx_emit_to_module = 1
		ptx_line(c".version 6.0")
		ptx_line(c".target sm_52")
		ptx_line(c".address_size 64")
		ptx_emit_char(10)
		ptx_emit_to_module = 0
	ptx_kernel_name = name
	ptx_body_pos = 0
	ptx_pending_fcmp = 0


# Close a kernel: stitch ".visible .entry name(params) { prologue body }"
# into the module. nparams parameters are declared .param .u64 p0..pN.
# reserve_bytes > 0 additionally reserves capture slots below %bp and
# stores every parameter into its slot (the 'gpu for' outlining layout:
# capture k lives at [%bp - (k+1)*8], a fixed offset discovered mid-body).
void ptx_kernel_end(int nparams, int reserve_bytes):
	ptx_promote()
	ptx_peephole()
	ptx_emit_to_module = 1
	ptx_emit(c".visible .entry ")
	ptx_emit(ptx_kernel_name)
	ptx_emit(c"(")
	int i = 0
	while (i < nparams):
		if (i > 0):
			ptx_emit(c", ")
		ptx_emit(c".param .u64 p")
		ptx_emit_int(i)
		i = i + 1
	ptx_line(c")")
	ptx_line(c"{")
	ptx_line(c".reg .b64 %ax, %bx, %cx, %sp, %bp;")
	ptx_line(c".reg .b32 %w0, %w1;")
	ptx_line(c".reg .f32 %fa, %fb;")
	ptx_line(c".reg .f64 %da, %db;")
	ptx_line(c".reg .pred %p;")
	if (ptx_peep_vregs > 0):
		# Virtual registers the peephole substituted for push/pop pairs
		# (one per nesting depth, reused across pairs).
		ptx_emit(c".reg .b64 %v<")
		ptx_emit_int(ptx_peep_vregs)
		ptx_line(c">;")
	if (ptx_prom_lregs > 0):
		# Registers ptx_promote substituted for whole stack slots.
		ptx_emit(c".reg .b64 %l<")
		ptx_emit_int(ptx_prom_lregs)
		ptx_line(c">;")
	ptx_line(c".local .align 8 .b8 __wstack[4096];")
	ptx_line(c"mov.u64 %sp, __wstack;")
	ptx_line(c"cvta.local.u64 %sp, %sp;")
	ptx_line(c"add.u64 %sp, %sp, 4096;")
	ptx_line(c"mov.u64 %bp, %sp;")
	if (reserve_bytes > 0):
		ptx_emit(c"sub.u64 %sp, %sp, ")
		ptx_emit_int(reserve_bytes)
		ptx_line(c";")
		# Captured values: parameter k -> its fixed slot below %bp
		# (and, when promoted, its %l register)
		int k = 0
		while (k < nparams):
			ptx_emit(c"ld.param.u64 %cx, [p")
			ptx_emit_int(k)
			ptx_line(c"];")
			ptx_emit(c"st.u64 [%bp+-")
			ptx_emit_int((k + 1) << 3)
			ptx_line(c"], %cx;")
			if ((ptx_prom_capreg != 0) && (k < ptx_prom_ncap)):
				if (ptx_prom_capreg[k] >= 0):
					ptx_prom_cap_init(ptx_prom_capreg[k], ptx_prom_capsfx[k])
			k = k + 1
	# The body (already emitted to scratch while parsing)
	i = 0
	while (i < ptx_body_pos):
		ptx_emit_char(ptx_body_buf[i])
		i = i + 1
	ptx_line(c"}")
	ptx_emit_char(10)
	ptx_emit_to_module = 0
	free(ptx_kernel_name)
	ptx_kernel_name = 0
	ptx_body_pos = 0
	if (ptx_prom_capreg != 0):
		free(ptx_prom_capreg)
		free(ptx_prom_capsfx)
		ptx_prom_capreg = 0
		ptx_prom_capsfx = 0
	ptx_prom_ncap = 0


# Called once per batch compilation, after every user file has compiled
# (compiler/compiler.w, next to test_registry_finish): synthesize
# `char* __w_ptx_module()` returning the embedded NUL-terminated module
# text, and honor --ptx=<path>. No-op for programs without kernels.
void ptx_finish_module():
	if (ptx_used == 0):
		# No kernels — but a program that imported lib.cuda (its
		# prototype declares __w_ptx_module) may still use the memory
		# API. Define the accessor returning an empty module so the
		# symbol resolves; __w_gpu_init skips the module load for it.
		if (sym_lookup(c"__w_ptx_module") >= 0):
			be_function_define_declare(c"__w_ptx_module")
			be_function_prologue()
			be_emit_inline_cstr(0, c"")
			ret()
			be_function_epilogue()
		return;
	ptx_emit_to_module = 1
	ptx_emit_char(0)
	ptx_emit_to_module = 0
	int text_len = ptx_module_pos - 1
	if (ptx_dump_path != 0):
		/* O_WRONLY|O_CREAT|O_TRUNC, mode 0644 */
		int fd = open(ptx_dump_path, 577, 420)
		if (fd < 0):
			error(c"could not open the --ptx output file")
		write(fd, ptx_module_buf, text_len)
		close(fd)
	be_function_define_declare(c"__w_ptx_module")
	be_function_prologue()
	be_emit_inline_cstr(text_len, ptx_module_buf)
	ret()
	be_function_epilogue()
