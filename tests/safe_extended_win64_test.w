# Cross-compile every checked language extension on ordinary test hosts.
# Runtime variants execute under the explicit tests_win64 umbrella.
# wbuild: step="bin/wv2 win64 --ast-required --strict tests/safe_optional_runtime_fixture.w -o bin/safe_optional_runtime.exe"
# wbuild: step="bin/wv2 win64 --ast-required --strict tests/safe_methods_runtime_fixture.w -o bin/safe_methods_runtime.exe"
# wbuild: step="bin/wv2 win64 --ast-required --strict tests/safe_control_flow_runtime_fixture.w -o bin/safe_control_flow_runtime.exe"
# wbuild: target=safe_extended_win64_runtime_test tag=tests_win64 dep=wv2
# wbuild: step="bin/wv2 win64 --ast-required --strict tests/safe_optional_runtime_fixture.w -o bin/safe_optional_runtime.exe"
# wbuild: step="wine bin/safe_optional_runtime.exe"
# wbuild: step="bin/wv2 win64 --ast-required --strict tests/safe_methods_runtime_fixture.w -o bin/safe_methods_runtime.exe"
# wbuild: step="wine bin/safe_methods_runtime.exe"
# wbuild: step="bin/wv2 win64 --ast-required --strict tests/safe_control_flow_runtime_fixture.w -o bin/safe_control_flow_runtime.exe"
# wbuild: step="wine bin/safe_control_flow_runtime.exe"
# wbuild: step="bin/wv2 win64 --ast-required --no-regs --no-inline --strict tests/safe_optional_runtime_fixture.w -o bin/safe_optional_runtime_plain.exe"
# wbuild: step="wine bin/safe_optional_runtime_plain.exe"
# wbuild: step="bin/wv2 win64 --ast-required --no-regs --no-inline --strict tests/safe_methods_runtime_fixture.w -o bin/safe_methods_runtime_plain.exe"
# wbuild: step="wine bin/safe_methods_runtime_plain.exe"
# wbuild: step="bin/wv2 win64 --ast-required --no-regs --no-inline --strict tests/safe_control_flow_runtime_fixture.w -o bin/safe_control_flow_runtime_plain.exe"
# wbuild: step="wine bin/safe_control_flow_runtime_plain.exe"
int main():
	return 0
