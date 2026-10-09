# Diagnostic call sites for 'wcoverage lines --diagnostics' (coverage_test).
void fixture_error(char* message):
	print_error(message)
	print_error(c"\x0a")


void fixture_warning(char* message):
	print_error(message)
	print_error(c"\x0a")


int check(int value):
	if (value < 0): fixture_error(c"negative")
	if (value > 100):
		fixture_warning(c"large")
	if (value == 7): fixture_warning(c"seven")
	# fixture_error(c"a comment is not a call site")
	char* text = "fixture_error(\"nor is a string\")"
	return value + strlen(text)


int main(int argc, char** argv):
	check(argc + 6)
	return 0
