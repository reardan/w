
/*
int **indirect


void sample():
	char* s =  "hello, world!\x0a"
	# syscall(4, 1, s, 15)
	syscall7(4, 1, s, 15, 0, 0, 0)


int old_main(int arg, int argv):
	int *f = sample
	f()
	exit_w(0)


int _main(int argc, int argv):
	int file = syscall(41, 2, 2, 0)
	syscall7(44, file, "hiya\x0a", 6, 0, 0, 0)
	exit_w(0)
int main():
	raw_asm ("\x90\x90\x90\x90\x90\x90\x90\x90\x90\x90")
	return 0
*/

int _main():
	char* s =  "hello, world!\x0a"
	syscall(4, 1, s, 15) /* write */
	syscall(60, 0, 0, 0) /* exit */
