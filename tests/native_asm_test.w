# wbuild: deps=tests/native_asm/
# wbuild: deps=grammar/inline_asm_stmt.w
# Native inline assembly statements (grammar/inline_asm_stmt.w,
# docs/projects/native_inline_asm.md): compile tests/native_asm/ops.w to a
# freestanding --c-abi object with NO external assembler, link it with a
# gcc C driver that checks each statement against the same operation in C
# inline asm, and run it. A pass proves the inline native encoding and the
# input/output/flag operand binding are correct end to end.
import lib.testing
import tests.tool_e2e
import lib.file
import lib.str


char* native_dir


char* native_path(char* name):
	return path_join(native_dir, name)


# Run bin/wv2 with args, requiring status 0.
void native_wv2(char*... args):
	list[char*] argv = new list[char*]
	argv.push(c"wv2")
	for char* a in args: argv.push(a)
	process_result* r = tool_spawn(0, 60000, argv)
	if (r.status != 0): println2(r.stderr_text)
	assert_equal(0, r.status)
	process_result_free(r)


# A host command through the shell; returns its combined result.
process_result* native_shell(char* command):
	char** argv = strv_new(3)
	strv_set(argv, 0, c"/bin/sh")
	strv_set(argv, 1, c"-c")
	strv_set(argv, 2, command)
	process_result* r = process_run(c"/bin/sh", argv, 0, 0, 60000)
	assert1(r != 0)
	free(cast(void*, argv))
	return r


void test_native_asm_setup():
	native_dir = tool_scratch(c"native_asm_")
	assert_equal(0, mkdir(native_dir, 493))


# Compile the native-asm object (no assembler step), link it with the gcc
# driver and run the result: every check must pass.
void test_native_asm_vs_gcc():
	char* object = native_path(c"ops.o")
	native_wv2(c"x64", c"--emit=obj", c"--freestanding", c"--c-abi", c"tests/native_asm/ops.w", c"-o", object)

	char* binary = native_path(c"ops_bin")
	char* link_cmd = strjoin(strjoin(c"gcc -no-pie tests/native_asm/driver.c ", object), strjoin(c" -o ", binary))
	process_result* link = native_shell(link_cmd)
	if (link.status != 0):
		println2(link.stdout_text)
		println2(link.stderr_text)
	assert_equal(0, link.status)
	process_result_free(link)

	process_result* run = native_shell(binary)
	if (run.status != 0):
		println2(run.stdout_text)
		println2(run.stderr_text)
	assert_equal(0, run.status)
	assert_contains(run.stdout_text, c"all checks passed")
	process_result_free(run)


# Compile a one-function program whose asm_native template is lines
# (joined with newlines and tabbed into the block); the compile must fail
# with a message containing want. object selects --emit=obj.
void native_reject(int object, char* lines, char* want):
	char* source = native_path(c"reject.w")
	char* text = strjoin(c"export void f():\n\tasm_native:\n", lines)
	assert_equal(1, file_write_text(source, text))
	list[char*] argv = new list[char*]
	argv.push(c"wv2")
	argv.push(c"x64")
	if (object):
		argv.push(c"--emit=obj")
		argv.push(c"--freestanding")
		argv.push(c"--c-abi")
	argv.push(source)
	argv.push(c"-o")
	argv.push(native_path(c"reject.out"))
	process_result* r = tool_spawn(0, 60000, argv)
	if (r.status == 0): println2(text)
	assert1(r.status != 0)
	assert_contains(strjoin(r.stdout_text, r.stderr_text), want)
	process_result_free(r)


# Templates the native path rejects, each with its diagnostic.
void test_native_asm_rejects():
	native_reject(0, c"\t\t\".pushsection w_x,\\\"a\\\"\"\n\t\t\".popsection\"\n", c"sections and symbol references need --emit=obj")
	native_reject(0, c"\t\t\"call c_fn\"\n", c"sections and symbol references need --emit=obj")
	native_reject(1, c"\t\t\"jmp 9f\"\n", c"undefined local label: 9f")
	native_reject(1, c"\t\t\".ascii x\"\n", c"unsupported directive")
	native_reject(1, c"\t\t\".pushsection w_x\"\n", c"template ends outside its code")
	native_reject(1, c"\t\t\".popsection\"\n", c".popsection without .pushsection")
	native_reject(1, c"\t\t\"x: nop\"\n\t\t\"x: nop\"\n", c"label defined twice: x")
	native_reject(1, c"\t\t\".pushsection w_x\"\n\t\t\".balign 3\"\n", c"alignment must be a power of two")
	native_reject(1, c"\t\t\".pushsection w_x\"\n\t\t\".byte 300\"\n", c"value out of range")
	native_reject(1, c"\t\t\"lock;\"\n", c"prefix without an instruction")
	native_reject(1, c"\t\t\"frobnicate %eax\"\n", c"cannot assemble")
	native_reject(1, c"\t\t\"movw $sym, %ax\"\n", c"symbol operand needs a 32-bit field")
	native_reject(1, c"\t\t\"1: nop\"\n\t\t\".pushsection w_x\"\n\t\t\"2: .byte 0\"\n\t\t\".popsection\"\n\t\t\".pushsection w_y\"\n\t\t\".long 1b - 2b\"\n\t\t\".popsection\"\n", c"label difference across sections")
	native_reject(1, c"\t\t\".byte sym\"\n", c"an absolute symbol value must be 4 or 8 bytes")
	native_reject(1, c"\t\t\".pushsection w_x\"\n\t\t\".long (1\"\n\t\t\".popsection\"\n", c"unbalanced parentheses")
	native_reject(1, c"\t\t\".pushsection w_x,\\\"aQ\\\"\"\n\t\t\".popsection\"\n", c"unsupported section flag")


void test_native_asm_cleanup():
	dir_remove_all(native_dir)
	free(native_dir)
