import libs.extras.protobuf.message

message ast_pb_item:
	int32 value = 1

type ast_pb_alias = ast_pb_item
int ast_pb_order
ast_pb_item ast_pb_make(int value):
	ast_pb_order = ast_pb_order + 1
	return ast_pb_item(value)

char* ast_pb_data(char* data):
	ast_pb_order = ast_pb_order * 10 + 1
	return data

int ast_pb_length(int length):
	ast_pb_order = ast_pb_order * 10 + 2
	return length

int ast_pb_shadow();
int main():
	pb_bytes* encoded = to_proto(ast_pb_make(42))
	if (ast_pb_order != 1): return 1
	ast_pb_alias* decoded = from_proto(ast_pb_alias, encoded)
	if (decoded.value != 42): return 2
	if (from_proto(ast_pb_item, to_proto(decoded)).value != 42): return 3
	ast_pb_order = 0
	ast_pb_item* raw = from_proto(ast_pb_item, ast_pb_data(encoded.data), ast_pb_length(encoded.length))
	if (raw.value != 42 || ast_pb_order != 12): return 4
	pb_message_desc* descriptor = proto_descriptor(ast_pb_item)
	if (descriptor != proto_descriptor(ast_pb_alias)): return 5
	if (descriptor.field_count != 1): return 6
	if (from_proto(ast_pb_item, 0) != 0): return 7
	pb_free_message(descriptor, cast(char*, decoded))
	pb_free_message(descriptor, cast(char*, raw))
	pb_bytes_free(encoded)
	if (ast_pb_shadow() != 5): return 8
	return 0

int from_proto(int value): return value + 1
int ast_pb_shadow(): return from_proto(4)
