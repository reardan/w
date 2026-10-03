# wbuild: target=wc2_parser dep=parser_generator_test input=tests/parser_generator/w.pg output=bin/wc2_parser.w
# wbuild: step="bin/parser_generator tests/parser_generator/w.pg -o bin/wc2_parser.w"
# wbuild: binary=wc2 dep=wc2_parser
/*
Leaf AST compiler experiment (#488), task 1: lower a documented subset of
the parser-generator tree into a semantic AST. See docs/projects/wc2.md.
*/
import lib.file
import tools.wc2.lower
import tools.wc2.dump


int main(int argc, char** argv):
	if ((argc != 3) || (strcmp(argv[1], c"--dump-ast") != 0)):
		println2(c"usage: wc2 --dump-ast file.w")
		return 2
	char* source = file_read_text(argv[2])
	if (source == 0):
		print2(c"wc2: cannot read ")
		println2(argv[2])
		return 1
	wc2_module* m = wc2_parse(source, argv[2])
	free(source)
	int status = 1
	if (wc2_module_ok(m)):
		char* dump = wc2_dump(m)
		print(dump)
		free(dump)
		status = 0
	else: pg_diagnostics_print(m.diagnostics)
	wc2_module_free(m)
	return status
