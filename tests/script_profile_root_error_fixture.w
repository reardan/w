# With the curated root, a module the root does not hold still does not
# resolve for addon code: the upward search that would find lib/file.w
# in the checkout is closed to profiled sources.
# wfixture: --profile=script --import-root=bin/addon_root
# expect_fail
# expect_stderr: script profile: import 'lib.file' is not in an import root
import lib.str
import lib.file


int main():
	return 0
