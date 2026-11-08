# wbuild: target=wfuzz_c_smoke tag=tests dep=wfuzz data=tests/ data=tools/fuzz/dicts/c.dict
# wbuild: step="bin/wv2 --coverage tools/fuzz/harness_c.w -o bin/wfuzz_c_harness"
# wbuild: step="rm -rf bin/wfuzz_c_smoke"
# wbuild: step="bin/wfuzz --binary bin/wfuzz_c_harness --ext .h --dict tools/fuzz/dicts/c.dict --corpus tests --out bin/wfuzz_c_smoke --cases 0 --fail-on-findings" expect_stdout="crashes: 0" timeout=300000
# wbuild: target=wfuzz_c dep=wfuzz
# wbuild: step="bin/wv2 --coverage tools/fuzz/harness_c.w -o bin/wfuzz_c_harness"
# wbuild: step="bin/wfuzz --binary bin/wfuzz_c_harness --ext .h --dict tools/fuzz/dicts/c.dict --corpus tests --out bin/wfuzz_c" timeout=3600000
# wbuild: target=wfuzz_c_import dep=wfuzz data=tools/fuzz/c_import_driver.wfuzz data=tests/ data=tools/fuzz/dicts/c.dict
# wbuild: step="mkdir -p bin/wfuzz_c_import"
# wbuild: step="cp tools/fuzz/c_import_driver.wfuzz bin/wfuzz_c_import/driver.w"
# wbuild: step="bin/wv2 --coverage w.w -o bin/wfuzz_c_import/compiler_cov"
# wbuild: step="bin/wfuzz --binary bin/wfuzz_c_import/compiler_cov --arg check --arg bin/wfuzz_c_import/driver.w --ext .h --dict tools/fuzz/dicts/c.dict --corpus tests --out bin/wfuzz_c_import/out" timeout=3600000
# Fuzz harness for the C front end behind c_import (issue #842):
# libs/extras/c_preprocessor (directives, macro expansion, #if
# arithmetic, #include resolution) over the input file, then the
# generated C parser (libs/extras/c_import/generated_c_parser.w) over the
# preprocessed text. The importer's lowering into the compiler's type
# tables runs in the compiler itself: wfuzz_c_import fuzzes that half,
# running the --coverage compiler's 'check' on tools/fuzz/
# c_import_driver.wfuzz, which c_imports the case file.
# Seeds are the c_import fixture headers under tests/.
import tools.fuzz.harness
import libs.extras.parser_generator.runtime


# The compiler's diagnostic interface, as standalone users of the
# preprocessor supply it (tests/c_preprocessor_standalone_test.w): an
# error is a rejection.
void diag_part(char* s):
	print_error(s)


void error(char* s):
	print_error(s)
	print_error(c"\n")
	exit(1)


import libs.extras.c_preprocessor.pp_directives
import libs.extras.c_import.generated_c_parser


int main(int argc, int argv):
	args_init(argc, argv)
	if (args_count() < 2):
		println2(c"usage: harness_c <file.h>")
		return 2
	char* path = args_get(1)
	cpp_result* pre = cpp_preprocess_file(path)
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_ast_node* root = clang_parse(pre.text, path, diagnostics)
	if ((root == 0) || (pg_diagnostics_count(diagnostics) != 0)): return 1
	return 0
