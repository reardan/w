# wbuild: x64 tool=tools/wc2.w expect_stdout="wc2_memory_test: OK"
# A fresh process makes a zero-leak assertion meaningful: no testing
# harness, unrelated parser trees, or formatting allocations precede it.
import lib.assert
import tools.wc2.lower
import tools.wc2.dump
import tools.wc2.emit
import tools.wc2.load


int main():
	malloc_force_debug_mode()
	wc2_module* retained = wc2_parse(c"int keep(): return 7\n", c"keep.w")
	assert1(wc2_module_ok(retained))
	for i in range(3):
		# Successful alternatives, failed alternatives, error recovery,
		# lexer errors and an empty file all have the same ownership API.
		wc2_module* m = wc2_parse(c"int f(int x):\n\tif x: return 2 + 3 * 4\n\treturn 0\n", c"ok.w")
		assert1(wc2_module_ok(m))
		char* dump = wc2_dump(m)
		free(dump)
		wc2_module_free(m)
		m = wc2_parse(c"int main(): return (0 && (1 / 0)) + ((~3 ^ 5) * 7 >> 2)\n", c"emit.w")
		asm_buffer* image = wc2_emit(m)
		assert1(image != 0)
		asm_buffer* again = wc2_emit(m)
		assert1(again != 0)
		assert_equal(image.length, again.length)
		assert1(mem_eq(image.data, again.data, image.length))
		wc2_module_free(m)
		asm_buffer_free(image)
		asm_buffer_free(again)
		m = wc2_parse(c"struct Pair:\n\tint x\n\tbool ready\nint read(Pair p):\n\tif p.ready: return p.x\n\telse: return 0\nint main():\n\tPair p\n\tp.x = 7\n\tp.ready = 1\n\tint i = 0\n\twhile i < 3:\n\t\ti += 1\n\t\tif i == 2: continue\n\t\tp.x += read(p)\n\treturn p.x\n", c"program.w")
		image = wc2_emit(m)
		assert1(image != 0)
		asm_buffer_free(image)
		wc2_module_free(m)
		m = wc2_parse(c"int main(): return 4294967296\n", c"overflow.w")
		assert1(wc2_emit(m) == 0)
		wc2_module_free(m)
		m = wc2_parse(c"int f(\nint good(): return 1\n", c"syntax.w")
		assert_equal(0, wc2_module_ok(m))
		wc2_module_free(m)
		m = wc2_parse(c"int f(): return @\n", c"lexer.w")
		assert_equal(0, wc2_module_ok(m))
		wc2_module_free(m)
		m = wc2_parse(c"int f(): return 1.5\n", c"unsupported.w")
		assert_equal(0, wc2_module_ok(m))
		wc2_module_free(m)
		m = wc2_parse(c"", c"empty.w")
		assert1(wc2_module_ok(m))
		wc2_module_free(m)
	assert1(wc2_module_ok(retained))
	wc2_module_free(retained)
	# Import merge, duplicate suppression and dependency ownership must
	# also release everything (including discarded module-root tables).
	string_builder* module_name = string_new()
	string_append(module_name, c"bin.wc2_memory_import_")
	string_append_int(module_name, getpid())
	char* path = strclone(module_name.data)
	for i in range(strlen(path)):
		if (path[i] == '.'): path[i] = '/'
	char* filename = strjoin(path, c".w")
	assert1(file_write_text(filename, c"int twice(int x): return x * 2\n"))
	string_builder* source = string_new()
	string_append(source, c"import ")
	string_append(source, module_name.data)
	string_append(source, c"\nimport ")
	string_append(source, module_name.data)
	string_append(source, c"\nint main(): return twice(7)\n")
	wc2_module* imported = wc2_parse(source.data, c"importer.w")
	wc2_load_imports(imported)
	asm_buffer* image = wc2_emit(imported)
	assert1(image != 0)
	asm_buffer_free(image)
	wc2_module_free(imported)
	assert1(file_write_text(filename, c"int broken(\n"))
	imported = wc2_parse(source.data, c"importer.w")
	wc2_load_imports(imported)
	assert_equal(0, wc2_module_ok(imported))
	wc2_module_free(imported)
	unlink(filename)
	free(filename)
	free(path)
	string_free(module_name)
	string_free(source)
	assert_equal(0, debug_alloc_report_leaks())
	println(c"wc2_memory_test: OK")
	return 0
