/*
SSE scalar float encodings, in the same hardcoded-byte style as x86.w
(fixed registers, no general ModRM encoder). Float values travel through
the compiler's integer pipeline as raw IEEE-754 bits in eax/rax; XMM
registers are used only inside a single operation, so every encoding here
is reg-reg. Convention: xmm0 holds the left operand, xmm1 the right.

float16 conversions use F16C (VEX-encoded vcvtph2ps/vcvtps2ph), which
requires an Ivy Bridge/Zen or newer CPU (2012+); there is no software
fallback.
*/


# AArch64 float support (dispatched on target_isa). Float bits still ride
# the integer pipeline in x0/x1; xmm0/xmm1 map to s0/d0 and s1/d1, and the
# GPR<->XMM transfers become fmov. Every A64 encoding was checked against
# the assembler. a64/op/arm64_cset/arm64_setcc_cond come from arm64.w.
void a64(int w);
int op(int msb, int low);
void arm64_cset(int cond);
int arm64_setcc_cond(int setcc);
void error(char *s);


########################### GPR <-> XMM transfers ############################

/* movd xmm0, eax */
void movd_xmm0_eax():
	if (target_isa == 1):
		a64(op(0x1e, 0x270000))   # fmov s0, w0
		return
	emit(4, c"\x66\x0f\x6e\xc0")


/* movd xmm0, ebx */
void movd_xmm0_ebx():
	if (target_isa == 1):
		a64(op(0x1e, 0x270020))   # fmov s0, w1
		return
	emit(4, c"\x66\x0f\x6e\xc3")


/* movd xmm1, eax */
void movd_xmm1_eax():
	if (target_isa == 1):
		a64(op(0x1e, 0x270001))   # fmov s1, w0
		return
	emit(4, c"\x66\x0f\x6e\xc8")


/* movd xmm1, ebx */
void movd_xmm1_ebx():
	if (target_isa == 1):
		a64(op(0x1e, 0x270021))   # fmov s1, w1
		return
	emit(4, c"\x66\x0f\x6e\xcb")


/* movd eax, xmm0 */
void movd_eax_xmm0():
	if (target_isa == 1):
		a64(op(0x1e, 0x260000))   # fmov w0, s0
		return
	emit(4, c"\x66\x0f\x7e\xc0")


/* movq xmm0, rax (x64 only) */
void movq_xmm0_rax():
	if (target_isa == 1):
		a64(op(0x9e, 0x670000))   # fmov d0, x0
		return
	emit(5, c"\x66\x48\x0f\x6e\xc0")


/* movq xmm0, rbx (x64 only) */
void movq_xmm0_rbx():
	if (target_isa == 1):
		a64(op(0x9e, 0x670020))   # fmov d0, x1
		return
	emit(5, c"\x66\x48\x0f\x6e\xc3")


/* movq xmm1, rax (x64 only) */
void movq_xmm1_rax():
	if (target_isa == 1):
		a64(op(0x9e, 0x670001))   # fmov d1, x0
		return
	emit(5, c"\x66\x48\x0f\x6e\xc8")


/* movq xmm1, rbx (x64 only) */
void movq_xmm1_rbx():
	if (target_isa == 1):
		a64(op(0x9e, 0x670021))   # fmov d1, x1
		return
	emit(5, c"\x66\x48\x0f\x6e\xcb")


/* movq rax, xmm0 (x64 only) */
void movq_rax_xmm0():
	if (target_isa == 1):
		a64(op(0x9e, 0x660000))   # fmov x0, d0
		return
	emit(5, c"\x66\x48\x0f\x7e\xc0")


############################ float32 arithmetic ##############################

/* addss xmm0, xmm1 */
void addss():
	if (target_isa == 1):
		a64(op(0x1e, 0x212800))   # fadd s0, s0, s1
		return
	emit(4, c"\xf3\x0f\x58\xc1")


