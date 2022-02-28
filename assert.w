
void asserts(char* s, int condition):
	if (condition == 0):
		println2(s)
		exit(1)


# todo cannot name the same as the file lol!
#void assert1(int condition):
void assert1(int condition):
	if (condition == 0):
		println2("Assertion2 failed.")
		exit(1)


void assert_equal(int want, int got):
	if (want != got):
		print2("Assertion failed.  wanted '")
		print2(itoa(want))
		print2("' got '")
		print2(itoa(got))
		println2("'")
		exit(1)

void assert_strings_equal(char* want, char* got):
	if (strcmp(got, want) != 0):
		print2("Assertion failed: wanted '")
		print2(want)
		print2("' got '")
		print2(got)
		println2("'")
		exit(1)
