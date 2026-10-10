# wbuild: tool=tools/wexec_main.w
# Executor sharding and timing are tested through the real CLI so its
# manifest validation, dependency scheduling and failure epilogues run.
import lib.testing
import lib.process
import lib.file
import lib.str
import lib.utf8
import structures.json
import tools.manifest_json


process_result* shard_run(list[char*] flags):
	char** argv = strv_new(flags.length + 3)
	strv_set(argv, 0, c"bin/wexec")
	strv_set(argv, 1, c"-f")
	strv_set(argv, 2, c"tests/wexec/shard.json")
	for i in range(flags.length): strv_set(argv, i + 3, flags[i])
	process_result* result = process_run(c"bin/wexec", argv, 0, 0, 30000)
	asserts(c"executor spawned", result != 0)
	return result


void test_shard_partition_and_shared_dependencies():
	process_result* a = shard_run(list[char*]{c"--list", c"--shard", c"0/2", c"suite", c"nested"})
	assert_equal(0, a.status)
	assert_strings_equal(c"alpha\ndelta\n", a.stdout_text)
	process_result_free(a)
	process_result* b = shard_run(list[char*]{c"--list", c"--shard", c"1/2", c"suite"})
	assert_equal(0, b.status)
	assert_strings_equal(c"beta\ngamma\n", b.stdout_text)
	process_result_free(b)
	process_result* r = shard_run(list[char*]{c"--shard", c"0/2", c"suite"})
	assert_equal(0, r.status)
	asserts(c"shared prerequisite runs", index_of(r.stdout_text, c"prepared") >= 0)
	asserts(c"first owned test runs", index_of(r.stdout_text, c"ran alpha") >= 0)
	asserts(c"second owned test runs", index_of(r.stdout_text, c"ran delta") >= 0)
	asserts(c"other shard beta excluded", index_of(r.stdout_text, c"ran beta") < 0)
	asserts(c"other shard gamma excluded", index_of(r.stdout_text, c"ran gamma") < 0)
	process_result_free(r)
	r = shard_run(list[char*]{c"--shard", c"7/8", c"suite"})
	assert_equal(0, r.status)
	asserts(c"empty shard does not run roots", index_of(r.stdout_text, c"ran ") < 0)
	process_result_free(r)


void test_shard_rejects_invalid_arguments_and_graphs():
	list[char*] invalid = list[char*]{c"0/0", c"2/2", c"-1/2", c"0/-2", c"1", c"/2", c"1/", c"0/2x", c"0/2/3", c"999999999999/2"}
	for char* spec in invalid:
		process_result* r = shard_run(list[char*]{c"--shard", spec, c"suite"})
		asserts(c"bad shard rejected", r.status != 0)
		asserts(c"diagnostic describes zero-based index", index_of(r.stderr_text, c"zero-based") >= 0)
		process_result_free(r)
	process_result* r = shard_run(list[char*]{c"--list", c"--shard", c"0/2", c"invalid_suite"})
	asserts(c"entire graph validated before selection", r.status != 0)
	asserts(c"missing dependency diagnosed", index_of(r.stderr_text, c"unknown target") >= 0)
	process_result_free(r)
	r = shard_run(list[char*]{c"--list", c"--shard", c"0/2", c"cycle"})
	asserts(c"cycle rejected before flattening", r.status != 0)
	process_result_free(r)
	r = shard_run(list[char*]{c"--list", c"--shard", c"0/2", c"invalid_steps"})
	asserts(c"malformed steps cannot silently disappear", r.status != 0)
	process_result_free(r)


json_value* shard_timing_row(char* path, char* name):
	list[char*] lines = file_read_lines(path)
	asserts(c"timing file readable", lines != 0)
	json_value* found = 0
	for char* line in lines:
		json_value* row = json_parse(line)
		asserts(c"each timing row is JSON", row != 0)
		char* target = jfield_string(row, c"target")
		if (target != 0 && strcmp(target, name) == 0):
			asserts(c"one timing row per target", found == 0)
			found = row
		else: json_free(row)
		free(line)
	asserts(c"target has timing row", found != 0)
	return found


void test_timings_measure_execution_cache_and_failure():
	char* path = cstr(f"bin/wexec_shard_timing_{getpid()}.jsonl")
	process_result* r = shard_run(list[char*]{c"--timings", path, c"alpha"})
	assert_equal(0, r.status)
	asserts(c"slowest targets summarized", index_of(r.stderr_text, c"slowest targets:") >= 0)
	process_result_free(r)
	json_value* row = shard_timing_row(path, c"alpha")
	asserts(c"timing measures real elapsed execution", jfield_int(row, c"elapsed_ms", -1) >= 40)
	assert_strings_equal(c"passed", jfield_string(row, c"status"))
	assert_strings_equal(c"none", jfield_string(row, c"cache"))
	json_free(row)
	r = shard_run(list[char*]{c"--no-cache", c"cached"})
	assert_equal(0, r.status)
	process_result_free(r)
	r = shard_run(list[char*]{c"--timings", path, c"cached"})
	assert_equal(0, r.status)
	process_result_free(r)
	row = shard_timing_row(path, c"cached")
	assert_strings_equal(c"local", jfield_string(row, c"cache"))
	json_free(row)
	r = shard_run(list[char*]{c"--keep-going", c"--timings", path, c"failure_suite"})
	asserts(c"failed suite still fails", r.status != 0)
	process_result_free(r)
	row = shard_timing_row(path, c"fails")
	assert_strings_equal(c"failed", jfield_string(row, c"status"))
	json_free(row)
	row = shard_timing_row(path, c"blocked")
	assert_strings_equal(c"skipped", jfield_string(row, c"status"))
	assert_equal(0, jfield_int(row, c"elapsed_ms", -1))
	json_free(row)
	row = shard_timing_row(path, c"delta")
	assert_strings_equal(c"passed", jfield_string(row, c"status"))
	json_free(row)
	r = shard_run(list[char*]{c"-j1", c"--timings", path, c"fails", c"delta"})
	asserts(c"fail-fast fails", r.status != 0)
	process_result_free(r)
	row = shard_timing_row(path, c"delta")
	assert_strings_equal(c"not_started", jfield_string(row, c"status"))
	json_free(row)
	unlink(path)


void test_shard_historical_cost_balancing():
	char* path = cstr(f"bin/wexec_shard_costs_{getpid()}.jsonl")
	assert_equal(1, file_write_text(path, c"{\"target\":\"alpha\",\"elapsed_ms\":9000,\"status\":\"passed\",\"cache\":\"none\"}\n{\"target\":\"beta\",\"elapsed_ms\":8000,\"status\":\"passed\",\"cache\":\"none\"}\n{\"target\":\"delta\",\"elapsed_ms\":2000,\"status\":\"passed\",\"cache\":\"none\"}\n{\"target\":\"alpha\",\"elapsed_ms\":1,\"status\":\"passed\",\"cache\":\"local\"}\n"))
	process_result* r = shard_run(list[char*]{c"--list", c"--shard", c"0/2", c"--shard-costs", path, c"suite"})
	assert_equal(0, r.status)
	assert_strings_equal(c"alpha\ngamma\n", r.stdout_text)
	process_result_free(r)
	r = shard_run(list[char*]{c"--list", c"--shard", c"1/2", c"--shard-costs", path, c"suite"})
	assert_equal(0, r.status)
	assert_strings_equal(c"beta\ndelta\n", r.stdout_text)
	process_result_free(r)
	unlink(path)