/* subss xmm0, xmm1 */
void subss():
	if (target_isa == 1):
		a64(op(0x1e, 0x213800))   # fsub s0, s0, s1
		return
	emit(4, c"\xf3\x0f\x5c\xc1")


/* mulss xmm0, xmm1 */
void mulss():
	if (target_isa == 1):
		a64(op(0x1e, 0x210800))   # fmul s0, s0, s1
		return
	emit(4, c"\xf3\x0f\x59\xc1")


/* divss xmm0, xmm1 */
void divss():
	if (target_isa == 1):
		a64(op(0x1e, 0x211800))   # fdiv s0, s0, s1
		return
	emit(4, c"\xf3\x0f\x5e\xc1")


############################ float64 arithmetic ##############################

/* addsd xmm0, xmm1 */
void addsd():
	if (target_isa == 1):
		a64(op(0x1e, 0x612800))   # fadd d0, d0, d1
		return
	emit(4, c"\xf2\x0f\x58\xc1")


/* subsd xmm0, xmm1 */
void subsd():
	if (target_isa == 1):
		a64(op(0x1e, 0x613800))   # fsub d0, d0, d1
		return
	emit(4, c"\xf2\x0f\x5c\xc1")


/* mulsd xmm0, xmm1 */
void mulsd():
	if (target_isa == 1):
		a64(op(0x1e, 0x610800))   # fmul d0, d0, d1
		return
	emit(4, c"\xf2\x0f\x59\xc1")


/* divsd xmm0, xmm1 */
void divsd():
	if (target_isa == 1):
		a64(op(0x1e, 0x611800))   # fdiv d0, d0, d1
		return
	emit(4, c"\xf2\x0f\x5e\xc1")


############################### comparisons ##################################

/* ucomiss xmm0, xmm1: sets ZF/CF like an unsigned integer compare */
void ucomiss():
	if (target_isa == 1):
		a64(op(0x1e, 0x212000))   # fcmp s0, s1
		return
	emit(3, c"\x0f\x2e\xc1")


/* ucomisd xmm0, xmm1 */
void ucomisd():
	if (target_isa == 1):
		a64(op(0x1e, 0x612000))   # fcmp d0, d1
		return
	emit(4, c"\x66\x0f\x2e\xc1")


/* setCC %al ; movzbl %al,%eax (the compare itself is emitted separately)
   setcc_opcode is the second setCC byte: 0x97 seta, 0x93 setae, 0x94
   sete, 0x95 setne. On AArch64 the fcmp already set the flags, so this is
   just a cset; the unsigned condition codes map to ordered float results
   for non-NaN operands. */
void setcc_movzx_eax(int setcc_opcode):
	if (target_isa == 1):
		arm64_cset(arm64_setcc_cond(setcc_opcode))
		return
	emit_int8(15)
	emit_int8(setcc_opcode)
	emit(4, c"\xc0\x0f\xb6\xc0")


############################### conversions ##################################
# The int <-> float conversions take the integer at the target word width
# (REX.W on x64, where int is 8 bytes), matching W's int semantics.

/* cvtsi2ss xmm0, eax/rax */
void cvtsi2ss_xmm0_eax():
	if (target_isa == 1):
		a64(op(0x9e, 0x220000))   # scvtf s0, x0
		return
	emit(1, c"\xf3")
	emit_x64_opcode()
	emit(3, c"\x0f\x2a\xc0")


/* cvtsi2ss xmm0, ebx/rbx */
void cvtsi2ss_xmm0_ebx():
	if (target_isa == 1):
		a64(op(0x9e, 0x220020))   # scvtf s0, x1
		return
	emit(1, c"\xf3")
	emit_x64_opcode()
	emit(3, c"\x0f\x2a\xc3")


/* cvtsi2ss xmm1, eax/rax */
void cvtsi2ss_xmm1_eax():
	if (target_isa == 1):
		a64(op(0x9e, 0x220001))   # scvtf s1, x0
		return
	emit(1, c"\xf3")
	emit_x64_opcode()
	emit(3, c"\x0f\x2a\xc8")


