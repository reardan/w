# Fixture for wexec_test's direct-file coverage (issue #323 stage 1): a
# "_test.w" source with no manifest target compiling it, so
# 'bin/wexec -f tests/wexec/direct_file.json [x64] tests/wexec/direct_file/sample_test.w'
# takes the ad-hoc-synthesis branch and, because the name ends in
# "_test.w", also runs the produced binary. Listed in build.base.json's
# "generate".exclude so tools/wbuildgen.w never turns it into a real
# build.json target of its own -- its whole purpose is to be resolved
# ad hoc against the isolated fixture manifest.
import lib.lib

int main():
	print("direct file adhoc test ran")
	return 0
