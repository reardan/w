# Force guard allocation explicitly: Windows has no /proc/self/environ.
# The unsafe harness observes the same checked functions on every target.
import lib.safe_buffer
import lib.memory_debug

struct WinSafeOwner:
	own WIntBuffer* numbers
	own WByteString* text
	own int* marker

struct WinSafeView:
	ref[items] int[] values
	int tag

ref[a] int* win_safe_choose(ref[a] int* left, ref[a] int* right, int first):
	if first: return left
	return right

ref[a] WinSafeView win_safe_wrap(ref[a] int[] values):
	return WinSafeView(values, 17)

own WinSafeOwner* win_safe_make():
	own WIntBuffer* numbers = int_buffer_new()
	int i = 0
	while i < 100:
		int_buffer_push(numbers, i + 7)
		i = i + 1
	byte[3] initial
	initial[0] = cast(byte, 65)
	initial[1] = cast(byte, 0)
	initial[2] = cast(byte, 90)
	own WByteString* text = byte_string_from(initial)
	byte_string_append(text, initial)
	own int* marker = new int
	*marker = 23
	return new WinSafeOwner(numbers, text, marker)

own WinSafeOwner* win_safe_relay(own WinSafeOwner* value):
	return value

int win_safe_exercise(int limit):
	own WinSafeOwner* value = win_safe_relay(win_safe_make())
	ref WinSafeView wrapped = win_safe_wrap(int_buffer_view(value.numbers))
	ref int[] elements = wrapped.values
	ref int[] tail = elements[95:]
	if tail.length != 5: return 1
	if tail[4] != 106: return 2
	if wrapped.tag != 17: return 3
	ref byte[] bytes = byte_string_view(value.text)
	if bytes.length != 6: return 4
	if bytes[1] != cast(byte, 0): return 5
	if bytes[5] != cast(byte, 90): return 6
	int_buffer_push(value.numbers, 200)
	if int_buffer_pop(value.numbers) != 200: return 7
	int_buffer_set(value.numbers, 0, 31)
	if int_buffer_get(value.numbers, 0) != 31: return 8
	int first = 11
	int second = 13
	ref int* selected = win_safe_choose(&first, &second, 0)
	if *selected != 13: return 9
	int n = limit
	while n > 0:
		own WinSafeOwner* local = win_safe_make()
		n = n - 1
		if n == 3: continue
		if n == 1: break
		ref int* marker = local.marker
		if *marker != 23: return 10
	value = win_safe_make()
	ref int* result = value.marker
	return *result - 23

int main():
	int before = 0
	unsafe:
		malloc_force_debug_mode()
		before = debug_alloc_report_leaks()
	int result = win_safe_exercise(0) + win_safe_exercise(1) + win_safe_exercise(5)
	int after = 0
	unsafe:
		after = debug_alloc_report_leaks()
	return result + after - before
