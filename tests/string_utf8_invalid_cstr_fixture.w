import lib.utf8


int main(int argc, int argv):
	string s = c"\xff"
	utf8_write(1, s)
	return 0
