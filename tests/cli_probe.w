# Tiny program for tests/compiler_cli_test.w steps: enough surface to
# exercise option parsing, subcommands and diagnostics, nothing more.
import lib.lib

int twice(int x):
	return x * 2

int main():
	println(twice(21))
	return 0