/* cvtsi2ss xmm1, ebx/rbx */
void cvtsi2ss_xmm1_ebx():
	if (target_isa == 1):
		a64(op(0x9e, 0x220021))   # scvtf s1, x1
		return
	emit(1, c"\xf3")
	emit_x64_opcode()
	emit(3, c"\x0f\x2a\xcb")


/* cvtsi2sd xmm0, rax (x64 only) */
void cvtsi2sd_xmm0_rax():
	if (target_isa == 1):
		a64(op(0x9e, 0x620000))   # scvtf d0, x0
		return
	emit(5, c"\xf2\x48\x0f\x2a\xc0")


/* cvtsi2sd xmm0, rbx (x64 only) */
void cvtsi2sd_xmm0_rbx():
	if (target_isa == 1):
		a64(op(0x9e, 0x620020))   # scvtf d0, x1
		return
	emit(5, c"\xf2\x48\x0f\x2a\xc3")


/* cvtsi2sd xmm1, rax (x64 only) */
void cvtsi2sd_xmm1_rax():
	if (target_isa == 1):
		a64(op(0x9e, 0x620001))   # scvtf d1, x0
		return
	emit(5, c"\xf2\x48\x0f\x2a\xc8")


/* cvtsi2sd xmm1, rbx (x64 only) */
void cvtsi2sd_xmm1_rbx():
	if (target_isa == 1):
		a64(op(0x9e, 0x620021))   # scvtf d1, x1
		return
	emit(5, c"\xf2\x48\x0f\x2a\xcb")


/* cvttss2si eax/rax, xmm0 (truncating float32 -> int) */
void cvttss2si_eax_xmm0():
	if (target_isa == 1):
		a64(op(0x9e, 0x380000))   # fcvtzs x0, s0
		return
	emit(1, c"\xf3")
	emit_x64_opcode()
	emit(3, c"\x0f\x2c\xc0")


/* cvttsd2si rax, xmm0 (truncating float64 -> int, x64 only) */
void cvttsd2si_rax_xmm0():
	if (target_isa == 1):
		a64(op(0x9e, 0x780000))   # fcvtzs x0, d0
		return
	emit(5, c"\xf2\x48\x0f\x2c\xc0")


/* cvtss2sd xmm0, xmm0 */
void cvtss2sd_xmm0():
	if (target_isa == 1):
		a64(op(0x1e, 0x22c000))   # fcvt d0, s0
		return
	emit(4, c"\xf3\x0f\x5a\xc0")


/* cvtss2sd xmm1, xmm1 */
void cvtss2sd_xmm1():
	if (target_isa == 1):
		a64(op(0x1e, 0x22c021))   # fcvt d1, s1
		return
	emit(4, c"\xf3\x0f\x5a\xc9")


/* cvtsd2ss xmm0, xmm0 */
void cvtsd2ss_xmm0():
	if (target_isa == 1):
		a64(op(0x1e, 0x624000))   # fcvt s0, d0
		return
	emit(4, c"\xf2\x0f\x5a\xc0")


########################### float16 (F16C, VEX) ##############################

/* vcvtph2ps xmm0, xmm0: widen the half in the low 16 bits to float32 */
void vcvtph2ps_xmm0():
	if (target_isa == 1):
		error(c"arm64: float16 is not implemented")
		return
	emit(5, c"\xc4\xe2\x79\x13\xc0")


/* vcvtps2ph xmm0, xmm0, 4: narrow float32 to half, round-to-nearest-even */
void vcvtps2ph_xmm0():
	if (target_isa == 1):
		error(c"arm64: float16 is not implemented")
		return
	emit(6, c"\xc4\xe3\x79\x1d\xc0\x04")


############################### sign flips ###################################

/* btc rax, 63: flip the float64 sign bit (x64 only) */
void btc_rax_63():
	if (target_isa == 1):
		a64(op(0xd2, 0x410000))   # eor x0, x0, #0x8000000000000000
		return
	emit(5, c"\x48\x0f\xba\xf8\x3f")
