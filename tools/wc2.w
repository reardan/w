# wbuild: target=wc2_parser dep=parser_generator_test input=tests/parser_generator/w.pg output=bin/wc2_parser.w
# wbuild: step="bin/parser_generator tests/parser_generator/w.pg -o bin/wc2_parser.w"
# wbuild: binary=wc2 dep=wc2_parser
/*
Leaf AST compiler experiment (#488): semantic AST inspection and native
code generation for the documented functions/control-flow/struct subset. See docs/projects/wc2.md.
*/
import lib.file
import tools.wc2.lower
import tools.wc2.dump
import tools.wc2.emit
import tools.wc2.load


int main(int argc, char** argv):
	int dump_mode = (argc == 3) && (strcmp(argv[1], c"--dump-ast") == 0)
	int compile_mode = (argc == 4) && (strcmp(argv[2], c"-o") == 0) && (argv[1][0] != '-') && (argv[3][0] != 0)
	if ((dump_mode || compile_mode) == 0):
		println2(c"usage: wc2 --dump-ast file.w")
		println2(c"       wc2 file.w -o output  (Linux x86 ELF)")
		return 2
	char* path = argv[1]
	if (dump_mode): path = argv[2]
	char* source = file_read_text(path)
	if (source == 0):
		print2(c"wc2: cannot read ")
		println2(path)
		return 1
	wc2_module* m = wc2_parse(source, path)
	free(source)
	if (compile_mode): wc2_load_imports(m)
	int status = 1
	if (wc2_module_ok(m) && dump_mode):
		char* dump = wc2_dump(m)
		print(dump)
		free(dump)
		status = 0
	elif (wc2_module_ok(m)):
		asm_buffer* image = wc2_emit(m)
		if (image != 0):
			if (wc2_write_executable(argv[3], image)): status = 0
			else:
				print2(c"wc2: cannot write executable ")
				println2(argv[3])
			asm_buffer_free(image)
	if (wc2_module_ok(m) == 0): pg_diagnostics_print(m.diagnostics)
	wc2_module_free(m)
	return status
