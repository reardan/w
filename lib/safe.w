# Minimal output interface for checked programs. The formatting itself is
# ordinary checked scalar W; only put_char crosses the audited runtime
# boundary. Keeping values negative also handles the minimum signed int.
import lib.lib


void safe_print_digits(int value):
	if value <= -10: safe_print_digits(value / 10)
	put_char('0' - value % 10)


void safe_print_int(int value):
	if value < 0: put_char('-')
	if value > 0: value = 0 - value
	safe_print_digits(value)


void safe_println_int(int value):
	safe_print_int(value)
	put_char(10)
