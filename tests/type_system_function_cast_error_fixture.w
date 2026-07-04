import lib.lib


int add(int a, int b):
	return a + b


void function_to_sub_word_cast_error():
	char c = cast(char, add)


int main():
	return 0
