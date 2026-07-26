# End-to-end exercise of wbuildgen's 'arch_only=' directive
# (tools/wbuildgen.w): this source yields exactly one generated target,
# compiled with the x64 selector under the basename-derived name — no
# default 32-bit twin exists in build.json at all (manifest_check pins
# that) — so the word-size assert below proves the selector was applied
# to the binary that actually runs.
# wbuild: arch_only=x64 expect_stdout="arch only OK"
import lib.lib
import lib.assert


int main():
	assert_equal(8, __word_size__)
	println(c"arch only OK")
	return 0
