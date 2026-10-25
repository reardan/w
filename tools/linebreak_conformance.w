# wbuild: binary=linebreak_conformance tag=tests
# Run lib/linebreak.w (UAX #14, default tailoring) against a
# LineBreakTest.txt-format file:
#   bin/linebreak_conformance path/to/LineBreakTest.txt
# The full UCD file is not committed; tests/data/linebreak_sample.txt is a
# sample of it that tests/linebreak_test.w runs.
import lib.lib
import tools.linebreak_conformance_lib

int main(int argc, int argv):
	if (argc < 2):
		println2(c"usage: linebreak_conformance LineBreakTest.txt")
		return 2
	char** args = cast(char**, argv)
	int total = 0
	int failures = lb_conf_file(args[1], lb_tailor_default, 1, &total)
	if (failures < 0):
		println2(c"linebreak_conformance: cannot read the file")
		return 2
	print(f"{total - failures}/{total} lines pass\n")
	return failures != 0
