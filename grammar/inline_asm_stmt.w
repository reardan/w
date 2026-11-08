/*
Native inline assembly statement (docs/projects/native_inline_asm.md).

A statement that emits a short run of machine instructions INLINE in the
surrounding function -- no outlined helper, no external assembler -- and
binds W values to the instruction operands through physical registers.
It is the statement counterpart to the whole-function `asm <isa>:` blocks
(grammar/asm_function.w), for machine-level code a C translator or a
freestanding kernel must express directly (CPUID, the timestamp counter,
lock-prefixed read-modify-writes, flag-producing bit operations).

Shape (x86-64; the template lines are AT&T/GNU syntax):

	asm_native:
		input rax = <value-expr>     # load the value into rax before
		inout rbx:8 = <address-expr>  # load *addr into rbx, store back after
		output rcx:4 = <address-expr> # store rcx into *addr (4 bytes) after
		flagout c:1 = <address-expr>  # set*cc into *addr after the template
		clobber rdx                   # consumed by the producer, ignored here
		"cpuid"
		"movq %rbx, %rsi"

The operands are already assigned to physical registers by the producer
(a constraint allocator), so W does no register allocation: it evaluates
each input value / output address, stages it on the stack, loads the named
registers, emits the assembled template, and stores the outputs back. The
statement is a register hazard (like raw_asm, grammar/regalloc_scan.w),
so W holds no value in a general register across it; r10 and r11 are
reserved as the statement's own scratch (flag capture and address
register), and rsp/rbp are off limits to operands.

This first form handles straight-line templates (no local labels,
branches, directives or external calls -- those are a follow-on). A
template line the encoder cannot assemble is a compile error, so a
producer only emits templates it has checked are supported.

This file is in w.w's import graph, so it is compiled by the pinned seed
and must stay seed-syntax-safe. The new STATEMENT SYNTAX must not appear
in any seed-compiled source; parsing it here is ordinary W.
*/
import libs.asm.att
import libs.asm.registers
import libs.asm.insn
import libs.asm.x86_encode


int expression();
int promote(int type);
void emit(int n, char* s);
int push_slot();
void error(char* s);
int process_string_literal();
int process_prefixed_string_literal();


# Local string helpers (no 3/4-argument strjoin in lib/lib.w).
char* inasm_join3(char* a, char* b, char* c):
	return strjoin(strjoin(a, b), c)

char* inasm_join4(char* a, char* b, char* c, char* d):
	return strjoin(strjoin(a, b), strjoin(c, d))


# Operand kinds.
const int INASM_IN = 0
const int INASM_IO = 1
const int INASM_OUT = 2
const int INASM_FLAG = 3

# Reserved scratch registers (x64 numbers): r11 = address register,
# r10 = flag capture. 4 = rsp, 5 = rbp are the frame registers.
const int INASM_R11 = 11
const int INASM_R10 = 10


# Per-statement collected operands (parallel lists) and template lines.
list[int] inasm_kind
list[int] inasm_reg       # register number, or -1 for a flag (cc in inasm_cc)
list[int] inasm_width     # store/load width in bytes
list[int] inasm_slot      # stack slot holding the value (in) or address (io/out/flag)
list[char*] inasm_cc      # condition-code suffix for a flag operand
list[char*] inasm_lines   # template instruction texts, in order
int inasm_ready


void inasm_reset():
	inasm_kind = new list[int]
	inasm_reg = new list[int]
	inasm_width = new list[int]
	inasm_slot = new list[int]
	inasm_cc = new list[char*]
	inasm_lines = new list[char*]
	inasm_ready = 1


# An operand register name the producer wrote (e.g. "rax", "r9") -> its
# x64 register number, or -1 when it is not a 64-bit general register or
# is one of the reserved frame/scratch registers.
int inasm_reg_number(char* name):
	int enc = asm_reg_lookup_x86(name)
	if (enc < 0): return 0 - 1
	if (asm_reg_size(enc) != 8): return 0 - 1
	int n = asm_reg_number(enc)
	if (n == 4 || n == 5): return 0 - 1
	if (n == INASM_R10 || n == INASM_R11): return 0 - 1
	return n


