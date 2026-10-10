# wbuild: tool=tools/wcoverage.w
# wbuild: step="bin/wcoverage suite --out bin/coverage_suite_good --merge-shards 2 --prefix tests/wcoverage/" expect_stdout="line coverage: 2/2 (100%)" expect_stdout="branch coverage: 2/2 (100%)"
# wbuild: step="cat bin/coverage_suite_good/diagnostics.txt" expect_stdout="diag_fixture.w:15: hit"
# wbuild: step="cat bin/coverage_suite_good/lcov.info" expect_stdout="BRH:2" expect_stdout="LH:2"
# wbuild: step="bin/wcoverage suite --out bin/coverage_suite_failed --merge-shards 2 --prefix tests/wcoverage/" expect_fail expect_stderr="shard 1/2 failed" expect_stderr="INCOMPLETE" expect_stdout="line coverage: 2/2 (100%)"
# wbuild: step="bin/wcoverage suite --out bin/coverage_suite_missing --merge-shards 2 --prefix tests/wcoverage/" expect_fail expect_stderr="missing or incomplete run"
# wbuild: step="test ! -e bin/coverage_suite_missing/lcov.info"
# wbuild: step="cat bin/coverage_suite_missing/completeness.txt" expect_stdout="INCOMPLETE: missing or incomplete run"
# wbuild: step="bin/wcoverage suite --out bin/coverage_suite_mismatch --merge-shards 2 --prefix tests/wcoverage/" expect_fail expect_stderr="coverage map does not match preparation"
# wbuild: step="bin/wcoverage suite --out bin/coverage_suite_identity --merge-shards 2 --prefix tests/wcoverage/" expect_fail expect_stderr="preparation identity does not match"
# wbuild: step="bin/wcoverage suite --out bin/coverage_suite_targets --merge-shards 2 --prefix tests/wcoverage/" expect_fail expect_stderr="run identity or targets do not match"
# wbuild: step="bin/wcoverage suite --out bin/coverage_suite_local --no-run --prefix tests/wcoverage/" expect_fail expect_stdout="line coverage: 2/2 (100%)" expect_stderr="INCOMPLETE"
# wbuild: step="bin/wcoverage suite --shard 2/2" expect_fail expect_stderr="0 <= I < N"
# wbuild: step="bin/wcoverage suite --shard 0/2 --baseline tools/coverage_baseline.txt" expect_fail expect_stderr="apply baseline after --merge-shards"
import lib.testing
import tools.wcoverage_suite


char* suite_test_map():
	return c"# wprofmap v1\tx86\t4\n0\tf\thash\tcheck\ttests/wcoverage/diag_fixture.w\t12\t0\n1\ts\thash\tcheck\ttests/wcoverage/diag_fixture.w\t14\t1\n2\ts\thash\tcheck\ttests/wcoverage/diag_fixture.w\t15\t0\n3\ts\thash\tcheck\ttests/wcoverage/diag_fixture.w\t14\t0\n"


void suite_test_artifacts(char* dir, int dumps):
	mkdir(dir, 493)
	mkdir(f"{dir}/.dumps", 493)
	wcov_suite_save(f"{dir}/preparation.id", c"coverage-suite-test\n")
	for wcov_suite_build* b in wcov_suite_builds(dir):
		wcov_suite_save(strjoin(b.binary, c".wprofmap"), suite_test_map())
		mkdir(b.dumps, 493)
		# Same PID in each artifact; the two complementary runs must both
		# survive collection. An empty architecture still contributes its map.
		if ((dumps != 0) && (b.x64 == 0)):
			char* raw = c"0 1\n1 1\n2 1\n3 1\n"
			if (dumps == 2): raw = c"0 1\n1 1\n3 1\n"
			wcov_suite_save(f"{b.dumps}/42.raw", raw)


void test_suite_artifact_fixtures():
	for char* name in split(c"good failed missing mismatch identity targets", ' '):
		char* out = f"bin/coverage_suite_{name}"
		dir_remove_all(out)
		suite_test_artifacts(out, 0)
		mkdir(f"{out}/shards", 493)
		for i in range(2):
			char* dir = f"{out}/shards/{i}-of-2"
			suite_test_artifacts(dir, i + 1)
			int status = 0
			if ((strcmp(name, c"failed") == 0) && (i == 1)): status = 1
			wcov_suite_save(f"{dir}/run.status", f"wcoverage suite v1\n{i}/2\ntests\n{status}\n")
		char* last = f"{out}/shards/1-of-2"
		if (strcmp(name, c"missing") == 0):
			unlink(f"{last}/run.status")
			wcov_suite_save(f"{out}/lcov.info", c"stale successful coverage report\n")
		if (strcmp(name, c"mismatch") == 0): wcov_suite_save(f"{last}/compiler_x86_cov.wprofmap", c"wrong map\n")
		if (strcmp(name, c"identity") == 0): wcov_suite_save(f"{last}/preparation.id", c"other preparation\n")
		if (strcmp(name, c"targets") == 0): wcov_suite_save(f"{last}/run.status", c"wcoverage suite v1\n1/2\nother_tests\n0\n")
	char* out = c"bin/coverage_suite_local"
	dir_remove_all(out)
	suite_test_artifacts(out, 1)
	wcov_suite_save(f"{out}/run.status", c"wcoverage suite v1\nlocal\ntests\n7\n")
