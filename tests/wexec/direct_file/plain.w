# Fixture for wexec_test's direct-file coverage (issue #323 stage 1):
# a plain (non-"_test.w") source with no manifest target compiling it, so
# 'bin/wexec -f tests/wexec/direct_file.json tests/wexec/direct_file/plain.w'
# takes the ad-hoc-synthesis branch. Not "_test.w"-suffixed, so it is also
# invisible to tools/wbuildgen.w's scan and never becomes a real
# build.json target.
int main():
	return 0
