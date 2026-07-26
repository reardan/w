# wbuild: x64
/*
process_run_bytes takes stdin's byte count explicitly, so subprocess
input containing embedded NUL bytes reaches the child in full
(docs/projects/ai_tooling_next_steps.md); process_run keeps its legacy
strlen contract and truncates its write at the first NUL. Both are
asserted here by echoing stdin back through /bin/cat, including a
payload larger than the 4096-byte pipe write chunk.
*/
import lib.testing
import lib.process


char** cat_argv():
	char** argv = strv_new(1)
	strv_set(argv, 0, c"/bin/cat")
	return argv


process_result* run_cat_bytes(char* stdin_text, int stdin_length):
	char** argv = cat_argv()
	process_result* r = process_run_bytes(c"/bin/cat", argv, 0, stdin_text, stdin_length, 10000)
	assert1(r != 0)
	free(cast(void*, argv))
	return r


# "ab\0cd": strlen sees 2 bytes, the buffer holds 5.
char* nul_payload():
	char* payload = malloc(6)
	payload[0] = 'a'
	payload[1] = 'b'
	payload[2] = 0
	payload[3] = 'c'
	payload[4] = 'd'
	payload[5] = 0
	return payload


void test_embedded_nul_reaches_child():
	char* payload = nul_payload()
	process_result* r = run_cat_bytes(payload, 5)
	assert_equal(0, r.status)
	assert_equal(5, r.stdout_length)
	int i = 0
	while (i < 5):
		assert_equal(payload[i] & 255, r.stdout_text[i] & 255)
		i = i + 1
	assert_equal(0, r.stderr_length)
	process_result_free(r)
	free(payload)


void test_process_run_still_truncates_at_nul():
	char* payload = nul_payload()
	char** argv = cat_argv()
	process_result* r = process_run(c"/bin/cat", argv, 0, payload, 10000)
	assert1(r != 0)
	assert_equal(0, r.status)
	assert_equal(2, r.stdout_length)
	assert_equal('a', r.stdout_text[0] & 255)
	assert_equal('b', r.stdout_text[1] & 255)
	process_result_free(r)
	free(cast(void*, argv))
	free(payload)


void test_large_nul_payload_round_trips():
	# Crosses the 4096-byte PIPE_BUF write chunk; every 96th byte is 0x00
	# and every value stays below 128 (char loads sign-extend).
	int length = 10000
	char* payload = malloc(length)
	int i = 0
	while (i < length):
		payload[i] = i % 96
		i = i + 1
	process_result* r = run_cat_bytes(payload, length)
	assert_equal(0, r.status)
	assert_equal(length, r.stdout_length)
	i = 0
	while (i < length):
		assert_equal(i % 96, r.stdout_text[i] & 255)
		i = i + 1
	process_result_free(r)
	free(payload)


void test_null_and_empty_stdin():
	# stdin_text 0 closes the pipe up front, like process_run.
	process_result* r = run_cat_bytes(0, 0)
	assert_equal(0, r.status)
	assert_equal(0, r.stdout_length)
	process_result_free(r)
	# The length governs, not strlen: a non-empty buffer with length 0
	# delivers empty stdin.
	process_result* r2 = run_cat_bytes(c"ignored", 0)
	assert_equal(0, r2.status)
	assert_equal(0, r2.stdout_length)
	process_result_free(r2)
