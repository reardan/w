# wbuild: target=regalloc_arm64_structure_test tag=tests dep=wv2 input=libs/asm/ input=tests/regalloc_arm64_test.w input=tests/regalloc_arm64_structure_test.w
# wbuild: step="bin/wv2 arm64 tests/regalloc_arm64_test.w -o bin/regalloc_arm64_structure_regs"
# wbuild: step="bin/wv2 arm64 --no-regs tests/regalloc_arm64_test.w -o bin/regalloc_arm64_structure_noregs"
# wbuild: step="bin/wv2 arm64 --streaming tests/regalloc_arm64_test.w -o bin/regalloc_arm64_structure_streaming"
# wbuild: step="bin/wv2 arm64 -O0 tests/regalloc_arm64_test.w -o bin/regalloc_arm64_structure_o0"
# wbuild: step="bin/wv2 arm64_darwin tests/regalloc_arm64_test.w -o bin/regalloc_arm64_structure_darwin"
# wbuild: step="bin/wv2 arm64_darwin --no-regs tests/regalloc_arm64_test.w -o bin/regalloc_arm64_structure_darwin_noregs"
# wbuild: step="bin/wv2 tests/regalloc_arm64_structure_test.w -o bin/regalloc_arm64_structure_test"
# wbuild: step="bin/regalloc_arm64_structure_test" expect_stdout="regalloc_arm64_structure_test passed"
/*
Structural test for register promotion on arm64 Linux (issue #801;
compiler/regalloc_scan.w, code_generator/arm64.w). The target
cross-compiles tests/regalloc_arm64_test.w for arm64 with promotion on
(the default), with --no-regs, with -O0, with the streaming front end,
and for arm64_darwin with and without --no-regs, then this x86 program
decodes the functions it names with libs/asm and asserts, without
executing anything:
 - sum_to keeps its counter, accumulator and bound in x19-x21: the
   prologue saves exactly those three, and the loop is four
   register-only instructions with no load or store;
 - pressure saves the whole budget (x19-x23), and no function of the
   program touches x24-x27;
 - every promoted function restores its first saved pair at each 'ret'
   (all exits restore), and declined shapes (a setjmp caller, raw_asm,
   an f-string, a variadic, a generator) save nothing;
 - --no-regs and -O0 save no callee-saved register in any of those
   functions, and their loops load the counter from the frame;
 - the streaming front end promotes the same locals as the AST one
   (identical save sets);
 - arm64_darwin is not admitted: its output is byte-identical with and
   without --no-regs.
*/
import lib.lib
import lib.assert
import libs.asm.insn
import libs.asm.binary_reader
import libs.asm.arm64_decode
import libs.asm.arm64_format


struct decoded:
	list[char*] text
	list[int] address
	list[int] target


# The instructions of the named function, formatted.
decoded* function_code(asm_binary* binary, char* name):
	int index = asm_binary_symbol_named(binary, name)
	if (index < 0):
		print(c"missing function ")
		println(name)
		exit(1)
	asm_symbol symbol = binary.symbols[index]
	asserts(c"function has a size", symbol.size > 0)
	decoded* result = new decoded
	result.text = new list[char*]
	result.address = new list[int]
	result.target = new list[int]
	char* base = binary.data + binary.text_offset + (symbol.value - binary.text_vaddr)
	int pos = 0
	while (pos + 4 <= symbol.size):
		asm_insn instruction
		asm_arm64_decode(&base[pos], 4, symbol.value + pos, &instruction)
		result.text.push(asm_arm64_format(&instruction))
		result.address.push(symbol.value + pos)
		result.target.push(instruction.branch_target)
		pos = pos + 4
	return result


int has_prefix(char* text, char* prefix):
	int i = 0
	while (prefix[i] != 0):
		if (text[i] != prefix[i]): return 0
		i = i + 1
	return 1


int contains(char* text, char* needle):
	int i = 0
	while (text[i] != 0):
		if (has_prefix(&text[i], needle)): return 1
		i = i + 1
	return 0