# "%" + the register name of number n at byte width w.
char* inasm_reg_operand(int n, int w):
	return strjoin(c"%", asm_reg_name(ASM_ARCH_X64, n, w))


# Assemble one AT&T x64 line and emit its bytes inline at codepos. A line
# the front end cannot parse or the encoder cannot build is a compile
# error (the producer emits only supported templates).
void inasm_emit_line(char* line):
	asm_insn insn
	if (asm_att_parse(line, ASM_ARCH_X64, &insn) == 0):
		error(strjoin(c"native inline asm cannot assemble: ", line))
	asm_buffer* b = asm_buffer_new()
	int n = asm_x86_encode(b, &insn)
	if (n <= 0):
		error(strjoin(c"native inline asm cannot assemble: ", line))
	emit(n, b.data)


# The rsp-relative displacement of a stack slot, as the load/store glue
# names it ("<disp>(%rsp)"); stack_pos must not change between the
# operand pushes and this point.
int inasm_slot_disp(int slot):
	return (stack_pos - slot) << word_size_log2


# Emit a width-sized load from (%r11) into register n: a smaller width
# zero-extends into the 32-bit register (clearing the upper 32 bits).
void inasm_load_through_r11(int n, int w):
	char* src = c"(%r11)"
	if (w == 8): inasm_emit_line(inasm_join4(c"movq ", src, c", ", inasm_reg_operand(n, 8)))
	else if (w == 4): inasm_emit_line(inasm_join4(c"movl ", src, c", ", inasm_reg_operand(n, 4)))
	else if (w == 2): inasm_emit_line(inasm_join4(c"movzwl ", src, c", ", inasm_reg_operand(n, 4)))
	else: inasm_emit_line(inasm_join4(c"movzbl ", src, c", ", inasm_reg_operand(n, 4)))


# Emit a width-sized store of register n to (%r11).
void inasm_store_through_r11(int n, int w):
	char* dst = c", (%r11)"
	if (w == 8): inasm_emit_line(inasm_join4(c"movq ", inasm_reg_operand(n, 8), dst, c""))
	else if (w == 4): inasm_emit_line(inasm_join4(c"movl ", inasm_reg_operand(n, 4), dst, c""))
	else if (w == 2): inasm_emit_line(inasm_join4(c"movw ", inasm_reg_operand(n, 2), dst, c""))
	else: inasm_emit_line(inasm_join4(c"movb ", inasm_reg_operand(n, 1), dst, c""))


# Load the slot holding an address into r11: "movq <disp>(%rsp), %r11".
void inasm_load_address(int slot):
	char* mem = inasm_join3(itoa(inasm_slot_disp(slot)), c"(%rsp), ", c"%r11")
	inasm_emit_line(strjoin(c"movq ", mem))


# Read a register-name token (advancing past it); returns its number, or
# errors. Used for operand and clobber registers.
int inasm_parse_reg():
	int n = inasm_reg_number(token)
	if (n < 0): error(strjoin(c"native inline asm: bad operand register '", strjoin(strclone(token), c"'")))
	get_token()
	return n


# Read a ":<width>" after an operand register (1/2/4/8); default 8.
int inasm_parse_width():
	if (peek(c":") == 0): return 8
	get_token()
	int w = atoi(token)
	if (w != 1 && w != 2 && w != 4 && w != 8): error(c"native inline asm: operand width must be 1, 2, 4 or 8")
	get_token()
	return w


# Record an operand whose value/address is in eax: push it as a slot.
void inasm_push_operand(int kind, int reg, int width, char* cc):
	int slot = push_slot()
	inasm_kind.push(kind)
	inasm_reg.push(reg)
	inasm_width.push(width)
	inasm_slot.push(slot)
	inasm_cc.push(cc)


