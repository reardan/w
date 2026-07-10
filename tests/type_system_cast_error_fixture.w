# expect_fail
# expect_stderr: cannot cast an address to a sub-word integer
import lib.lib


void pointer_to_sub_word_cast_error():
	char* p = "x"
	char c = cast(char, p)


int main():
	return 0
