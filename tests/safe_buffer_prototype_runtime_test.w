# wbuild: step="bin/wv2 --strict tests/safe_buffer_prototype_runtime_fixture.w -o bin/safe_buffer_prototype_runtime_fixture"
# wbuild: step="env W_DEBUG_ALLOC=1 bin/safe_buffer_prototype_runtime_fixture"
# wbuild: step="bin/wv2 --strict x64 tests/safe_buffer_prototype_runtime_fixture.w -o bin/safe_buffer_prototype_runtime_fixture64"
# wbuild: step="env W_DEBUG_ALLOC=1 bin/safe_buffer_prototype_runtime_fixture64"
int main():
	return 0
