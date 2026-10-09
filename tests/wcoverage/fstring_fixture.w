# Interpolated f-strings under --coverage and --profile-generate: the
# counter map keys each definition by its defhash, whose re-tokenize
# pass must resume a template's literal chunk after each '}'.
char* label(int n):
	if (n > 2):
		return f"big_{n}"
	return f"small_{n}"


int main(int argc, char** argv):
	int x = argc + 2
	char* name = "w"
	println(f"a_{x} {f"in{x}{{}}"} {x + 1:>4}{name}")
	println(label(x))
	if (argc > 1):
		println(f"args_{argc}")
	return 0
