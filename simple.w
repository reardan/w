

int **indirect


void sample():
	char* s =  "hello, world!\x0a"
	syscall(4, 1, s, 15)


int _main(int arg, int argv):
	int *f = sample
	f()
	exit(0)
