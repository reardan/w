/*
wfuzz-found fixture (tools/wfuzz.w, issue #440): a struct embedding
itself by value used to crash the compiler. The struct name
pre-registers before its fields parse, so `ScalarPair r` inside
ScalarPair resolves; every consumer that walks the struct shape then
recursed to a stack overflow -- wfuzz found three on the same minimized
input (type_has_array_field, init_array_field_descriptors_at,
global_storage_ast_build), the smallest seeds being two lines.
struct_declaration now rejects the shape at completion, and
type_has_array_field keeps a depth cap as the second layer. The step
asserts the diagnostic comes out instead of a fatal signal.
*/
struct ScalarPair:
	ScalarPair r

int main():
	return 0
