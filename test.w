/*
Testing Grounds for the W Language
*/



/* Grounds Start */
/*int main1():
	int a = '0'
	a = a + strlen("hi there")
	putchar(a)
	putchar(10)

	print(itoa(11))
	putchar(10)

	return 0*/



/*int range(int end):
	int i = 0
	if (i <= end):
		i = i + 1
		yield i


int main1():
	int a = '0'
	for int x in range(10):
		puterror(0 + x)*/

/*int main1():
	char *s = "hi thar\x0a"
	syscall(4,2,s,strlen(s))
	return 0*/


int main_write():
	# create file
	char *filename = "/home/w/git/cc500/test_output.txt"
	# 511 == 0777
	int file = open(filename, 2, 511)
	print("file_handle: ")
	print(itoa(file))
	print("\x0a")

	# seek to end
	int position = seek(file, 0, 2)
	print("position: ")
	print(itoa(position))
	print("\x0a")

	# write to file
	char *s = "hi thar, derpity derp\x0a"
	write(file, s)

	# close file
	close(file)

	return 0

int main_read():
	int file = open("/home/w/git/cc500/test_output.txt", 0, 511)

	int size = seek(file, 0, 2) + 1
	print("size: ")
	print(itoa(size))
	print("\x0a")
	char* buf = malloc(size)

	seek(file, 0, 0)
	read(file, buf, size)
	close(file)
	print(buf)
	return 0

int getc():
	char* buf = "\x00"
	int result = read(0, buf, 1)
	if (result == 0):
		return (0-1)
	return buf[0]

void print_arg(int argc):
	print(argc)
	print_hex(": ", argc)


int main(int argc, int argv):
	print_hex("argc: ", argc)
	print_hex("argv: ", argv)
	int i = 0
	int arg
	while (i < argc):
		arg = argv + i * 4
		println(*arg)
		i = i + 1

	return 0

int main_pipe():
	int c = getc()
	int i = 300
	while((i >= 0) & (c >= 0)):
		putchar(c)
		i = i - 1
		c = getc()
	return 0



/*int main1():
	print("Hello, world!\x0a")
	return 0*/


/*
int main1():
	int a = 7
	int b = 3
	int c = a % b
	c = c + '0'
	int d = 1 + 2 * 2
	d = d + '0'
	putchar('"')
	putchar(d)
	putchar('"')
	putchar(10)

	return 0
*/
/*
int main1():
	int a
	
	a = '9'
	while(a >= '0'):
		putchar(a)
		a = a - 1
	putchar(10)
	
	a = '0'
	while(a <= '9'):
		putchar(a)
		a = a + 1
	putchar(10)

	return 0*/

/* Grounds End */
