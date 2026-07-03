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


########################### GPR <-> XMM transfers ############################

/* movd xmm0, eax */
void movd_xmm0_eax():
	emit(4, "\x66\x0f\x6e\xc0")


/* movd xmm0, ebx */
void movd_xmm0_ebx():
	emit(4, "\x66\x0f\x6e\xc3")


/* movd xmm1, eax */
void movd_xmm1_eax():
	emit(4, "\x66\x0f\x6e\xc8")


/* movd xmm1, ebx */
void movd_xmm1_ebx():
	emit(4, "\x66\x0f\x6e\xcb")


/* movd eax, xmm0 */
void movd_eax_xmm0():
	emit(4, "\x66\x0f\x7e\xc0")


/* movq xmm0, rax (x64 only) */
void movq_xmm0_rax():
	emit(5, "\x66\x48\x0f\x6e\xc0")


/* movq xmm0, rbx (x64 only) */
void movq_xmm0_rbx():
	emit(5, "\x66\x48\x0f\x6e\xc3")


/* movq xmm1, rax (x64 only) */
void movq_xmm1_rax():
	emit(5, "\x66\x48\x0f\x6e\xc8")


/* movq xmm1, rbx (x64 only) */
void movq_xmm1_rbx():
	emit(5, "\x66\x48\x0f\x6e\xcb")


/* movq rax, xmm0 (x64 only) */
void movq_rax_xmm0():
	emit(5, "\x66\x48\x0f\x7e\xc0")


############################ float32 arithmetic ##############################

/* addss xmm0, xmm1 */
void addss():
	emit(4, "\xf3\x0f\x58\xc1")


/* subss xmm0, xmm1 */
void subss():
	emit(4, "\xf3\x0f\x5c\xc1")


/* mulss xmm0, xmm1 */
void mulss():
	emit(4, "\xf3\x0f\x59\xc1")


/* divss xmm0, xmm1 */
void divss():
	emit(4, "\xf3\x0f\x5e\xc1")


############################ float64 arithmetic ##############################

/* addsd xmm0, xmm1 */
void addsd():
	emit(4, "\xf2\x0f\x58\xc1")


/* subsd xmm0, xmm1 */
void subsd():
	emit(4, "\xf2\x0f\x5c\xc1")


/* mulsd xmm0, xmm1 */
void mulsd():
	emit(4, "\xf2\x0f\x59\xc1")


/* divsd xmm0, xmm1 */
void divsd():
	emit(4, "\xf2\x0f\x5e\xc1")


############################### comparisons ##################################

/* ucomiss xmm0, xmm1: sets ZF/CF like an unsigned integer compare */
void ucomiss():
	emit(3, "\x0f\x2e\xc1")


/* ucomisd xmm0, xmm1 */
void ucomisd():
	emit(4, "\x66\x0f\x2e\xc1")


/* setCC %al ; movzbl %al,%eax (the compare itself is emitted separately)
   setcc_opcode is the second setCC byte: 0x97 seta, 0x93 setae, 0x94
   sete, 0x95 setne */
void setcc_movzx_eax(int setcc_opcode):
	emit_int8(15)
	emit_int8(setcc_opcode)
	emit(4, "\xc0\x0f\xb6\xc0")


############################### conversions ##################################
# The int <-> float conversions take the integer at the target word width
# (REX.W on x64, where int is 8 bytes), matching W's int semantics.

/* cvtsi2ss xmm0, eax/rax */
void cvtsi2ss_xmm0_eax():
	emit(1, "\xf3")
	emit_x64_opcode()
	emit(3, "\x0f\x2a\xc0")


/* cvtsi2ss xmm0, ebx/rbx */
void cvtsi2ss_xmm0_ebx():
	emit(1, "\xf3")
	emit_x64_opcode()
	emit(3, "\x0f\x2a\xc3")


/* cvtsi2ss xmm1, eax/rax */
void cvtsi2ss_xmm1_eax():
	emit(1, "\xf3")
	emit_x64_opcode()
	emit(3, "\x0f\x2a\xc8")


/* cvtsi2ss xmm1, ebx/rbx */
void cvtsi2ss_xmm1_ebx():
	emit(1, "\xf3")
	emit_x64_opcode()
	emit(3, "\x0f\x2a\xcb")


/* cvtsi2sd xmm0, rax (x64 only) */
void cvtsi2sd_xmm0_rax():
	emit(5, "\xf2\x48\x0f\x2a\xc0")


/* cvtsi2sd xmm0, rbx (x64 only) */
void cvtsi2sd_xmm0_rbx():
	emit(5, "\xf2\x48\x0f\x2a\xc3")


/* cvtsi2sd xmm1, rax (x64 only) */
void cvtsi2sd_xmm1_rax():
	emit(5, "\xf2\x48\x0f\x2a\xc8")


/* cvtsi2sd xmm1, rbx (x64 only) */
void cvtsi2sd_xmm1_rbx():
	emit(5, "\xf2\x48\x0f\x2a\xcb")


/* cvttss2si eax/rax, xmm0 (truncating float32 -> int) */
void cvttss2si_eax_xmm0():
	emit(1, "\xf3")
	emit_x64_opcode()
	emit(3, "\x0f\x2c\xc0")


/* cvttsd2si rax, xmm0 (truncating float64 -> int, x64 only) */
void cvttsd2si_rax_xmm0():
	emit(5, "\xf2\x48\x0f\x2c\xc0")


/* cvtss2sd xmm0, xmm0 */
void cvtss2sd_xmm0():
	emit(4, "\xf3\x0f\x5a\xc0")


/* cvtss2sd xmm1, xmm1 */
void cvtss2sd_xmm1():
	emit(4, "\xf3\x0f\x5a\xc9")


/* cvtsd2ss xmm0, xmm0 */
void cvtsd2ss_xmm0():
	emit(4, "\xf2\x0f\x5a\xc0")


########################### float16 (F16C, VEX) ##############################

/* vcvtph2ps xmm0, xmm0: widen the half in the low 16 bits to float32 */
void vcvtph2ps_xmm0():
	emit(5, "\xc4\xe2\x79\x13\xc0")


/* vcvtps2ph xmm0, xmm0, 4: narrow float32 to half, round-to-nearest-even */
void vcvtps2ph_xmm0():
	emit(6, "\xc4\xe3\x79\x1d\xc0\x04")


############################### sign flips ###################################

/* btc rax, 63: flip the float64 sign bit (x64 only) */
void btc_rax_63():
	emit(5, "\x48\x0f\xba\xf8\x3f")
