# wbuild: binary=wvmd_cell_fixture arch=x64
import lib.lib
import lib.assert

int private_counter

int main(int argc, int argv):
	char** args = cast(char**, argv)
	if (argc < 2): return 2
	if (strcmp(args[1], c"private") == 0):
		private_counter = private_counter + 1
		assert_equal(1, private_counter)
		assert_equal(-13, open(c"/etc/passwd", 0, 0))
		println(c"private")
		return 0
	if (strcmp(args[1], c"region-write") == 0):
		char* region = cast(char*, 251658240)
		region[0] = 'Z'
		return 0
	if (strcmp(args[1], c"region-read") == 0):
		char* region = cast(char*, 251658240)
		assert_equal('Z', region[0])
		asserts(c"shared permissions cannot escalate", mprotect(251658240, 4096, 3) < 0)
		write(1, region, 1)
		return 0
	return 3
