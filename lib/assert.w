
void asserts(char* s, int condition):
	if (condition == 0):
		println2(s)
		exit(1)


# todo cannot name the same as the file lol!
#void assert1(int condition):
void assert1(int condition):
	if (condition == 0):
		println2(c"Assertion2 failed.")
		exit(1)


void assert_equal(int want, int got):
	if (want != got):
		print2(c"Assertion failed.  wanted int(")
		print2(itoa(want))
		print2(c") got int(")
		print2(itoa(got))
		println2(c")")
		exit(1)


void assert_equal_hex(int want, int got):
	if (want != got):
		print2(c"Assertion failed.  wanted ")
		print2(hex(want))
		print2(c" got ")
		print2(hex(got))
		println2(c"")
		exit(1)


void assert_strings_equal(char* want, char* got):
	if (strcmp(got, want) != 0):
		print2(c"Assertion failed: wanted '")
		print2(want)
		print2(c"' got '")
		print2(got)
		println2(c"'")
		exit(1)
