# The compiler implementation lives in bin/libwcompiler.so. The build
# target supplies its loader dependency through link=wcompiler.
import lib.lib

extern int compiler_main(int argc, int argv)


int main(int argc, int argv):
	return compiler_main(argc, argv)

# wbuild: binary=compiler_shared arch=x64 link=wcompiler out=bin/wcompiler_shared
# wbuild: target=compiler_shared_test tag=tests dep=compiler_shared
# wbuild: step="bin/wcompiler_shared --version" expect_stdout="w 0.3.0"
# wbuild: step="bin/wcompiler_shared check --json tests/hello.w"
# wbuild: step="bin/wcompiler_shared x64 tests/hello.w -o bin/compiler_shared_hello"
# wbuild: step="bin/compiler_shared_hello" expect_stdout="hello, world!"
# wbuild: step="bin/wcompiler_shared deps --json tests/hello.w" expect_stdout="tests/hello.w"
# wbuild: step="bin/wcompiler_shared symbols --json tests/hello.w" expect_stdout="main"
# wbuild: step="bin/wcompiler_shared x64 w.w -o bin/compiler_shared_self"
# wbuild: step="bin/compiler_shared_self --version" expect_stdout="w 0.3.0"
# wbuild: binary=compiler_static arch=x64 link=wcompiler_static out=bin/wcompiler_static
# wbuild: target=compiler_static_test tag=tests dep=compiler_static input=tests/compiler_static_host_test.py
# wbuild: step="bin/wcompiler_static --version" expect_stdout="w 0.3.0"
# wbuild: step="bin/wcompiler_static check --json tests/hello.w"
# wbuild: step="bin/wcompiler_static x64 tests/hello.w -o bin/compiler_static_hello"
# wbuild: step="bin/compiler_static_hello" expect_stdout="hello, world!"
# wbuild: step="bin/wcompiler_static x64 w.w -o bin/compiler_static_self"
# wbuild: step="bin/compiler_static_self --version" expect_stdout="w 0.3.0"
# wbuild: step="python3 tests/compiler_static_host_test.py bin/wcompiler_static" expect_stdout="static compiler standalone OK"
