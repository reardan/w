# Run lib/bidi.w against a BidiCharacterTest.txt-format file:
#   bin/bidi_conformance path/to/BidiCharacterTest.txt
# The full UCD file is not committed; tests/data/bidi_character_sample.txt
# is a sample of it that tests/bidi_test.w runs.
import lib.lib
import tools.bidi_conformance_lib

int main(int argc, int argv):
	if (argc < 2):
		println2(c"usage: bidi_conformance BidiCharacterTest.txt")
		return 2
	char** args = cast(char**, argv)
	int total = 0
	int failures = bidi_conf_file(args[1], 1, &total)
	if (failures < 0):
		println2(c"bidi_conformance: cannot read the file")
		return 2
	print(f"{total - failures}/{total} lines pass\n")
	return failures != 0
