/*
Disassembly for wdbg (issue #169): the 'disas' command and the automatic
instruction context shown at stops.

Decoding and formatting come from libs/asm: asm_x86_decode covers both
the 32-bit and the 64-bit debugger build through its mode parameter
(mirroring how the x64 codegen reuses code_generator/x86.w), and
asm_format renders the canonical Intel text the corpus tests pin down.

Bytes are fetched through a per-mode reader function so the same code
serves both execution models: the in-process debugger registers
dbg_disas_read_local (direct reads, probed with mincore so a bad address
cannot fault wdbg), attach mode registers at_disas_read (PTRACE_PEEKDATA).
Both readers substitute an armed breakpoint's remembered original byte
for its int3 patch, so disassembly always shows the real instruction.

x86 cannot be decoded backwards, so the "context" display finds the
instructions before the stop by walking forward from the enclosing
function's entry (debugger/symbols.w) and requiring the walk to land
exactly on the stop address; when it does not (data in the code stream,
unknown function) the context simply starts at the stop.

This file sits in w.w's seed-compiled import graph (w --debug), like the
rest of debugger/ and libs/asm: only seed-understood syntax here.
*/
import debugger.memory
import debugger.symbols
import debugger.breakpoints
import libs.asm.x86_decode
import libs.asm.format


int dbg_disas_read_fn /* byte reader: int f(int addr) -> 0..255, -1 unreadable */
int dbg_disas_delta   /* target address - symbol-table address (attach mode) */
int dbg_disas_symbols /* 1 when the symbol/line tables describe the target */
int dbg_disas_auto    /* 1: show instruction context at every stop */
char* dbg_disas_buf   /* scratch bytes for one instruction */


# In-process byte reader: direct memory access, probed with mincore so a
# bad address cannot fault wdbg, with any armed breakpoint's remembered
# original byte substituted for its int3 patch.
int dbg_disas_read_local(int addr):
	if (dbg_mem_readable(addr, 1) == 0):
		return -1
	int bp = bp_find(addr)
	if (bp >= 0):
		if (load_int(bp_armeds + bp * 4)):
			return load_int(bp_bytes + bp * 4)
	return bp_read_byte(addr)


# Read one byte at addr through the registered reader (0..255, or -1 when
# unreadable). Exposed for callers outside this file that want the same
# breakpoint-substituted byte access disassembly uses -- debugger/attach.w's
# frame-walk call-site heuristic (#123 phase 5) reads through this instead
# of a direct memory access, so it works against a ptrace-attached target.
int dbg_disas_read_byte(int addr):
	int* rd = cast(int*, dbg_disas_read_fn)
	return rd(addr)


# Read up to n bytes at addr through the registered reader; returns how
# many were readable.
int dbg_disas_fetch(int addr, char* buf, int n):
	int* rd = cast(int*, dbg_disas_read_fn)
	int i = 0
	while (i < n):
		int v = rd(addr + i)
		if (v < 0):
			return i
		buf[i] = v
		i = i + 1
	return i


# Decode the instruction at an absolute address; returns its length, or
# 0 when the memory there is not readable. 16 bytes covers the longest
# x86 instruction (15) with room for the truncated-tail case.
int dbg_disas_decode(int addr, asm_insn* insn):
	if (dbg_disas_buf == 0):
		dbg_disas_buf = malloc(16)
	int n = dbg_disas_fetch(addr, dbg_disas_buf, 16)
	if (n == 0):
		return 0
	return asm_x86_decode(dbg_disas_buf, n, addr, __word_size__, insn)


# Print " <name>" or " <name+off>" when an absolute address lands inside
# a known function; prints nothing otherwise.
void dbg_disas_annotate(int addr):
	if (dbg_disas_symbols == 0):
		return;
	int f = dbg_function_at(addr - dbg_disas_delta)
	if (f < 0):
		return;
	print(c" <")
	print(dbg_sym_name(f))
	int off = (addr - dbg_disas_delta) - dbg_sym_address(f)
	if (off != 0):
		print(c"+")
		char* digits = itoa(off)
		print(digits)
		free(digits)
	print(c">")


# 1 when the operand is an immediate holding exactly a known function's
# entry address. The compiler calls through 'mov eax,fn ; call eax', so
# this is what makes call sites readable in the listing.
int dbg_disas_imm_function(asm_operand* op):
	if (op.kind != ASM_OP_IMM()):
		return 0
	if (dbg_disas_symbols == 0):
		return 0
	if (op.imm_hi != 0):
		return 0
	int f = dbg_function_at(op.imm - dbg_disas_delta)
	if (f < 0):
		return 0
	return (op.imm - dbg_disas_delta) == dbg_sym_address(f)


# One listing line: "   0xADDR  text", with "=>" marking the current
# instruction and a <function> annotation for branch targets and for
# immediates holding a function's entry address.
void dbg_disas_print(int addr, asm_insn* insn, int current):
	if (current):
		print(c"=> ")
	else:
		print(c"   ")
	char* h = hex_word(addr)
	print(h)
	free(h)
	print(c"  ")
	char* text = asm_format(insn)
	print(text)
	free(text)
	if (insn.branch_target != -1):
		dbg_disas_annotate(insn.branch_target)
	else if (dbg_disas_imm_function(&insn.op2)):
		dbg_disas_annotate(insn.op2.imm)
	else if (dbg_disas_imm_function(&insn.op1)):
		dbg_disas_annotate(insn.op1.imm)
	put_char(10)


