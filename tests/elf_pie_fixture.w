# Static and dynamic PIE share this input; the dynamic variant adds
# elf_pie_imports.w as a second root. Exercise stored pointers as well
# as forward function-address chains and high-address signal handlers.
import lib.lib
import lib.assert
import lib.utf8
import lib.signal
import lib.stack_trace

int[3] pie_items
struct pie_record:
	int[2] items
pie_record pie_rec
thread_local int pie_tls
int pie_signal_seen

int pie_forward(int n);
type pie_callback = fn(int) -> int

void pie_handler(int sig, int context):
	pie_signal_seen = sig

int main():
	pie_items[2] = 73
	pie_rec.items[1] = 19
	assert_equal(92, pie_items[2] + pie_rec.items[1])
	pie_tls = 41
	assert_equal(41, pie_tls)
	string s = "PIE UTF-8: λ"
	assert_equal(13, len(s))
	assert_strings_equal(c"PIE UTF-8: λ", cstr(s))
	pie_callback* callback = pie_forward
	assert_equal(42, callback(41))
	signal_install_handler(10, cast(int, pie_handler), 0)
	kill(getpid(), 10)
	assert_equal(10, pie_signal_seen)
	st_init(cast(int, main))
	assert_equal(1, st_state)
	assert_strings_equal(c"main", stack_trace_symbol(cast(int, main)))
	asserts(c"PIE was slid", st_slide != 0)
	asserts(c"PIE code above 4GB", cast(int, main) >> 32 != 0)
	println(hex_fixed(cast(int, main), 16))
	return 0

int pie_forward(int n):
	return n + 1
