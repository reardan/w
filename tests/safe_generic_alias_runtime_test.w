# wbuild: step="bin/wv2 --strict tests/safe_generic_alias_runtime_fixture.w -o bin/safe_generic_alias_runtime"
# wbuild: step="bin/safe_generic_alias_runtime"
# wbuild: step="bin/wv2 --strict --streaming tests/safe_generic_alias_runtime_fixture.w -o bin/safe_generic_alias_streaming"
# wbuild: step="bin/safe_generic_alias_streaming"
# wbuild: step="bin/wv2 x64 --strict tests/safe_generic_alias_runtime_fixture.w -o bin/safe_generic_alias_runtime64"
# wbuild: step="bin/safe_generic_alias_runtime64"
# wbuild: step="bin/wv2 x64 --strict --streaming tests/safe_generic_alias_runtime_fixture.w -o bin/safe_generic_alias_streaming64"
# wbuild: step="bin/safe_generic_alias_streaming64"
int main():
	return 0
