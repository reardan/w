# Shared help for native reduction and hosts without process support.
import lib.lib


int reduce_error(char* message):
	print2(c"w reduce: ")
	println2(message)
	return 1


void reduce_usage():
	println(c"usage: w reduce input.w [-o output.w] [--timeout-ms N] [--max-tests N] -- predicate [args...]")
	println(c"Predicate exit 0 accepts a candidate; {} is replaced by its path, or the path is appended.")
	println(c"Defaults: output input.w.reduced.w, 10000 ms per test, 1000 tests. Existing files are never overwritten.")
