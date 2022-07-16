int _main():
	char* s =  "hello, 64 bit world!\x0a"
	syscall(1, 1, s, 22) /* write */
	syscall(60, 0, 0, 0) /* exit */
