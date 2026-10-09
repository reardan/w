# wfuzz_test's target (tools/wfuzz.w): reads the file named by its
# argument and branches on its content. Each nested condition is a new
# statement counter, so coverage guidance can climb one level at a time
# (the keywords are in wfuzz's token dictionary, the bytes in its
# alphabet); an input with both keywords dereferences a null
# pointer. Exit 0 = accepted, 1 = rejected, like a compiler's
# compiled/diagnosed.
import lib.lib
import lib.args
import lib.file
import lib.str


int fixture_depth(char* text):
	int depth = 0
	if (contains(text, c"if (")):
		depth = 1
		if (contains(text, c"while (")):
			depth = 2
	return depth


int fixture_prefix(char* text):
	int depth = 0
	if (text[0] == 'w'):
		depth = 1
		if (text[1] == '('):
			depth = 2
			if (text[2] == ':'):
				depth = 3
	return depth


int main(int argc, int argv):
	args_init(argc, argv)
	if (args_count() < 2): return 2
	char* text = file_read_text(args_get(1))
	if (text == 0): return 2
	if (strlen(text) < 4): return 1
	if (fixture_prefix(text) == 3): return 0
	int depth = fixture_depth(text)
	if (depth == 2):
		int* nothing = cast(int*, 0)
		return *nothing
	if (depth >= 1): return 0
	return 1
