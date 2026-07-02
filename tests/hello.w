int _main(int argc, char** argv):
	syscall(4, 1, "hello, world!\x0a", 14)
	return 0
