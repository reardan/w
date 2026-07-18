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
	ptx_line(c".reg .b32 %w0;")
	ptx_line(c".reg .f32 %fa, %fb;")
	ptx_line(c".reg .f64 %da, %db;")
	ptx_line(c".reg .pred %p;")
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
		int k = 0
		while (k < nparams):
			ptx_emit(c"ld.param.u64 %cx, [p")
			ptx_emit_int(k)
			ptx_line(c"];")
			ptx_emit(c"st.u64 [%bp+-")
			ptx_emit_int((k + 1) << 3)
			ptx_line(c"], %cx;")
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


# Called once per batch compilation, after every user file has compiled
# (compiler/compiler.w, next to test_registry_finish): synthesize
# `char* __w_ptx_module()` returning the embedded NUL-terminated module
# text, and honor --ptx=<path>. No-op for programs without kernels.
void ptx_finish_module():
	if (ptx_used == 0):
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
