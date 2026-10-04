import lib.linux

int _main(int argc, char** argv):
	write(1, c"hello, world!\x0a", 14)
	return 0
