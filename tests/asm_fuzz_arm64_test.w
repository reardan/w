/*
arm64 (A64) property/fuzz round-trip test (issue #171): randomized
extension of asm_arm64_test's corpus round-trips, plus a dedicated
raw-round-trip check for the "recognized-but-opaque" madd/msub and
scalar-FP forms that docs/projects/assembler_disassembler.md documents
as decoded-to-mnemonic-but-not-modeled (their operands are not fully
reconstructed, so parse(format(...)) cannot be asserted for them — see
test_opaque_raw_roundtrip below).

Instruction generation reuses the existing corpus-enumeration machinery:
each iteration samples a random line from tests/asm/corpus_arm64.txt (the
same fixture asm_arm64_test's corpus round-trip parses), parses it into
a structured asm_insn, then randomizes its concrete register/immediate/
displacement payload. Adding a new instruction form to
tests/asm/corpus_arm64.txt is automatically picked up by future fuzz
runs, with no separate form table to update.

Two properties are checked per generated instruction, matching the
issue's wording literally (insn has no equality operator, so canonical
text/bytes are the equality proxy, as elsewhere in this test suite):

  - decode(encode(insn)) == insn: byte-identity of encode -> decode ->
    encode, plus format-text identity of the two decoded instructions.
  - parse(format(insn)) == insn: format the mutated insn, parse it back,
    and require a second format to reproduce the same text.

Mutation scope, and why: GP register operands (kind reg) are randomized
over x0-x30/w0-w30 (register 31 means sp in this library's model —
asm_reg_name_arm64 always renders it "sp"/"wsp" — so an operand already
pinned to 31 by the corpus form, e.g. "mov x28,sp", is left alone rather
than risking a nonsensical mutation target; nothing else needs to avoid
31, since format/parse/encode/decode treat it uniformly). True immediate
operands (kind imm — add/sub/movz/svc/etc.) are randomized within a
small unsigned range that stays legal for every immediate-bearing form
this library supports, without needing per-mnemonic bit-width knowledge.
Memory displacements are randomized as a small non-negative multiple of
the access size, which stays within the legal immediate range for the
unsigned-offset, pre-index and post-index addressing modes alike.
Branch/adr targets and condition-code operands (kind label) are left
untouched: their legal encodings are per-mnemonic (26/19/14-bit signed
word counts, sp/pc-relative computations) and modeling that is exactly
the "supported subset" scope this fuzz harness avoids re-deriving —
these still round-trip on each sampled corpus form's original value.

docs/projects/assembler_disassembler.md.
*/
import lib.lib
import lib.assert
import libs.asm.insn
import libs.asm.hexutil
import libs.asm.arm64_decode
import libs.asm.arm64_encode
import libs.asm.arm64_text
import libs.asm.arm64_format
import tests.asm_fuzz_prng


int asm_fuzz_bytes4_equal(char* a, char* b):
	int i = 0
	while (i < 4):
		if ((a[i] & 255) != (b[i] & 255)):
			return 1 == 2
		i = i + 1
	return 1


void asm_fuzz_arm64_mutate_operand(asm_operand* op):
	if (op.kind == ASM_OP_REG()):
		if (op.reg != 31):
			op.reg = fuzz_range(31)
		return
	if (op.kind == ASM_OP_IMM()):
		# A conservative 12-bit unsigned range: exactly legal for add/sub/cmp
		# immediates, and a legal subset of movz/movk/svc/brk's wider fields.
		op.imm = fuzz_range(4096)
		return
	if (op.kind == ASM_OP_MEM()):
		if (op.disp_size == ARM64_ADDR_PCREL()):
			# Literal-pool / pc-relative load: address-derived, leave it be.
			return
		if (op.base >= 0):
			op.base = fuzz_range(31)
		if (op.disp_size == ARM64_ADDR_REG()):
			if (op.index >= 0):
				op.index = fuzz_range(31)
			return
		int width = op.size
		if (width != 4 & width != 8):
			width = 8
		op.disp = fuzz_range(32) * width


void asm_fuzz_arm64_mutate_insn(asm_insn* insn):
	asm_fuzz_arm64_mutate_operand(&insn.op1)
	asm_fuzz_arm64_mutate_operand(&insn.op2)
	asm_fuzz_arm64_mutate_operand(&insn.op3)


