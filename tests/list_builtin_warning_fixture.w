# Compile-only fixture: each statement below must produce the type warning
# the list_builtin_test build target greps for.
import lib.lib


int main():
	list[int] numbers = new list[int]
	numbers.push(c"nope")
	numbers[0] = c"bad"
	list[int] wrong_init = new list[char*]
	for char* misread in numbers:
		print_string(c"x: ", misread)
	int an_int = 5
	list[char*] names = list[char*]{an_int}
	return 0