# Parse the block body (lines indented past body_level) into the operand
# and template lists, evaluating each input value / output address as it
# is seen and pushing it as a slot.
void inasm_parse_body(int body_level):
	while ((token[0] != 0) && ((token_newline == 0) || (tab_level > body_level))):
		if ((token[0] == '"') || ((token[0] == 'c') && (token[1] == '"'))):
			int length
			if (token[0] == 'c'): length = process_prefixed_string_literal()
			else: length = process_string_literal()
			token[length] = 0
			inasm_lines.push(strclone(token))
			get_token()
		else if (peek(c"input")):
			get_token()
			int reg = inasm_parse_reg()
			expect(c"=")
			promote(expression())
			inasm_push_operand(INASM_IN, reg, 8, c"")
		else if (peek(c"inout")):
			get_token()
			int reg = inasm_parse_reg()
			int w = inasm_parse_width()
			expect(c"=")
			promote(expression())
			inasm_push_operand(INASM_IO, reg, w, c"")
		else if (peek(c"output")):
			get_token()
			int reg = inasm_parse_reg()
			int w = inasm_parse_width()
			expect(c"=")
			promote(expression())
			inasm_push_operand(INASM_OUT, reg, w, c"")
		else if (peek(c"flagout")):
			get_token()
			char* cc = strclone(token)
			get_token()
			int w = inasm_parse_width()
			expect(c"=")
			promote(expression())
			inasm_push_operand(INASM_FLAG, 0 - 1, w, cc)
		else if (peek(c"clobber")):
			# The producer's constraint allocator owns register
			# assignment; W keeps nothing live in a general register
			# across the hazard, so the clobber list is informational.
			get_token()
			get_token()
		else:
			error(strjoin(c"native inline asm: unexpected '", strjoin(strclone(token), c"'")))


# Emit the whole statement: load the input and io registers, the template
# lines, the flag captures and the output stores, then drop the slots.
void inasm_emit():
	# Glue-in: input values and io loads.
	for i in range(inasm_kind.length):
		int kind = inasm_kind[i]
		if (kind == INASM_IN):
			char* mem = inasm_join3(itoa(inasm_slot_disp(inasm_slot[i])), c"(%rsp), ", inasm_reg_operand(inasm_reg[i], 8))
			inasm_emit_line(strjoin(c"movq ", mem))
		else if (kind == INASM_IO):
			inasm_load_address(inasm_slot[i])
			inasm_load_through_r11(inasm_reg[i], inasm_width[i])

	# The template, in source order.
	for i in range(inasm_lines.length): inasm_emit_line(inasm_lines[i])

	# Flag captures, while the template's flags are still live: set*cc into
	# r10b, then zero-extend to the full register so the output store
	# writes a clean 0/1 across the lvalue's width (not just its low byte).
	for i in range(inasm_kind.length):
		if (inasm_kind[i] == INASM_FLAG):
			inasm_emit_line(inasm_join3(c"set", inasm_cc[i], c" %r10b"))
			inasm_emit_line(c"movzbl %r10b, %r10d")

	# Glue-out: store every output / io register and flag capture.
	for i in range(inasm_kind.length):
		int kind = inasm_kind[i]
		if (kind == INASM_OUT || kind == INASM_IO):
			inasm_load_address(inasm_slot[i])
			inasm_store_through_r11(inasm_reg[i], inasm_width[i])
		else if (kind == INASM_FLAG):
			inasm_load_address(inasm_slot[i])
			inasm_store_through_r11(INASM_R10, inasm_width[i])

	# Drop the staged slots.
	int n = inasm_kind.length
	if (n > 0):
		be_pop(n)
		stack_pos = stack_pos - n


# The statement: 'asm_native' and ':' have not yet been consumed. Returns
# 1 when it parsed the statement (caller treats it as a hazard), 0 when
# the next token is not a native inline asm statement.
int inline_asm_statement():
	if (peek(c"asm_native") == 0): return 0
	if (nextc != ':'): return 0
	if (sym_lookup(c"asm_native") >= 0): return 0
	script_profile_reject(c"script profile: inline asm is not allowed")
	get_token()        # 'asm_native'
	int body_level = tab_level
	get_token()        # ':'
	if ((token_newline == 0) || (tab_level <= body_level)):
		error(c"native inline asm block needs indented lines after ':'")
	inasm_reset()
	inasm_parse_body(body_level)
	# One flag output at most: they share the r10 capture register, so two
	# would clobber each other (rare; the producer falls back otherwise).
	int flags = 0
	for i in range(inasm_kind.length):
		if (inasm_kind[i] == INASM_FLAG): flags = flags + 1
	if (flags > 1): error(c"native inline asm supports at most one flag output")
	inasm_emit()
	return 1
