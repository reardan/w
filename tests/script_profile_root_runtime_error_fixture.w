# With the curated root, lib/lib.w compiles from the root as a trusted
# import, but its file-descriptor I/O and exit paths are still not the
# addon's to call.
# wfixture: --profile=script --import-root=bin/addon_root
# expect_fail
# expect_stderr: script profile: runtime function 'print_write' is not visible to addon code
import lib.str


int main():
	print_write(1, c"x", 1)
	return 0
