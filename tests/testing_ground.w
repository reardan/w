/*
Testing Grounds for the W Language
TODO: refactor all these into the appropriate test files.
*/
import lib.lib
import lib.assert
import lib.args

int global_int
char* global_char

/* Grounds Start */
/*int main1():
	int a = '0'
	a = a + strlen("hi there")
	put_char(a)
	put_char(10)

	print(itoa(11))
	put_char(10)

	return 0*/



/*int range(int end):
	int i = 0
	if (i <= end):
		i = i + 1
		yield i


int main1():
	int a = '0'
	for int x in range(10):
		put_error(0 + x)*/

/*int main1():
	char *s = "hi thar\x0a"
	syscall(4,2,s,strlen(s))
	return 0*/

/*int forgotten_colon()
	return 0
*/


int main_write():
	# create file
	char *filename = c"/home/w/git/cc500/test_output.txt"
	# 511 == 0777
	int file = open_or_create(filename, 2, 511)
	print(c"file_handle: ")
	print(itoa(file))
	print(c"\x0a")

	# seek to end
	int position = seek(file, 0, 2)
	print(c"position: ")
	print(itoa(position))
	print(c"\x0a")

	# write to file
	char *s = c"hi thar, derpity derp da derp da derp\x0a"
	write_string(file, s)

	# close file
	close(file)

	return 0


int main_read():
	int file = open(c"/home/w/git/cc500/test_output.txt", 0, 511)

	int size = seek(file, 0, 2) + 1
	print(c"size: ")
	print(itoa(size))
	print(c"\x0a")
	char* buf = malloc(size)

	seek(file, 0, 0)
	read(file, buf, size)
	close(file)
	print(buf)
	return 0


void print_arg(int argc):
	print(argc)
	print_hex(c": ", argc)


int main_args(int argc, int argv):
	args_init(argc, argv)
	print_hex(c"argc: ", argc)
	print_hex(c"argv: ", argv)
	int i = 0
	while (i < args_count()):
		println(args_get(i))
		i = i + 1

	return 0

int main_strings(int argc, int argv):
	if (starts_with(c"hi there", c"hi")):
		println(c"it worked!!")
	else:
		println(c"prefix not working...")

	if (strcmp(c"hi there", c"hi there")):
		println(c"strcmp worked!")

	if (strcmp(c"", c"")):
		println(c"strcmp blank worked!")

	if (strcmp(c"c", c"c")):
		println(c"strcmp char worked!")

	if (strcmp(c"hi there", c"hi there1")):
		println(c"this shouldn't have worked...")

	if (strcmp(c"", c"h")):
		println(c"this shouldn't have worked...")

	if (strcmp(c"a", c"")):
		println(c"this shouldn't have worked...")

	return 0

int main(int argc, int argv):
	print_error(c"yolo swag life!\x0a")
	if (strcmp(itoa(0), c"0") != 0):
		println(c"failed zero check")
		# exit(1)

	# The testing_ground target passes: arg1 arg2 arg3 -o output -i=input --input=doubledash
	if (argc > 1):
		args_init(argc, argv)
		asserts(c"expected 3 positional args", args_positional_count() == 3)
		asserts(c"bad -o value", strcmp(args_value(c"o"), c"output") == 0)
		asserts(c"bad -i value", strcmp(args_value(c"i"), c"input") == 0)
		asserts(c"bad --input value", strcmp(args_value(c"input"), c"doubledash") == 0)
		println(c"command line args parsed ok")
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
	put_char('"')
	put_char(d)
	put_char('"')
	put_char(10)

	return 0
*/
/*
int main1():
	int a
	
	a = '9'
	while(a >= '0'):
		put_char(a)
		a = a - 1
	put_char(10)
	
	a = '0'
	while(a <= '9'):
		put_char(a)
		a = a + 1
	put_char(10)

	return 0*/

/* Grounds End */
