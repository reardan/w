void takes_char_ptr(char* s):
	pass


char* returns_char_ptr():
	return "plain return"


int main(int argc, int argv):
	char* p = "plain init"
	takes_char_ptr("plain arg")
	p = "plain assign"
	return 0
