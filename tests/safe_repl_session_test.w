# wbuild: x64 timeout=600000
# Checked ownership across persistent REPL entries (#713): owners and
# borrows persist between entries, failed entries roll back without
# publishing anything, replaced and remaining owners are destroyed exactly
# once (W_DEBUG_ALLOC turns a second destruction into a fault and the
# fixture counts live cells), and unsupported entry forms fail explicitly.
# The 32-bit test drives a 32-bit REPL and the x64 twin a 64-bit one.
import lib.testing
import lib.process
import lib.file
import lib.env
import lib.str


char* safe_repl_binary


char* safe_repl_path(char* stem, char* suffix):
	char* name = strjoin(stem, itoa(__word_size__ * 8))
	char* path = strjoin(name, suffix)
	free(name)
	return path


process_result* safe_repl_exec(char** args, char* input):
	spawn_options* opts = spawn_options_new()
	opts.env = env_copy_with(env_current(), c"W_DEBUG_ALLOC", c"1")
	process_result* result = process_run(args[0], args, opts, input, 300000)
	assert1(result != 0)
	return result


char* safe_repl_build():
	if (safe_repl_binary != 0): return safe_repl_binary
	safe_repl_binary = safe_repl_path(c"bin/safe_repl_session_repl", c"")
	char** args = strv_new(5)
	strv_set(args, 0, c"bin/wv2")
	int at = 1
	if (__word_size__ == 8):
		strv_set(args, 1, c"x64")
		at = 2
	strv_set(args, at, c"repl.w")
	strv_set(args, at + 1, c"-o")
	strv_set(args, at + 2, safe_repl_binary)
	process_result* built = process_run(args[0], args, 0, 0, 600000)
	assert1(built != 0)
	if (built.status != 0): println(built.stderr_text)
	assert_equal(0, built.status)
	process_result_free(built)
	free(cast(void*, args))
	return safe_repl_binary


# Run one session with the fixture loaded.
process_result* safe_repl_run(char* input):
	char** args = strv_new(4)
	strv_set(args, 0, safe_repl_build())
	strv_set(args, 1, c"--no_main")
	strv_set(args, 2, c"tests/safe_repl_session_fixture.w")
	process_result* result = safe_repl_exec(args, input)
	free(cast(void*, args))
	return result


# Each needle occurs in text, in this order.
void safe_repl_expect_order(char* text, list[char*] needles):
	int at = 0
	for i in range(needles.length):
		int found = index_of(text + at, needles[i])
		if (found < 0):
			print(c"missing in order: ")
			println(needles[i])
			println(text)
		assert1(found >= 0)
		at = at + found + strlen(needles[i])


list[char*] safe_repl_lines(char* a, char* b, char* c, char* d):
	list[char*] lines = new list[char*]
	if (a != 0): lines.push(a)
	if (b != 0): lines.push(b)
	if (c != 0): lines.push(c)
	if (d != 0): lines.push(d)
	return lines


void test_owners_persist_and_drop_once():
	process_result* r = safe_repl_run(c"safe_repl_report(c\"start\")\nown cell* a = new cell\na.value = 5\na.value + 37\nsafe_repl_report(c\"one\")\nown cell* a = new cell\nsafe_repl_report(c\"replaced\")\na.value + 40\nown cell* l = new cell\nown cell* m = new cell\nown pair* p = new pair(l, m)\np.left.value = 4\np.left.value + 1\nsafe_repl_report(c\"three\")\n:reset\nsafe_repl_report(c\"reset\")\nown cell* kept = new cell\n:quit\n")
	assert_equal(0, r.status)
	safe_repl_expect_order(r.stdout_text, safe_repl_lines(c"start live=0", c"42", c"one live=1", c"replaced live=1"))
	safe_repl_expect_order(r.stdout_text, safe_repl_lines(c"replaced live=1", c"40", c"5", c"three live=3"))
	safe_repl_expect_order(r.stdout_text, safe_repl_lines(c"three live=3", c"reset live=0", 0, 0))
	assert_lacks(r.stderr_text, c"error")
	assert_lacks(r.stdout_text, c"memory_debug")
	process_result_free(r)


