# The compile itself must fail: int64/uint64 need the x64 target, and
# this source deliberately requests neither. Ported off the hand-written
# int64_x86_error_test build.base.json target (#323 bucket I) onto the
# `compile_fail` directive class.
# wbuild: compile_fail
# wbuild: expect_stderr="int64 requires the x64 target"

int64 unused_wide_value


int main():
	return 0