# Whether text names register reg ("x19") as a whole operand.
int mentions(char* text, char* reg):
	int n = strlen(reg)
	int i = 0
	while (text[i] != 0):
		if (has_prefix(&text[i], reg)):
			int before = 0
			if (i > 0): before = text[i - 1]
			int after = text[i + n]
			int boundary_before = (before == 0) || (before == ' ') || (before == ',') || (before == '[')
			int boundary_after = (after == 0) || (after == ',') || (after == ']')
			if (boundary_before && boundary_after): return 1
		i = i + 1
	return 0


char* reg_name(int r):
	char* name = cast(char*, malloc(4))
	name[0] = 'x'
	name[1] = '0' + r / 10
	name[2] = '0' + r % 10
	name[3] = 0
	return name


# The callee-saved registers the prologue pushes onto the W stack
# (stp/str xN, ..., [x28, #-k]!) as a bit mask over x19..x27.
int saved_mask(decoded* code):
	int mask = 0
	for i in range(code.text.length):
		char* t = code.text[i]
		int store = has_prefix(t, c"stp x") || has_prefix(t, c"str x")
		if (store == 0): continue
		if (contains(t, c"[x28,#-") == 0): continue
		for r in range(19, 28):
			char* name = reg_name(r)
			if (mentions(t, name)): mask = mask | (1 << (r - 19))
	return mask


int count_bits(int mask):
	int n = 0
	while (mask != 0):
		n = n + (mask & 1)
		mask = mask >> 1
	return n


int count_prefix(decoded* code, char* prefix):
	int n = 0
	for i in range(code.text.length):
		if (has_prefix(code.text[i], prefix)): n = n + 1
	return n


# A promoted function restores its registers on every exit: as many
# reloads of the first saved register from the frame as 'ret's.
void check_restores(char* name, decoded* code):
	int rets = count_prefix(code, c"ret")
	int restores = count_prefix(code, c"ldp x19,") + count_prefix(code, c"ldr x19,[x29")
	if (rets != restores):
		print(name)
		print_int0(c": rets ", rets)
		print_int0(c" restores ", restores)
		println(c"")
	assert_equal(rets, restores)
	asserts(c"promoted function returns", rets > 0)


# The last backward branch's loop body: [start, branch].
int loop_start(decoded* code, int* branch_out):
	for k in range(code.text.length):
		int i = code.text.length - 1 - k
		if ((has_prefix(code.text[i], c"b.") == 0) && (has_prefix(code.text[i], c"b ") == 0)): continue
		int target = code.target[i]
		if ((target >= 0) && (target < code.address[i])):
			*branch_out = i
			for j in range(code.text.length):
				if (code.address[j] == target): return j
	return -1


int is_memory(char* t):
	return has_prefix(t, c"ld") || has_prefix(t, c"st")


void check_sum_loop_registers(decoded* code):
	int branch = -1
	int start = loop_start(code, &branch)
	asserts(c"sum_to has a loop", start >= 0)
	assert_equal(4, branch - start + 1)
	for i in range(start, branch + 1):
		asserts(c"sum_to loop body uses no memory", is_memory(code.text[i]) == 0)
	asserts(c"loop compares the counter with the bound", strcmp(code.text[branch - 1], c"cmp x19,x21") == 0)


void check_sum_loop_frame(decoded* code):
	int branch = -1
	int start = loop_start(code, &branch)
	asserts(c"sum_to has a loop", start >= 0)
	int memory = 0
	for i in range(start, branch + 1):
		if (is_memory(code.text[i])): memory = memory + 1
	asserts(c"unpromoted loop reads the frame", memory >= 3)


# Functions the scan admits, with how many registers each saves.
int promoted_count(char* name):
	if (strcmp(name, c"sum_to") == 0): return 3
	if (strcmp(name, c"pressure") == 0): return 5
	if (strcmp(name, c"early_exit") == 0): return 4
	if (strcmp(name, c"consume_generator") == 0): return 5
	if (strcmp(name, c"operators") == 0): return 5
	return -1


