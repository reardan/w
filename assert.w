
void asserts(char* s, int condition):
	if (condition == 0):
		println(s)
		exit(1)


void assert(int condition):
	if (!condition):
		println("Assertion failed.")
		exit(1)


void assert_equal(int want, int got):
	if (want != got):
		print("Assertion failed.  wanted '")
		print(itoa(want))
		print("' got '")
		print(itoa(got))
		println("'")
		exit(1)
