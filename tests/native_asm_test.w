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


void test_native_asm_cleanup():
	dir_remove_all(native_dir)
	free(native_dir)