void asm_fuzz_arm64_report(char* what, int seed, int iter, int line, char* text, char* want, char* got):
	print2(c"asm fuzz mismatch (")
	print2(what)
	print2(c") seed=")
	print2(itoa(seed))
	print2(c" iter=")
	print2(itoa(iter))
	print2(c" corpus_line=")
	println2(itoa(line))
	print2(c"  form: ")
	println2(text)
	print2(c"  want: ")
	println2(want)
	print2(c"  got:  ")
	println2(got)


void test_arm64_fuzz_corpus():
	list[asm_corpus_entry] entries = asm_corpus_load(c"tests/asm/corpus_arm64.txt")
	asserts(c"empty arm64 corpus", entries.length > 100)
	int seed = ASM_FUZZ_SEED()
	fuzz_seed(seed)
	int iterations = asm_fuzz_iterations()
	int checked = 0
	int i = 0
	while (i < iterations):
		int idx = fuzz_range(entries.length)
		asm_corpus_entry entry = entries[idx]
		asm_insn insn
		int ok = asm_arm64_parse(entry.text, &insn)
		if (ok == 0):
			i = i + 1
			continue
		asm_fuzz_arm64_mutate_insn(&insn)

		# Property 1: decode(encode(insn)) == insn.
		asm_buffer* b1 = asm_buffer_new()
		asm_arm64_encode(b1, &insn)
		asm_insn insn2
		asm_arm64_decode(b1.data, b1.length, 0, &insn2)
		asm_buffer* b2 = asm_buffer_new()
		asm_arm64_encode(b2, &insn2)
		if (b1.length != 4 | b2.length != 4 | asm_fuzz_bytes4_equal(b1.data, b2.data) == 0):
			print2(c"asm fuzz mismatch (arm64) seed=")
			print2(itoa(seed))
			print2(c" iter=")
			print2(itoa(i))
			print2(c" corpus_line=")
			println2(itoa(entry.line))
			print2(c"  form: ")
			println2(entry.text)
			print2(c"  want: ")
			println2(asm_hex_encode(b1.data, b1.length))
			print2(c"  got:  ")
			println2(asm_hex_encode(b2.data, b2.length))
			exit(1)
		char* f1 = asm_arm64_format(&insn)
		char* f2 = asm_arm64_format(&insn2)
		if (strcmp(f1, f2) != 0):
			asm_fuzz_arm64_report(c"arm64 decode(encode)", seed, i, entry.line, entry.text, f1, f2)
			exit(1)
		asm_buffer_free(b1)
		asm_buffer_free(b2)

		# Property 2: parse(format(insn)) == insn.
		asm_insn insn3
		asm_arm64_parse(f1, &insn3)
		char* f3 = asm_arm64_format(&insn3)
		if (strcmp(f1, f3) != 0):
			asm_fuzz_arm64_report(c"arm64 parse(format)", seed, i, entry.line, entry.text, f1, f3)
			exit(1)

		checked = checked + 1
		i = i + 1
	print2(c"arm64 fuzz: seed=")
	print2(itoa(seed))
	print2(c" iterations=")
	print2(itoa(iterations))
	print2(c" checked=")
	println2(itoa(checked))


############################ opaque-form raw round trip #######################

# madd/msub live in the "data-processing (3 source)" encoding class
# ((w & 0x1f000000) == 0x1b000000, libs/asm/arm64_decode.w's
# arm64_dec_dp3): op31 (bits 21-23) must be 0 and Ra (bits 10-14) != 31,
# else the same bit shape decodes to mul (Ra==31) or smulh (op31!=0)
# instead. o0 (bit 15) selects madd (0) vs msub (1); sf (bit 31) selects
# the 32-/64-bit register width. None of this needs validating bit-by-bit
# here: arm64_decode.w's own dispatch (asm_arm64_decode) is what actually
# classifies the constructed word, and the test below asserts it lands on
# the expected mnemonic before checking the round trip.
int asm_fuzz_arm64_build_dp3(int sf, int rm, int o0, int ra, int rn, int rd):
	return (sf << 31) | 0x1b000000 | (rm << 16) | (o0 << 15) | (ra << 10) | (rn << 5) | rd


