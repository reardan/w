# wbuild: tool=tools/wcoverage.w deps=tests/wcoverage/line_fixture.w deps=tests/wcoverage/advanced_fixture.w deps=tests/wcoverage/fstring_fixture.w
# wbuild: step="bin/wv2 --coverage tests/wcoverage/line_fixture.w -o bin/coverage_fixture"
# wbuild: step="bin/wv2 --coverage --streaming tests/wcoverage/line_fixture.w -o bin/coverage_fixture_streaming"
# wbuild: step="cmp bin/coverage_fixture bin/coverage_fixture_streaming"
# wbuild: step="cmp bin/coverage_fixture.wprofmap bin/coverage_fixture_streaming.wprofmap"
# wbuild: step="bin/coverage_fixture" env="W_PROFILE_OUT=bin/coverage_first.raw"
# wbuild: step="bin/wcoverage lines --file tests/wcoverage/line_fixture.w bin/coverage_fixture.wprofmap bin/coverage_first.raw" expect_stdout="line_fixture.w:4: miss" expect_stdout="line_fixture.w:8: hit" expect_stdout="line_fixture.w:9: miss" expect_stdout="line_fixture.w:19: miss" expect_stdout="line_fixture.w:21: miss" expect_stdout="line_fixture.w:22: hit" expect_stdout="line coverage: 8/14 (57%)" reject_stdout="line_fixture.w:3:"
# wbuild: step="bin/coverage_fixture_streaming alt" env="W_PROFILE_OUT=bin/coverage_second.raw"
# wbuild: step="bin/wcoverage lines --file tests/wcoverage/line_fixture.w bin/coverage_fixture_streaming.wprofmap bin/coverage_second.raw" expect_stdout="line_fixture.w:8: miss" expect_stdout="line_fixture.w:9: hit" expect_stdout="line_fixture.w:10: hit" expect_stdout="line_fixture.w:21: hit" expect_stdout="line_fixture.w:22: miss" expect_stdout="line coverage: 9/14 (64%)"
# wbuild: step="bin/wv2 x64 --coverage tests/wcoverage/line_fixture.w -o bin/coverage_fixture_x64"
# wbuild: step="bin/coverage_fixture_x64 alt" env="W_PROFILE_OUT=bin/coverage_x64.raw"
# wbuild: step="bin/wcoverage lines --file tests/wcoverage/line_fixture.w bin/coverage_fixture.wprofmap bin/coverage_first.raw bin/coverage_fixture_x64.wprofmap bin/coverage_x64.raw" expect_stdout="line_fixture.w:8: hit" expect_stdout="line_fixture.w:9: hit" expect_stdout="line_fixture.w:12: miss" expect_stdout="line_fixture.w:21: hit" expect_stdout="line coverage: 11/14 (78%)"
# wbuild: step="bin/wcoverage lines --file tests/wcoverage/line_fixture.w bin/coverage_fixture.wprofmap bin/coverage_empty.raw" expect_stdout="line coverage: 0/14 (0%)" reject_stdout=": hit"
# wbuild: step="bin/wcoverage lines bin/coverage_fixture.wprofmap" expect_fail expect_stderr="each map requires a dump"
# wbuild: step="bin/wcoverage lines bin/coverage_fixture.wprofmap bin/coverage_bad.raw" expect_fail expect_stderr="dump index outside map"
# wbuild: step="bin/wcoverage lines bin/coverage_fixture.wprofmap bin/coverage_negative.raw" expect_fail expect_stderr="invalid decimal field"
# wbuild: step="bin/wcoverage lines bin/coverage_fixture.wprofmap bin/coverage_missing.raw" expect_fail expect_stderr="cannot read dump"
# wbuild: step="bin/wcoverage lines --file absent.w bin/coverage_fixture.wprofmap bin/coverage_empty.raw" expect_fail expect_stderr="no executable lines matched"
# wbuild: step="bin/wcoverage lines bin/coverage_malformed.wprofmap bin/coverage_empty.raw" expect_fail expect_stderr="map indices must be consecutive"
# wbuild: step="bin/wv2 --profile-generate tests/wcoverage/line_fixture.w -o bin/coverage_profile_only"
# wbuild: step="bin/wcoverage lines bin/coverage_profile_only.wprofmap bin/coverage_empty.raw" expect_fail expect_stderr="compile with --coverage"
# wbuild: step="bin/wv2 arm64 --coverage tests/wcoverage/line_fixture.w -o bin/coverage_unsupported" expect_fail expect_stderr="only supported on the x86 and x64 Linux targets"
# wbuild: step="bin/wv2 --coverage tests/wcoverage/line_fixture.w" expect_fail expect_stderr="requires -o"
# wbuild: step="bin/wv2 --coverage tests/wcoverage/advanced_fixture.w -o bin/coverage_advanced"
# wbuild: step="bin/wv2 --coverage --streaming tests/wcoverage/advanced_fixture.w -o bin/coverage_advanced_streaming"
# wbuild: step="cmp bin/coverage_advanced bin/coverage_advanced_streaming"
# wbuild: step="cmp bin/coverage_advanced.wprofmap bin/coverage_advanced_streaming.wprofmap"
# wbuild: step="bin/coverage_advanced" env="W_PROFILE_OUT=bin/coverage_advanced.raw"
# wbuild: step="bin/wcoverage lines --file tests/wcoverage/advanced_fixture.w bin/coverage_advanced.wprofmap bin/coverage_advanced.raw" expect_stdout="advanced_fixture.w:10: hit" expect_stdout="advanced_fixture.w:13: hit" expect_stdout="advanced_fixture.w:15: miss" expect_stdout="advanced_fixture.w:18: hit" expect_stdout="advanced_fixture.w:19: hit" expect_stdout="advanced_fixture.w:22: hit" reject_stdout="advanced_fixture.w:28:" expect_stdout="line coverage: 13/14 (92%)"
# wbuild: step="bin/wv2 --coverage tests/wcoverage/fstring_fixture.w -o bin/coverage_fstring"
# wbuild: step="bin/wv2 --coverage --streaming tests/wcoverage/fstring_fixture.w -o bin/coverage_fstring_streaming"
# wbuild: step="cmp bin/coverage_fstring bin/coverage_fstring_streaming"
# wbuild: step="cmp bin/coverage_fstring.wprofmap bin/coverage_fstring_streaming.wprofmap"
# wbuild: step="bin/coverage_fstring" env="W_PROFILE_OUT=bin/coverage_fstring.raw" expect_stdout="a_3 in3{}    4w" expect_stdout="big_3"
# wbuild: step="bin/wcoverage lines --file tests/wcoverage/fstring_fixture.w bin/coverage_fstring.wprofmap bin/coverage_fstring.raw" expect_stdout="fstring_fixture.w:6: hit" expect_stdout="fstring_fixture.w:7: miss" expect_stdout="fstring_fixture.w:13: hit" expect_stdout="fstring_fixture.w:16: miss" expect_stdout="line coverage: 8/10 (80%)"
# wbuild: step="bin/wv2 x64 --coverage tests/wcoverage/fstring_fixture.w -o bin/coverage_fstring_x64"
# wbuild: step="bin/coverage_fstring_x64 alt" env="W_PROFILE_OUT=bin/coverage_fstring_x64.raw" expect_stdout="args_2"
# wbuild: step="bin/wv2 --profile-generate tests/wcoverage/fstring_fixture.w -o bin/coverage_fstring_profile"
# wbuild: step="bin/wv2 defhash tests/wcoverage/fstring_fixture.w" expect_stdout="\"name\": \"label\"" expect_stdout="\"refs\": [\"label\"]"
import lib.testing
import lib.file
import tools.wcoverage_lines


void test_coverage_decimal_counts():
	assert_equal(0, wcov_decimal_nonzero(c"000"))
	assert_equal(1, wcov_decimal_nonzero(c"18446744073709551615"))
	assert_equal(2147483647, wcov_small_decimal(c"2147483647"))


# Start each regression run with fresh dumps: the runtime appends so
# several invocations of one binary can intentionally share a dump.
void test_coverage_prepare_runs():
	file_write_text(c"bin/coverage_advanced.raw", c"")
	file_write_text(c"bin/coverage_first.raw", c"")
	file_write_text(c"bin/coverage_second.raw", c"")
	file_write_text(c"bin/coverage_x64.raw", c"")
	file_write_text(c"bin/coverage_empty.raw", c"")
	file_write_text(c"bin/coverage_fstring.raw", c"")
	file_write_text(c"bin/coverage_fstring_x64.raw", c"")
	file_write_text(c"bin/coverage_bad.raw", c"2147483647 1\n")
	file_write_text(c"bin/coverage_negative.raw", c"0 -1\n")
	file_write_text(c"bin/coverage_malformed.wprofmap", c"# wprofmap v1\tx86\t1\n1\ts\thash\tname\tfile.w\t3\t0\n")
	unlink(c"bin/coverage_missing.raw")
