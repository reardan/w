# wbuild: target=android_executor_signal_device_test dep=wv2
# wbuild: step="bin/wv2 arm64_android --strict tools/wexec_main.w tests/android_elf_imports.w -o bin/wexec_android_signal_test"
# wbuild: step="python3 tests/android_executor_signal_test.py bin/wexec_android_signal_test"
# wbuild: target=android_build_tools_compile_test tag=tests dep=wv2
# wbuild: step="bin/wv2 arm64 --strict tools/wexec_main.w -o bin/wexec_arm64_cross"
# wbuild: step="bin/wv2 arm64_android --strict tools/wexec_main.w -o bin/wexec_android_cross"
# wbuild: step="bin/wv2 arm64_android --strict tools/test_map.w -o bin/wtest_android_cross"
# wbuild: step="bin/wv2 arm64_android --strict tools/wbuildgen.w -o bin/wbuildgen_android_cross"
# bin/wexec's entry point. The executor itself lives in tools/wexec.w,
# kept free of a main() so tools/wbuildd.w can import it and run builds
# in-process (docs/projects/wbuildd.md, "Build RPC").
import tools.wexec


int main(int argc, int argv):
	return wexec_main(argc, argv)
