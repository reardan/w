/*
Recoverable result helpers with a generic one-word payload.

wresult[T] carries either an ok payload (T value) or an error code. Use
it when a caller can inspect and handle a failure. Keep assert/error
for violated invariants and compile-time fatal diagnostics.

LAYOUT INVARIANT: 'ok' and 'code' are declared FIRST, so their offsets
are identical in every instantiation of wresult[T]. The postfix '?'
error-propagation operator relies on this: on the error path it returns
the operand pointer reinterpreted as the enclosing function's
wresult[U]* return type, and only 'ok'/'code' are ever read from an
error result. Do not reorder or insert fields before 'value'.

Payload policy: keep T word-sized (int, pointers, char, bool). See
docs/error_results.txt.
*/
import lib.lib


struct wresult[T]:
	int ok
	int code
	T value


void result_set_ok[T](wresult[T]* r, T value):
	r.ok = 1
	r.code = 0
	r.value = value


void result_set_error[T](wresult[T]* r, int code):
	r.ok = 0
	r.code = code
	r.value = 0


# Word-sized payloads by policy, so ok + code + value fit in three
# words on every instantiation and target.
wresult[T]* result_alloc[T]():
	return cast(wresult[T]*, malloc(3 * __word_size__))


wresult[T]* result_new_ok[T](T value):
	wresult[T]* r = result_alloc[T]()
	result_set_ok[T](r, value)
	return r


wresult[T]* result_new_error[T](int code):
	wresult[T]* r = result_alloc[T]()
	result_set_error[T](r, code)
	return r


# Syscall payloads are always plain ints, so this stays monomorphic.
wresult[int]* result_new_from_syscall(int value):
	# Linux reserves -4095..-1 (MAX_ERRNO) for syscall errors.
	if ((value < 0) && (value > -4096)):
		return result_new_error[int](value)
	return result_new_ok[int](value)


int result_is_ok[T](wresult[T]* r):
	return r.ok


int result_is_error[T](wresult[T]* r):
	return r.ok == 0


T result_value[T](wresult[T]* r):
	return r.value


int result_code[T](wresult[T]* r):
	return r.code


T result_unwrap_or[T](wresult[T]* r, T fallback):
	if (result_is_ok[T](r)):
		return r.value
	return fallback


void result_free[T](wresult[T]* r):
	free(r)


T result_take_or[T](wresult[T]* r, T fallback):
	T value = result_unwrap_or[T](r, fallback)
	result_free[T](r)
	return value
