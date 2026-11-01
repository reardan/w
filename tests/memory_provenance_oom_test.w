# wbuild: x64 deps=tests/memory_provenance_oom_fixture.w
import lib.assert
import lib.process
import lib.str


int main():
	char* binary = c"bin/memory_provenance_oom32"
	if (__word_size__ == 8): binary = c"bin/memory_provenance_oom64"
	char** args = strv_new(7)
	strv_set(args, 0, c"bin/wv2")
	int at = 1
	if (__word_size__ == 8):
		strv_set(args, at, c"x64")
		at += 1
	strv_set(args, at, c"--strict")
	strv_set(args, at + 1, c"tests/memory_provenance_oom_fixture.w")
	strv_set(args, at + 2, c"-o")
	strv_set(args, at + 3, binary)
	process_result* built = process_run(args[0], args, 0, 0, 60000)
	asserts(c"OOM fixture compiled", built != 0)
	assert_equal(0, built.status)
	process_result_free(built)
	free(cast(void*, args))
	for locked in range(2):
		args = strv_new(3)
		strv_set(args, 0, binary)
		if (locked): strv_set(args, 1, c"locked")
		process_result* result = process_run(binary, args, 0, 0, 5000)
		asserts(c"OOM fixture started", result != 0)
		assert_equal(1, result.status)
		assert_equal(0, result.stdout_length)
		assert_equal(0, strcmp(c"foreign provenance: bookkeeping allocation failed\n", result.stderr_text))
		process_result_free(result)
		free(cast(void*, args))
	return 0
