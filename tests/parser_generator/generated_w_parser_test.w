import lib.testing
import libs.extras.parser_generator.runtime
import libs.extras.parser_generator.source_writer
import bin.generated_w_parser


void assert_w_parse_text(char* source, char* filename):
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_ast_node* root = wlang_parse(source, filename, diagnostics)
	if ((root == 0) | (pg_diagnostics_count(diagnostics) != 0)):
		pg_diagnostics_print(diagnostics)
	assert1(root != 0)
	assert_equal(0, pg_diagnostics_count(diagnostics))
	assert_equal(wlang_ast_program(), root.kind)


void assert_w_parse_file(char* path):
	char* source = pg_read_file_text(path)
	assert1(source != 0)
	assert_w_parse_text(source, path)


void test_parse_w_import_struct_and_function():
	assert_w_parse_text("import lib.testing\x0a\x0astruct point:\x0a\x09int x\x0a\x09int y\x0a\x0aint add(int a, int b):\x0a\x09return a + b\x0a", "inline.w")


void test_parse_w_control_flow_and_calls():
	assert_w_parse_text("int main(int argc, int argv):\x0a\x09if (argc >= 2):\x0a\x09\x09return syscall(1, 0, 0)\x0a\x09else:\x0a\x09\x09pass\x0a\x09for int i in range(0, 3):\x0a\x09\x09debugger\x0a\x09return 0\x0a", "control.w")


void test_parse_w_literals_arrays_and_new():
	assert_w_parse_text("struct point:\x0a\x09int x\x0a\x0avoid test_values():\x0a\x09int values[4]\x0a\x09values[0] = 42\x0a\x09char* s = \x22hello\\x0a\x22\x0a\x09point* p = new point(1)\x0a\x09p.x = values[0]\x0a", "values.w")


void test_parse_real_w_entrypoint():
	assert_w_parse_file("w.w")


void test_parse_real_hello_fixture():
	assert_w_parse_file("tests/hello.w")
