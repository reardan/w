# wbuild: tool=tools/wcoverage.w deps=tests/wcoverage/line_fixture.w deps=tests/wcoverage/advanced_fixture.w deps=tests/wcoverage/fstring_fixture.w deps=tests/wcoverage/diag_fixture.w deps=tests/wcoverage/changed_fixture.w deps=tests/wcoverage/exec_probe.w deps=tests/wcoverage/changed_fixture.diff deps=tests/wcoverage/baseline_pass.txt deps=tests/wcoverage/baseline_fail.txt
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
# wbuild: step="bin/wv2 wasm --coverage tests/wcoverage/line_fixture.w -o bin/coverage_unsupported" expect_fail expect_stderr="only supported on the x86, x64 and arm64 Linux targets"
# wbuild: step="bin/wv2 arm64_darwin --profile-generate tests/wcoverage/line_fixture.w -o bin/coverage_unsupported" expect_fail expect_stderr="only supported on the x86, x64 and arm64 Linux targets"
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
# wbuild: step="bin/wcoverage lines --branches --file tests/wcoverage/line_fixture.w bin/coverage_fixture.wprofmap bin/coverage_first.raw" expect_stdout="line_fixture.w:7: taken hit, not taken miss" expect_stdout="line_fixture.w:9: taken miss, not taken miss" expect_stdout="line_fixture.w:20: taken miss, not taken hit" expect_stdout="branch coverage: 2/6 (33%)" reject_stdout="line_fixture.w:16:"
# wbuild: step="bin/wcoverage lines --branches --file tests/wcoverage/line_fixture.w bin/coverage_fixture.wprofmap bin/coverage_first.raw bin/coverage_fixture_streaming.wprofmap bin/coverage_second.raw" expect_stdout="line_fixture.w:7: taken hit, not taken hit" expect_stdout="line_fixture.w:9: taken hit, not taken miss" expect_stdout="line_fixture.w:20: taken hit, not taken hit" expect_stdout="branch coverage: 5/6 (83%)"
# wbuild: step="bin/wcoverage lines --uncovered-only --file tests/wcoverage/line_fixture.w bin/coverage_fixture.wprofmap bin/coverage_first.raw" expect_stdout="line_fixture.w:4: miss" reject_stdout=": hit" expect_stdout="line coverage: 8/14 (57%)"
# wbuild: step="bin/wcoverage lines --summary file --prefix tests/wcoverage/ bin/coverage_fixture.wprofmap bin/coverage_first.raw" expect_stdout="57.1%       8/14        33.3%     2/6      tests/wcoverage/line_fixture.w"
# wbuild: step="bin/wcoverage lines --summary dir --prefix tests/ bin/coverage_fixture.wprofmap bin/coverage_first.raw" expect_stdout="tests/" reject_stdout="lib/"
# wbuild: step="bin/wcoverage lines --summary function --file tests/wcoverage/line_fixture.w bin/coverage_fixture.wprofmap bin/coverage_first.raw" expect_stdout="0.0%       0/1       tests/wcoverage/line_fixture.w:3: coverage_unused" expect_stdout="function coverage: 2/3 (66%)"
# wbuild: step="bin/wcoverage lines --summary function --uncovered-only --file tests/wcoverage/line_fixture.w bin/coverage_fixture.wprofmap bin/coverage_first.raw" expect_stdout="line_fixture.w:3: coverage_unused" reject_stdout="coverage_choose"
# wbuild: step="bin/wcoverage lines --format lcov --file tests/wcoverage/line_fixture.w bin/coverage_fixture.wprofmap bin/coverage_first.raw" expect_stdout="SF:tests/wcoverage/line_fixture.w" expect_stdout="FN:3,coverage_unused" expect_stdout="FNDA:0,coverage_unused" expect_stdout="FNH:2" expect_stdout="BRDA:20,0,1,1" expect_stdout="BRF:6" expect_stdout="DA:4,0" expect_stdout="DA:8,1" expect_stdout="LF:14" expect_stdout="LH:8" expect_stdout="end_of_record" reject_stdout="line coverage"
# wbuild: step="bin/wcoverage lines --format json --file tests/wcoverage/line_fixture.w bin/coverage_fixture.wprofmap bin/coverage_first.raw" expect_stdout="{\"file\": \"tests/wcoverage/line_fixture.w\", \"lines\": 14, \"hit\": 8, \"branches\": 6, \"branches_hit\": 2, \"missed\": [4, 9, 10, 12, 19, 21]}"
# wbuild: step="bin/wcoverage lines --baseline tests/wcoverage/baseline_pass.txt --file tests/wcoverage/line_fixture.w bin/coverage_fixture.wprofmap bin/coverage_first.raw" expect_stdout="baseline: ok tests/wcoverage/ 57.1% (floor 50.0%)" expect_stdout="baseline: ok branches:tests/wcoverage/ 33.3% (floor 30%)"
# wbuild: step="bin/wcoverage lines --baseline tests/wcoverage/baseline_fail.txt --file tests/wcoverage/line_fixture.w bin/coverage_fixture.wprofmap bin/coverage_first.raw" expect_fail expect_stdout="baseline: FAIL tests/wcoverage/ 57.1% is below its floor 90.5%"
# wbuild: step="bin/wcoverage lines --summary nope bin/coverage_fixture.wprofmap bin/coverage_first.raw" expect_fail expect_stderr="--summary takes file, dir or function"
# wbuild: step="bin/wv2 --coverage tests/wcoverage/diag_fixture.w -o bin/coverage_diag"
# wbuild: step="bin/coverage_diag" env="W_PROFILE_OUT=bin/coverage_dumps/diag.raw" expect_stderr="seven"
# wbuild: step="bin/wcoverage lines --diagnostics --file tests/wcoverage/diag_fixture.w bin/coverage_diag.wprofmap bin/coverage_dumps" expect_stdout="diag_fixture.w:13: miss: if (value < 0): fixture_error(c\"negative\")" expect_stdout="diag_fixture.w:15: miss" expect_stdout="diag_fixture.w:16: hit" reject_stdout="diag_fixture.w:3:" reject_stdout="diag_fixture.w:17:" reject_stdout="diag_fixture.w:18:" expect_stdout="diagnostic coverage: 1/3 (33%)"
# wbuild: step="bin/wcoverage lines --diagnostics --uncovered-only --file tests/wcoverage/diag_fixture.w bin/coverage_diag.wprofmap bin/coverage_dumps" reject_stdout=": hit:" expect_stdout="diag_fixture.w:13: miss"
# wbuild: step="bin/wv2 --coverage tests/wcoverage/changed_fixture.w -o bin/coverage_changed"
# wbuild: step="bin/coverage_changed" env="W_PROFILE_OUT=bin/coverage_changed.raw"
# wbuild: step="bin/wcoverage lines --format lcov --file tests/wcoverage/changed_fixture.w bin/coverage_changed.wprofmap bin/coverage_changed.raw" stdout_file=bin/coverage_changed.info
# wbuild: step="bin/wcoverage changed --prefix tests/wcoverage/ tests/wcoverage/changed_fixture.diff bin/coverage_changed.info" expect_fail expect_stdout="changed_fixture.w:4: changed line not reached by any test" expect_stdout="changed_fixture.w:14: changed line not reached" expect_stdout="reached: 3/5 (60%), minimum 80%" reject_stdout="changed_fixture.w:8:"
# wbuild: step="bin/wcoverage changed --min 60 --prefix tests/wcoverage/ tests/wcoverage/changed_fixture.diff bin/coverage_changed.info" expect_stdout="reached: 3/5 (60%), minimum 60%"
# wbuild: step="bin/wv2 tests/wcoverage/exec_probe.w -o bin/coverage_exec_probe"
# wbuild: step="bin/wv2 a b" env="W_COVERAGE_COMPILER=bin/coverage_exec_probe" env="W_COVERAGE_OUT=bin/coverage_probe" expect_stdout="argv: bin/wv2 a b" expect_stdout="W_COVERAGE_COMPILER=[]" expect_stdout="W_PROFILE_OUT=[bin/coverage_probe/compiler_x86/"
# wbuild: step="bin/wv2 --version" env="W_COVERAGE_COMPILER=bin/coverage_exec_probe" env="W_PROFILE_OUT=bin/coverage_probe_guard.raw" expect_stdout="w 0.3.0" reject_stdout="argv:"
# wbuild: step="bin/wv2 --version" env="W_COVERAGE_COMPILER=bin/coverage_no_such_build" expect_fail expect_stderr="cannot execute coverage build 'bin/coverage_no_such_build' named by $W_COVERAGE_COMPILER"
# wbuild: target=coverage_arm64_test tag=tests_arm64 dep=wv2 dep=wrun dep=wcoverage input=tests/wcoverage/line_fixture.w input=tests/wcoverage/fstring_fixture.w
# wbuild: step="bin/wv2 arm64 --coverage tests/wcoverage/line_fixture.w -o bin/coverage_fixture_arm64"
# wbuild: step="bin/wv2 arm64 --coverage --streaming tests/wcoverage/line_fixture.w -o bin/coverage_fixture_arm64_streaming"
# wbuild: step="cmp bin/coverage_fixture_arm64 bin/coverage_fixture_arm64_streaming"
# wbuild: step="cmp bin/coverage_fixture_arm64.wprofmap bin/coverage_fixture_arm64_streaming.wprofmap"
# wbuild: step="rm -f bin/coverage_arm64_first.raw bin/coverage_arm64_alt.raw bin/coverage_fstring_arm64.raw"
# wbuild: step="bin/wrun arm64 bin/coverage_fixture_arm64" env="W_PROFILE_OUT=bin/coverage_arm64_first.raw"
# wbuild: step="bin/wcoverage lines --branches --file tests/wcoverage/line_fixture.w bin/coverage_fixture_arm64.wprofmap bin/coverage_arm64_first.raw" expect_stdout="line_fixture.w:7: taken hit, not taken miss" expect_stdout="line_fixture.w:20: taken miss, not taken hit" expect_stdout="line coverage: 8/14 (57%)" expect_stdout="branch coverage: 2/6 (33%)"
# wbuild: step="bin/wrun arm64 bin/coverage_fixture_arm64 alt" env="W_PROFILE_OUT=bin/coverage_arm64_alt.raw"
# wbuild: step="bin/wcoverage lines --file tests/wcoverage/line_fixture.w bin/coverage_fixture_arm64.wprofmap bin/coverage_arm64_alt.raw" expect_stdout="line_fixture.w:21: hit" expect_stdout="line_fixture.w:22: miss" expect_stdout="line coverage: 9/14 (64%)"
# wbuild: step="bin/wv2 arm64 --coverage tests/wcoverage/fstring_fixture.w -o bin/coverage_fstring_arm64"
# wbuild: step="bin/wrun arm64 bin/coverage_fstring_arm64 alt" env="W_PROFILE_OUT=bin/coverage_fstring_arm64.raw" expect_stdout="a_4 in4{}    5w" expect_stdout="args_2"
# wbuild: step="bin/wcoverage lines --file tests/wcoverage/fstring_fixture.w bin/coverage_fstring_arm64.wprofmap bin/coverage_fstring_arm64.raw" expect_stdout="fstring_fixture.w:16: hit"
import lib.testing
import lib.file
import lib.dir
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
	file_write_text(c"bin/coverage_changed.raw", c"")
	dir_remove_all(c"bin/coverage_dumps")
	mkdir(c"bin/coverage_dumps", 493)
	file_write_text(c"bin/coverage_bad.raw", c"2147483647 1\n")
	file_write_text(c"bin/coverage_negative.raw", c"0 -1\n")
	file_write_text(c"bin/coverage_malformed.wprofmap", c"# wprofmap v1\tx86\t1\n1\ts\thash\tname\tfile.w\t3\t0\n")
	unlink(c"bin/coverage_missing.raw")