# Start address for the context display: up to two instruction starts
# before pc, found by walking forward from the enclosing function's
# entry. Falls back to pc itself when the walk cannot land exactly on it.
int dbg_disas_context_start(int pc):
	if (dbg_disas_symbols == 0):
		return pc
	int f = dbg_function_at(pc - dbg_disas_delta)
	if (f < 0):
		return pc
	int a = dbg_sym_address(f) + dbg_disas_delta
	int prev1 = -1
	int prev2 = -1
	asm_insn insn
	while (a < pc):
		int len = dbg_disas_decode(a, &insn)
		if (len <= 0):
			return pc
		prev2 = prev1
		prev1 = a
		a = a + len
	if (a != pc):
		return pc
	if (prev2 != -1):
		return prev2
	if (prev1 != -1):
		return prev1
	return pc


# The automatic stop display: the current instruction with up to two
# before and two after it, "=>" on the current one. Shown at every 'si'
# stop and, after 'disas on', at every other stop as well.
void dbg_disas_show_context(int pc):
	if (dbg_disas_read_fn == 0):
		return;
	int a = dbg_disas_context_start(pc)
	int after = 0
	asm_insn insn
	while (after < 3):
		int len = dbg_disas_decode(a, &insn)
		if (len <= 0):
			return;
		dbg_disas_print(a, &insn, a == pc)
		if (a >= pc):
			after = after + 1
		a = a + len


# Terminate the first word of s and return the rest (spaces skipped).
# Local copy: this file is shared by wdbg.w and attach.w, which each
# keep their own splitter for the same layering reason.
char* dbg_disas_split(char* s):
	int i = 0
	while ((s[i] != 0) && (s[i] != ' ')):
		i = i + 1
	if (s[i] == 0):
		return s + i
	s[i] = 0
	i = i + 1
	while (s[i] == ' '):
		i = i + 1
	return s + i


int dbg_disas_number(char* s):
	if (starts_with(s, c"0x")):
		return from_hex(s)
	return atoi(s)


# disas [addr | function] [count]
#   no argument: the function enclosing pc (or 10 instructions from pc
#   when it is unknown), with "=>" on the current instruction
#   function:    the whole function (or count instructions when given)
#   address:     count instructions (default 10) from the address
# disas on|off: toggle the automatic instruction context at every stop.
void dbg_disas_command(int pc, char* arg):
	if (dbg_disas_read_fn == 0):
		println(c"disassembly is not available here")
		return;
	char* count_text = dbg_disas_split(arg)
	if (strcmp(arg, c"on") == 0):
		dbg_disas_auto = 1
		println(c"instruction context at stops: on")
		return;
	if (strcmp(arg, c"off") == 0):
		dbg_disas_auto = 0
		println(c"instruction context at stops: off")
		return;
	int count = 0 /* 0 = default for the target form */
	if (count_text[0] != 0):
		count = dbg_disas_number(count_text)
		if (count < 1):
			count = 1
		if (count > 1024):
			count = 1024
	int start = pc
	int end = -1 /* function-boundary bound, when one is known */
	if (arg[0] == 0):
		if (dbg_disas_symbols):
			int f = dbg_function_at(pc - dbg_disas_delta)
			if (f >= 0):
				start = dbg_sym_address(f) + dbg_disas_delta
				if (dbg_sym_size(f) > 0):
					end = start + dbg_sym_size(f)
				print(dbg_sym_name(f))
				println(c":")
	else if (((arg[0] >= '0') && (arg[0] <= '9')) || (arg[0] == '-')):
		start = dbg_disas_number(arg)
	else:
		if (dbg_disas_symbols == 0):
			println(c"no symbols: disassemble by address (disas 0xADDR)")
			return;
		int f = dbg_global_find(arg)
		if (f < 0):
			print(c"unknown function: ")
			println(arg)
			dbg_suggest_functions(arg)
			return;
		if (dbg_sym_symtype(f) != 2):
			print(c"not a function: ")
			println(arg)
			return;
		start = dbg_sym_address(f) + dbg_disas_delta
		if (dbg_sym_size(f) > 0):
			end = start + dbg_sym_size(f)
		print(dbg_sym_name(f))
		println(c":")
	if (count > 0):
		end = -1 /* an explicit count wins over the function boundary */
	else if (end != -1):
		count = 1024 /* bounded by the function's end; cap the walk */
	else:
		count = 10
	asm_insn insn
	int a = start
	int printed = 0
	while (printed < count):
		if (end != -1):
			if (a >= end):
				return;
		int len = dbg_disas_decode(a, &insn)
		if (len <= 0):
			print(c"cannot read memory at ")
			char* h = hex_word(a)
			println(h)
			free(h)
			return;
		dbg_disas_print(a, &insn, a == pc)
		a = a + len
		printed = printed + 1
