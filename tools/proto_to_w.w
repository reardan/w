# wbuild: target=protobuf_generated tag=generated dep=wv2 input=libs/extras/protobuf/ input=libs/extras/parser_generator/ input=tools/parser_generator.w input=tools/proto_to_w.w input=tests/protobuf/ output=libs/extras/protobuf/generated_proto_parser.w output=tests/protobuf/common_pb.w output=tests/protobuf/sample_pb.w
# wbuild: step="bin/wv2 tools/parser_generator.w -o bin/parser_generator_protobuf"
# wbuild: step="bin/parser_generator_protobuf libs/extras/protobuf/proto.pg -o libs/extras/protobuf/generated_proto_parser.w"
# wbuild: step="bin/wv2 tools/proto_to_w.w -o bin/proto_to_w_generated"
# wbuild: step="bin/proto_to_w_generated tests/protobuf/common.proto -o tests/protobuf/common_pb.w"
# wbuild: step="bin/proto_to_w_generated tests/protobuf/sample.proto -o tests/protobuf/sample_pb.w"
# wbuild: target=proto_to_w_test tag=tests dep=wv2
# wbuild: step="bin/wv2 tools/proto_to_w.w -o bin/proto_to_w"
# wbuild: step="bin/proto_to_w tests/protobuf/sample.proto -o bin/sample_pb.w"
# wbuild: step="cmp bin/sample_pb.w tests/protobuf/sample_pb.w"
# wbuild: step="bin/proto_to_w tests/protobuf/common.proto -o bin/common_pb.w"
# wbuild: step="cmp bin/common_pb.w tests/protobuf/common_pb.w"
/*
proto_to_w: generate W 'message' declarations from a .proto file
(issue #16 stage 2; libs/extras/protobuf/codegen.w).

	bin/proto_to_w schema.proto -o schema_pb.w [-I root]

Without -o the module is written to stdout. 'import "a/b.proto"' is
read from <root>/a/b.proto (root defaults to the current directory)
and becomes 'import a.b_pb': generate each imported file to
<root>/a/b_pb.w, with <root> the directory W imports resolve from. Errors go to stderr as
"file:line: message" and exit 1.

The protobuf_generated target above (tag=generated, issue #323: no
committed generated files) builds libs/extras/protobuf/generated_proto_parser.w
from proto.pg and the tests/protobuf/*_pb.w modules from their .proto
files before any other target runs; proto_to_w_test regenerates the
modules through bin/proto_to_w and compares them with those outputs.
*/
import lib.lib
import lib.args
import lib.file
import libs.extras.protobuf.codegen


void proto_to_w_usage():
	println2(c"usage: proto_to_w schema.proto [-o output.w] [-I import_root]")


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
	list[char*] roots = new list[char*]
	char* root = args_value(c"I")
	if (root == 0): root = c"."
	roots.push(root)
	proto_codegen_result* result = proto_to_w_with_roots(input, input_path, roots)
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
