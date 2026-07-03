/*
Recoverable result helpers for one-word payloads.

Use wresult when a caller can inspect and handle a failure. Keep assert/error
for violated invariants and compile-time fatal diagnostics.
*/
import lib.lib


struct wresult:
	int ok
	int code
	int value


void result_set_ok(wresult* r, int value):
	r.ok = 1
	r.code = 0
	r.value = value


void result_set_error(wresult* r, int code):
	r.ok = 0
	r.code = code
	r.value = 0


wresult* result_new_ok(int value):
	wresult* r = new wresult()
	result_set_ok(r, value)
	return r


wresult* result_new_error(int code):
	wresult* r = new wresult()
	result_set_error(r, code)
	return r


wresult* result_new_from_syscall(int value):
	# Linux reserves -4095..-1 (MAX_ERRNO) for syscall errors.
	if ((value < 0) && (value > -4096)):
		return result_new_error(value)
	return result_new_ok(value)


int result_is_ok(wresult* r):
	return r.ok


int result_is_error(wresult* r):
	return r.ok == 0


int result_value(wresult* r):
	return r.value


int result_code(wresult* r):
	return r.code


int result_unwrap_or(wresult* r, int fallback):
	if (result_is_ok(r)):
		return r.value
	return fallback


void result_free(wresult* r):
	free(r)


int result_take_or(wresult* r, int fallback):
	int value = result_unwrap_or(r, fallback)
	result_free(r)
	return value
