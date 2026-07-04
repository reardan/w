/*
Standalone ParserGenerator CLI.
*/
import lib.lib
import lib.args
import libs.extras.parser_generator.diagnostics
import libs.extras.parser_generator.grammar_reader
import libs.extras.parser_generator.generator
import libs.extras.parser_generator.source_writer


void parser_generator_usage():
	println2("usage: parser_generator grammar.pg -o output.w")


int main(int argc, int argv):
	args_init(argc, argv)
	if (args_positional_count() < 1):
		parser_generator_usage()
		return 1
	char* input_path = args_positional(0)
	char* output_path = args_value("o")
	if (output_path == 0):
		output_path = args_value("output")
	if (output_path == 0):
		parser_generator_usage()
		return 1
	char* input = pg_read_file_text(input_path)
	if (input == 0):
		print2("parser_generator: could not read ")
		println2(input_path)
		return 1
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_grammar* grammar = pg_grammar_read(input, input_path, diagnostics)
	if ((grammar == 0) | (pg_diagnostics_count(diagnostics) > 0)):
		pg_diagnostics_print(diagnostics)
		return 1
	char* source = pg_generate_parser(grammar)
	if (pg_write_file_text(output_path, source) == 0):
		print2("parser_generator: could not write ")
		println2(output_path)
		return 1
	print2("generated ")
	println2(output_path)
	return 0
