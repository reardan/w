/*
Standalone ParserGenerator CLI.
*/
import lib.lib
import lib.args
import libs.extras.parser_generator.diagnostics
import libs.extras.parser_generator.grammar_reader
import libs.extras.parser_generator.analysis
import libs.extras.parser_generator.generator
import libs.extras.parser_generator.source_writer


void parser_generator_usage():
	println2(c"usage: parser_generator grammar.pg -o output.w [--report]")
	println2(c"  --report: print LL(1) dispatch conflicts (rules kept on the")
	println2(c"            backtracking path and their colliding first-set")
	println2(c"            tokens) to stderr while generating")


int main(int argc, int argv):
	args_init(argc, argv)
	if (args_positional_count() < 1):
		parser_generator_usage()
		return 1
	char* input_path = args_positional(0)
	char* output_path = args_value(c"o")
	if (output_path == 0):
		output_path = args_value(c"output")
	if (output_path == 0):
		parser_generator_usage()
		return 1
	char* input = pg_read_file_text(input_path)
	if (input == 0):
		print2(c"parser_generator: could not read ")
		println2(input_path)
		return 1
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_grammar* grammar = pg_grammar_read(input, input_path, diagnostics)
	if ((grammar == 0) | (pg_diagnostics_count(diagnostics) > 0)):
		pg_diagnostics_print(diagnostics)
		return 1
	if (args_has_flag(c"report")):
		pg_report_dispatch(grammar)
	char* source = pg_generate_parser(grammar)
	if (source == 0):
		print2(c"parser_generator: ")
		print2(input_path)
		println2(c": generation failed (see diagnostics above)")
		return 1
	if (pg_write_file_text(output_path, source) == 0):
		print2(c"parser_generator: could not write ")
		println2(output_path)
		return 1
	print2(c"generated ")
	println2(output_path)
	return 0
