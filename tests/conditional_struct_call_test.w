# Struct-valued ternary arms whose stack depths differ; the fixture runs
# under --streaming because that is the rule that compiles it (the AST
# front end falls back for struct-valued ternaries).
# wbuild: step="bin/wv2 --streaming --strict tests/conditional_struct_call_fixture.w -o bin/conditional_struct_call32"
# wbuild: step="bin/conditional_struct_call32"
# wbuild: step="bin/wv2 x64 --streaming --strict tests/conditional_struct_call_fixture.w -o bin/conditional_struct_call64"
# wbuild: step="bin/conditional_struct_call64"
int main():
	return 0