void test_moves_borrows_and_failed_entries():
	process_result* r = safe_repl_run(c"own cell* q = new cell\nq.value = 9\nref cell* r = q\nint bad = qq_missing + safe_repl_take(q)\nsafe_repl_take(q); safe_repl_peek(r)\nsafe_repl_peek(r) + 100\nsafe_repl_take(q) + 200\nq.value\nsafe_repl_peek(r)\nsafe_repl_report(c\"moved\")\nown cell* q = new cell\nq.value = 1\nq.value + 300\n:quit\n")
	assert_equal(0, r.status)
	safe_repl_expect_order(r.stdout_text, safe_repl_lines(c"109", c"209", c"moved live=0", c"301"))
	safe_repl_expect_order(r.stderr_text, safe_repl_lines(c"Cannot find symbol: 'qq_missing'", c"error: safe:", c"use of uninitialized or moved value", c"use of uninitialized or moved value"))
	assert_contains(r.stderr_text, c"note: checked session transcript line")
	process_result_free(r)


void test_fault_discards_only_changed_bindings():
	process_result* r = safe_repl_run(c"own cell* g = new cell\nown cell* keep = new cell\nkeep.value = 4\nown cell* h = g; 1 / 0\ng.value\nkeep.value + 1\nsafe_repl_report(c\"faulted\")\n:reset\nsafe_repl_report(c\"after\")\n:quit\n")
	assert_equal(0, r.status)
	safe_repl_expect_order(r.stdout_text, safe_repl_lines(c"entry rolled back", c"note: checked session bindings were discarded after the fault", c"5", c"faulted live=2"))
	# keep is destroyed at :reset; g's cell is leaked, never destroyed twice.
	safe_repl_expect_order(r.stdout_text, safe_repl_lines(c"faulted live=2", c"after live=1", 0, 0))
	assert_contains(r.stderr_text, c"this checked session binding was discarded after a runtime fault")
	process_result_free(r)


void test_unsupported_forms_fail_explicitly():
	process_result* r = safe_repl_run(c"own cell* a = new cell\nint sneaky():\n\treturn a.value\n\nint use(own cell* c):\n\treturn c.value\n\nint use(ref cell* c):\n\treturn c.value\n\n:type own cell* z = new cell\nint flag = 1\nif (flag): safe_repl_take(a)\nown cell* a = new cell; own cell* a = new cell\na.value + 7\n:quit\n")
	assert_equal(0, r.status)
	safe_repl_expect_order(r.stderr_text, safe_repl_lines(c"cannot use a checked session binding; pass it as an argument", c"redefinition changes a checked function contract", c"an entry that is not run cannot declare checked session bindings", c"must be held or moved on every path of an entry"))
	assert_contains(r.stderr_text, c"a checked session binding cannot be redeclared in the entry that declared it")
	assert_contains(r.stdout_text, c"7")
	process_result_free(r)


void test_imported_source_edit_and_reset():
	char* module = safe_repl_path(c"bin/safe_repl_session_mod", c".w")
	char* second = safe_repl_path(c"bin/safe_repl_session_mod_next", c".w")
	file_write_text(module, c"int safe_repl_mod(ref cell* c):\n\treturn c.value + 1\n")
	file_write_text(second, c"int safe_repl_mod(own cell* c):\n\treturn c.value + 2\n")
	char* import_line = safe_repl_path(c"import bin.safe_repl_session_mod", c"\n")
	string_builder* input = string_new()
	string_append(input, import_line)
	string_append(input, c"own cell* a = new cell\na.value = 3\nsafe_repl_mod(a) + 10\nsafe_repl_mod(a) + 20\n!cp ")
	string_append(input, second)
	string_append_char(input, ' ')
	string_append(input, module)
	string_append(input, c"\n:reset\nsafe_repl_report(c\"reset\")\n")
	string_append(input, import_line)
	string_append(input, c"own cell* b = new cell\nb.value = 5\nsafe_repl_mod(b) + 30\nb.value\nsafe_repl_report(c\"end\")\n:quit\n")
	process_result* r = safe_repl_run(input.data)
	assert_equal(0, r.status)
	safe_repl_expect_order(r.stdout_text, safe_repl_lines(c"14", c"24", c"reset live=0", c"37"))
	safe_repl_expect_order(r.stdout_text, safe_repl_lines(c"37", c"end live=0", 0, 0))
	assert_contains(r.stderr_text, c"use of uninitialized or moved value")
	process_result_free(r)
	string_free(input)
	unlink(module)
	unlink(second)


void test_safe_flag_still_rejected():
	char** args = strv_new(3)
	strv_set(args, 0, safe_repl_build())
	strv_set(args, 1, c"--safe")
	process_result* r = safe_repl_exec(args, c":quit\n")
	assert1(r.status != 0)
	assert_contains(r.stderr_text, c"--safe is not supported by in-process REPL or debugger sessions")
	process_result_free(r)
	free(cast(void*, args))
