/*
Fixture for dwarf_addr_size_test: the build target compiles this for
x86 and x64 and runs both before the test parses their DWARF. It must
print on both targets, so it uses lib.lib (which resolves the
per-arch write syscall) rather than tests/hello.w's raw 32-bit
syscall numbers.
*/
import lib.lib


int add(int a, int b):
	return a + b


int main():
	int total = add(3, 4)
	if (total != 7):
		return 1
	println(c"hello from dwarf fixture")
	return 0
