/*
Static test registry (issue #147). When the compiled program defines
__w_run_tests (lib/testing.w does), the driver synthesizes __w_test_main
at the final top-level boundary: one __w_run_tests(name, fn) call per
defined zero-argument test_* function, in definition order. Test
discovery therefore needs no binary-format introspection at runtime -
it works identically for ELF, Mach-O, and PE output and survives
stripped binaries, replacing the ELF section-header walk that aborted
on arm64_darwin with "No symbol table addr".

This file is compiled by the committed seed: only seed-understood
syntax here.
*/


# A discovered test: a defined zero-argument function. symbol is the
# table offset of the name's NUL terminator, like every sym_* accessor.
int test_registry_is_test(int symbol):
	if (table[symbol + 1] != 'D'):
		return 0
	if (load_int(table + symbol + 10) != 2):
		return 0
	return sym_num_args(symbol) == 0


# Emit __w_run_tests(name, fn) with both operands materialized inline:
# callee first, then the arguments (the first at the highest stack
# offset), the same layout for_iter_call and the postfix call path use.
void test_registry_emit_call(char* name):
	sym_get_value(c"__w_run_tests")
	push_eax()
	be_emit_inline_cstr(strlen(name), name)
	push_eax()
	sym_get_value(name)
	push_eax()
	mov_eax_esp_plus(2 << word_size_log2)
	call_eax()
	be_pop(3)


# Called once per batch compilation, after every user file, runtime
# import, and queued generic instantiation has been compiled (the REPL
# does not run tests and skips this).
void test_registry_finish():
	if (sym_lookup(c"__w_run_tests") < 0):
		return;
	sym_define_declare_global_function(c"__w_test_main")
	be_function_prologue()
	int t = 0
	while (t <= table_pos - 1):
		char* name = table + t
		t = t + strlen(table + t)
		if (starts_with(name, c"test_")):
			if (test_registry_is_test(t)):
				test_registry_emit_call(name)
		t = next_token(t)
	ret()
