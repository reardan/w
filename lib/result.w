/*
Recoverable result helpers for one-word payloads.

Use result when a caller can inspect and handle a failure. Keep assert/error
for violated invariants and compile-time fatal diagnostics.
*/
import lib.lib


struct result:
	int ok
	int code
	int value


void result_set_ok(result* r, int value):
	r.ok = 1
	r.code = 0
	r.value = value


void result_set_error(result* r, int code):
	r.ok = 0
	r.code = code
	r.value = 0


result* result_new_ok(int value):
	result* r = new result()
	result_set_ok(r, value)
	return r


result* result_new_error(int code):
	result* r = new result()
	result_set_error(r, code)
	return r


result* result_new_from_syscall(int value):
	if (value < 0):
		return result_new_error(value)
	return result_new_ok(value)


int result_is_ok(result* r):
	return r.ok


int result_is_error(result* r):
	return r.ok == 0


int result_value(result* r):
	return r.value


int result_code(result* r):
	return r.code


int result_unwrap_or(result* r, int fallback):
	if (result_is_ok(r)):
		return r.value
	return fallback


void result_free(result* r):
	free(r)
