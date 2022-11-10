void _main(int argc, char** argv):
	syscall(4, 0, "hello, world!\x0a", 15)
	syscall(1, 0, 0, 0)
