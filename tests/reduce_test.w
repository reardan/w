# Regression coverage for the public compiler command and predicate contract.
# wbuild: expect_stdout="reduce tests passed"
import lib.file
import lib.process
import lib.assert
import lib.str


process_result* reduce_test_run(char** args, int timeout):
	spawn_options* opts = spawn_options_new()
	opts.new_group = 1
	process_result* result = process_run(args[0], args, opts, 0, timeout)
	free(opts)
	return result


int reduce_test_predicate(char* mode, char* candidate):
	if (strcmp(mode, c"reject") == 0): return 1
	if (strcmp(mode, c"accept") == 0): return 0
	if (strcmp(mode, c"sleep") == 0):
		process_sleep_ms(2000)
		return 0
	char** args = strv_new(5)
	args[0] = c"bin/wv2"
	if (strcmp(mode, c"diagnostic") == 0):
		args[1] = c"check"
		args[2] = candidate
	else:
		args[1] = candidate
		args[2] = c"-o"
		args[3] = c"bin/reduce_predicate_program"
	process_result* compiled = reduce_test_run(args, 5000)
	int ok = 0
	if (strcmp(mode, c"diagnostic") == 0):
		ok = (compiled.status > 0) && (contains(compiled.stderr_text, c"reduce_missing") != 0)
	else if (compiled.status == 0):
		char** run_args = strv_new(1)
		run_args[0] = c"bin/reduce_predicate_program"
		process_result* ran = reduce_test_run(run_args, 1000)
		ok = ran.status == 7
		process_result_free(ran)
		free(cast(char*, run_args))
	process_result_free(compiled)
	free(cast(char*, args))
	if (ok): return 0
	return 1


process_result* reduce_test_command(char* self, char* input, char* output, char* mode, char* limit, char* timeout, int placeholder):
	char** args = strv_new(15)
	args[0] = c"bin/wv2"
	args[1] = c"reduce"
	args[2] = input
	args[3] = c"-o"
	args[4] = output
	args[5] = c"--max-tests"
	args[6] = limit
	args[7] = c"--timeout-ms"
	args[8] = timeout
	args[9] = c"--"
	args[10] = self
	args[11] = c"--predicate"
	args[12] = mode
	if (placeholder): args[13] = c"{}"
	process_result* result = reduce_test_run(args, 30000)
	free(cast(char*, args))
	return result


