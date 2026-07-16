# Fixture for wexec_test's direct-file coverage (issue #323 stage 1):
# tests/wexec/direct_file.json declares a "direct_file_known_target" whose
# own compile step names this file as its root, so
# 'bin/wexec -f tests/wexec/direct_file.json tests/wexec/direct_file/known.w'
# must resolve to running that target directly instead of synthesizing an
# ad-hoc one. Not "_test.w"-suffixed, so it is also invisible to
# tools/wbuildgen.w's scan.
int main():
	return 0