# Scalar floating point: (w & 0x5f000000) == 0x1e000000; the decoder
# classifies any word matching that top-byte pattern as opaque "fp"
# regardless of the remaining 24 bits (arm64_decode.w line ~905), so
# those bits can be fully random.
int asm_fuzz_arm64_build_fp(int low24):
	return 0x1e000000 | low24


# madd/msub decode with a real mnemonic and rd/rn/rm modeled, but the
# accumulator (Ra) is not represented in the operands — only in
# insn.raw — and libs/asm/arm64_encode.w has no "madd"/"msub" case, so
# encode always falls back to reproducing insn.raw. That fallback is
# exactly what makes the *decode(encode(x))* byte round trip hold for
# these words; format(insn) renders rd/rn/rm from the modeled fields, but
# re-parsing that text cannot recover Ra, so *parse(format(x))* is not a
# meaningful check here (matching the design doc: "these opaque forms...
# modeling their operands... is a follow-up"). Scalar-FP words carry no
# modeled operands at all (bare mnemonic), so the same reasoning applies.
# This is the harness's documented skip for the two recognized-but-opaque
# arm64 families named in issue #171; both are asserted to at least
# survive the raw (decode->encode byte-identity) round trip.
void test_arm64_opaque_raw_roundtrip():
	int seed = ASM_FUZZ_SEED() + 1
	fuzz_seed(seed)
	int n = 500
	int madd_count = 0
	int msub_count = 0
	int fp_count = 0
	int i = 0
	while (i < n):
		int which = fuzz_range(3)
		int w = 0
		char* want_mnemonic = c"fp"
		if (which == 0 | which == 1):
			int sf = fuzz_range(2)
			int rm = fuzz_range(32)
			int ra = fuzz_range(31)   # 0..30: never 31, which would decode as mul.
			int rn = fuzz_range(32)
			int rd = fuzz_range(32)
			w = asm_fuzz_arm64_build_dp3(sf, rm, which, ra, rn, rd)
			if (which == 0):
				want_mnemonic = c"madd"
			else:
				want_mnemonic = c"msub"
		else:
			int low24 = fuzz_next() & ((1 << 24) - 1)
			w = asm_fuzz_arm64_build_fp(low24)
		asm_buffer* wb = asm_buffer_new()
		asm_buffer_int32(wb, w)

		asm_insn insn
		asm_arm64_decode(wb.data, 4, 0, &insn)
		if (strcmp(insn.mnemonic, want_mnemonic) != 0):
			print2(c"asm fuzz: opaque-form template misclassified: seed=")
			print2(itoa(seed))
			print2(c" iter=")
			print2(itoa(i))
			print2(c" want_mnemonic=")
			print2(want_mnemonic)
			print2(c" got_mnemonic=")
			print2(insn.mnemonic)
			print2(c" word=")
			println2(asm_hex_encode(wb.data, 4))
			exit(1)

		asm_buffer* eb = asm_buffer_new()
		asm_arm64_encode(eb, &insn)
		if (eb.length != 4 | asm_fuzz_bytes4_equal(eb.data, wb.data) == 0):
			print2(c"asm fuzz: opaque-form raw round trip failed: seed=")
			print2(itoa(seed))
			print2(c" iter=")
			print2(itoa(i))
			print2(c" mnemonic=")
			print2(insn.mnemonic)
			print2(c" want=")
			print2(asm_hex_encode(wb.data, 4))
			print2(c" got=")
			println2(asm_hex_encode(eb.data, eb.length))
			exit(1)

		if (which == 0):
			madd_count = madd_count + 1
		else if (which == 1):
			msub_count = msub_count + 1
		else:
			fp_count = fp_count + 1
		asm_buffer_free(wb)
		asm_buffer_free(eb)
		i = i + 1
	print2(c"arm64 opaque-form raw round trip: madd=")
	print2(itoa(madd_count))
	print2(c" msub=")
	print2(itoa(msub_count))
	print2(c" fp=")
	println2(itoa(fp_count))


int main():
	test_arm64_fuzz_corpus()
	test_arm64_opaque_raw_roundtrip()
	println(c"asm_fuzz_arm64_test passed")
	return 0