int main(int argc, int argv):
	char** args = cast(char**, argv)
	if ((argc == 4) && (strcmp(args[1], c"--predicate") == 0)):
		return reduce_test_predicate(args[2], args[3])
	char* input = c"bin/reduce input.w"
	char* output = c"bin/reduce output.w"
	char* original = c"import reduce_helper\n\nint unused():\n\treturn 99\n\nint main():\n\tint unused_local = 1\n\tif (0):\n\t\treturn 17\n\treturn reduce_answer()\n"
	assert1(file_write_text(c"bin/reduce_helper.w", c"int reduce_answer():\n\treturn 7\n"))
	assert1(file_write_text(input, original))
	unlink(output)
	process_result* result = reduce_test_command(args[0], input, output, c"runtime", c"200", c"5000", 1)
	if (result.status != 0): println2(result.stderr_text)
	assert_equal(0, result.status)
	process_result_free(result)
	char* reduced = file_read_text(output)
	assert1(reduced != 0)
	assert1(strlen(reduced) < strlen(original))
	assert1(contains(reduced, c"unused") == 0)
	assert1(contains(reduced, c"return 17") == 0)
	assert_equal(0, reduce_test_predicate(c"runtime", output))
	char* unchanged = file_read_text(input)
	assert_strings_equal(original, unchanged)
	free(unchanged)
	free(reduced)

	# Existing destination and input-as-destination must never be truncated.
	result = reduce_test_command(args[0], input, input, c"runtime", c"1", c"5000", 1)
	assert1(result.status != 0)
	process_result_free(result)
	unchanged = file_read_text(input)
	assert_strings_equal(original, unchanged)
	free(unchanged)
	assert1(file_write_text(output, c"sentinel"))
	result = reduce_test_command(args[0], input, output, c"runtime", c"1", c"5000", 1)
	assert1(result.status != 0)
	process_result_free(result)
	unchanged = file_read_text(output)
	assert_strings_equal(c"sentinel", unchanged)
	free(unchanged)

	# Predicate failure and timeout reject the original and create no output.
	unlink(output)
	result = reduce_test_command(args[0], input, output, c"reject", c"20", c"5000", 0)
	assert1(result.status != 0)
	assert1(contains(result.stderr_text, c"initial predicate") != 0)
	assert_equal(0, process_path_readable(output))
	process_result_free(result)
	result = reduce_test_command(args[0], input, output, c"sleep", c"20", c"20", 0)
	assert1(result.status != 0)
	assert1(contains(result.stderr_text, c"timed out") != 0)
	assert_equal(0, process_path_readable(output))
	process_result_free(result)

	# The initial predicate consumes the budget; save the original best.
	result = reduce_test_command(args[0], input, output, c"runtime", c"1", c"5000", 0)
	assert_equal(0, result.status)
	assert1(contains(result.stdout_text, c"test limit reached") != 0)
	process_result_free(result)
	unchanged = file_read_text(output)
	assert_strings_equal(original, unchanged)
	free(unchanged)

	# Invalid source remains eligible: syntax validity is the predicate's job.
	char* diagnostic = c"int unused():\n\treturn 5\n\nint main():\n\treturn reduce_missing\n"
	assert1(file_write_text(input, diagnostic))
	unlink(output)
	result = reduce_test_command(args[0], input, output, c"diagnostic", c"100", c"5000", 0)
	if (result.status != 0): println2(result.stderr_text)
	assert_equal(0, result.status)
	process_result_free(result)
	reduced = file_read_text(output)
	assert1(strlen(reduced) < strlen(diagnostic))
	assert1(contains(reduced, c"unused") == 0)
	assert_equal(0, reduce_test_predicate(c"diagnostic", output))
	free(reduced)

	# Byte retention includes CRLF and an unterminated final line.
	char* exact = c"# noise\r\nint main():\r\n\treturn 0"
	assert1(file_write_text(input, exact))
	unlink(output)
	result = reduce_test_command(args[0], input, output, c"accept", c"1", c"5000", 0)
	assert_equal(0, result.status)
	process_result_free(result)
	unchanged = file_read_text(output)
	assert_strings_equal(exact, unchanged)
	free(unchanged)
	unlink(output)
	result = reduce_test_command(args[0], input, output, c"accept", c"100", c"5000", 0)
	assert_equal(0, result.status)
	process_result_free(result)
	reduced = file_read_text(output)
	assert_strings_equal(c"", reduced)
	free(reduced)

	# Text input must not silently lose an embedded NUL and its suffix.
	io_result written
	assert_equal(IO_OK, file_write_text_checked(input, c"a\0b", 3, &written))
	unlink(output)
	result = reduce_test_command(args[0], input, output, c"accept", c"100", c"5000", 0)
	assert1(result.status != 0)
	assert1(contains(result.stderr_text, c"embedded NUL"))
	assert_equal(0, process_path_readable(output))
	process_result_free(result)

	# Command lookup failure is an error, not an interesting program.
	assert1(file_write_text(input, exact))
	result = reduce_test_command(c"w_reduce_nonexistent_predicate_717", input, output, c"accept", c"10", c"5000", 0)
	assert1(result.status != 0)
	assert1(contains(result.stderr_text, c"command not found"))
	assert_equal(0, process_path_readable(output))
	process_result_free(result)
	unlink(input)
	unlink(output)
	unlink(c"bin/reduce_helper.w")
	unlink(c"bin/reduce_predicate_program")
	println(c"reduce tests passed")
	return 0
