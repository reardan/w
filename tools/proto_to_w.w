# wbuild: target=proto_to_w_test tag=tests dep=parser_generator_test
# wbuild: step="bin/parser_generator libs/extras/protobuf/proto.pg -o bin/generated_proto_parser.w"
# wbuild: step="cmp bin/generated_proto_parser.w libs/extras/protobuf/generated_proto_parser.w"
# wbuild: step="bin/wv2 tools/proto_to_w.w -o bin/proto_to_w"
# wbuild: step="bin/proto_to_w tests/protobuf/sample.proto -o bin/sample_pb.w"
# wbuild: step="cmp bin/sample_pb.w tests/protobuf/sample_pb.w"
/*
proto_to_w: generate W 'message' declarations from a .proto file
(issue #16 stage 2; libs/extras/protobuf/codegen.w).

	bin/proto_to_w schema.proto -o schema_pb.w

Without -o the module is written to stdout. Errors go to stderr as
"file:line: message" and exit 1.
*/
import lib.lib
import lib.args
import lib.file
import libs.extras.protobuf.codegen


void proto_to_w_usage():
	println2(c"usage: proto_to_w schema.proto [-o output.w]")


int main(int argc, int argv):
	args_init(argc, argv)
	if (args_positional_count() != 1):
		proto_to_w_usage()
		return 1
	char* input_path = args_positional(0)
	char* output_path = args_value(c"o")
	char* input = file_read_text(input_path)
	if (input == 0):
		print2(c"proto_to_w: could not read ")
		println2(input_path)
		return 1
	proto_codegen_result* result = proto_to_w(input, input_path)
	if (result.source == 0):
		int i = 0
		while (i < result.errors.length):
			println2(result.errors[i])
			i = i + 1
		return 1
	if (output_path == 0):
		print(result.source)
		return 0
	if (file_write_text(output_path, result.source) == 0):
		print2(c"proto_to_w: could not write ")
		println2(output_path)
		return 1
	return 0