char** promoted_names():
	char** names = cast(char**, malloc(20 * __word_size__))
	names[0] = c"sum_to"
	names[1] = c"pressure"
	names[2] = c"address_taken"
	names[3] = c"calls_in_loop"
	names[4] = c"tree"
	names[5] = c"early_exit"
	names[6] = c"early_caller"
	names[7] = c"jumper"
	names[8] = c"test_setjmp"
	names[9] = c"consume_generator"
	names[10] = c"busy"
	names[11] = c"with_defer"
	names[12] = c"fib_multi"
	names[13] = c"operators"
	names[14] = c"dot"
	names[15] = c"for_ranges"
	names[16] = c"with_goto"
	names[17] = 0
	return names


char** declined_names():
	char** names = cast(char**, malloc(8 * __word_size__))
	names[0] = c"with_setjmp"
	names[1] = c"with_raw_asm"
	names[2] = c"with_fstring"
	names[3] = c"variadic_sum"
	names[4] = c"gen_squares"
	names[5] = c"busy_task"
	names[6] = 0
	return names


asm_binary* open_binary(char* path):
	asm_binary* binary = asm_binary_open(path)
	if (cast(int, binary) == 0):
		print(c"cannot open ")
		println(path)
		exit(1)
	assert_equal(ASM_EM_AARCH64, binary.machine)
	return binary


void check_promoted(char* path, asm_binary* reference):
	asm_binary* binary = open_binary(path)
	char** names = promoted_names()
	int i = 0
	while (names[i] != 0):
		decoded* code = function_code(binary, names[i])
		int mask = saved_mask(code)
		asserts(c"promoted function saves x19", (mask & 1) != 0)
		assert_equal((1 << count_bits(mask)) - 1, mask)
		int expect = promoted_count(names[i])
		if (expect >= 0): assert_equal(expect, count_bits(mask))
		check_restores(names[i], code)
		for t in range(code.text.length):
			for r in range(24, 28):
				asserts(c"no function uses x24-x27", mentions(code.text[t], reg_name(r)) == 0)
		if (cast(int, reference) != 0):
			# the other front end admits the same locals
			assert_equal(saved_mask(function_code(reference, names[i])), mask)
		i = i + 1
	names = declined_names()
	i = 0
	while (names[i] != 0):
		assert_equal(0, saved_mask(function_code(binary, names[i])))
		i = i + 1
	check_sum_loop_registers(function_code(binary, c"sum_to"))
	println(path)


void check_unpromoted(char* path):
	asm_binary* binary = open_binary(path)
	char** names = promoted_names()
	int i = 0
	while (names[i] != 0):
		decoded* code = function_code(binary, names[i])
		assert_equal(0, saved_mask(code))
		i = i + 1
	decoded* sum = function_code(binary, c"sum_to")
	for t in range(sum.text.length):
		for r in range(19, 28):
			asserts(c"unpromoted sum_to uses no x19-x27", mentions(sum.text[t], reg_name(r)) == 0)
	check_sum_loop_frame(sum)
	println(path)


void check_same_bytes(char* a, char* b):
	int length_a = 0
	int length_b = 0
	char* data_a = asm_binary_read_file(a, &length_a)
	char* data_b = asm_binary_read_file(b, &length_b)
	asserts(c"darwin outputs readable", (cast(int, data_a) != 0) && (cast(int, data_b) != 0))
	assert_equal(length_a, length_b)
	for i in range(length_a):
		if (data_a[i] != data_b[i]):
			print_int0(c"darwin outputs differ at ", i)
			println(c"")
			exit(1)
	println(a)


int main():
	asserts(c"mentions matches whole registers", mentions(c"add x19,x19,#1", c"x19"))
	asserts(c"mentions skips longer names", mentions(c"mov x1,x190", c"x19") == 0)
	asserts(c"mentions sees memory bases", mentions(c"ldr x0,[x19]", c"x19"))
	asm_binary* regs = open_binary(c"bin/regalloc_arm64_structure_regs")
	check_promoted(c"bin/regalloc_arm64_structure_regs", 0)
	check_promoted(c"bin/regalloc_arm64_structure_streaming", regs)
	check_unpromoted(c"bin/regalloc_arm64_structure_noregs")
	check_unpromoted(c"bin/regalloc_arm64_structure_o0")
	check_same_bytes(c"bin/regalloc_arm64_structure_darwin", c"bin/regalloc_arm64_structure_darwin_noregs")
	println(c"regalloc_arm64_structure_test passed")
	return 0
