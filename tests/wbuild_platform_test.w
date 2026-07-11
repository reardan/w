# End-to-end exercise of wbuildgen's platform axis (tools/wbuildgen.w):
# one source, four twins declared by a single '# wbuild:' line —
# default (32-bit x86), arm64, win64 and arm64_darwin. arm64 actually
# runs here (wrapped in tools/run_arm64.sh, under qemu in this
# container); win64 and arm64_darwin are compile-only proof that the
# cross-compile step succeeds — running them rides wine and
# tools/mac/run_darwin_tests.sh respectively, neither available here.
# wbuild: arch=arm64 arch=win64 arch=arm64_darwin
# wbuild: expect_stdout="platform axis OK"
import lib.lib


int main():
	println(c"platform axis OK")
	return 0
