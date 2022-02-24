/*lib.w
var: int type (parent object)

String:
	length

Array:
	length
	total

Object:
	String

Import System
	keywords: import Filename


*/
/* Our library functions. */
void exit(int);
int getchar(void);
void *malloc(int);
int putchar(int);
int puterror(int);

/* The first function implemented must be _main(). */
int main(int argc, int argv);
int _main(int argc, int argv):
	exit(main(argc, argv))


/* string functions */
char *realloc(char *old, int oldlen, int newlen):
	char *new = malloc(newlen)
	int i = 0
	while (i <= oldlen - 1):
		new[i] = old[i]
		i = i + 1

	return new

int strlen(char *c):
	int length = 0
	while(c[length]):
		length = length + 1
	return length

char* strclone(char *c):
	int length = strlen(c)
	return realloc(c, length, length)

void strcpy(char *dst, char *src):
	while (*src):
		*dst = *src
		src = src + 1
		dst = dst + 1

void reverse(char *s):
	int i = 0
	int j = strlen(s)-1
	int c
	while(i < j):
		c = s[i]
		s[i] = s[j]
		s[j] = c
		i = i + 1
		j = j -1

char* itoa(int n):
	char *s = "012345678901234567890"
	int i
	int sign = n
	if(n < 0):
		n = 0-n
	i = 0
	while(n > 0):
		s[i] = n % 10 + '0'
		i = i + 1
		n = n / 10
	if(sign < 0):
		s[i] = '-'
		i = i + 1
	s[i] = 0
	reverse(s)
	return s


void print(char *s):
	int i = 0
	while(s[i]):
		putchar(s[i])
		i = i + 1


void put_error(char *s):
	int i = 0
	while(s[i]):
		puterror(s[i])
		i = i + 1

void print_int(char* c, int v):
	print(c)
	print(itoa(v))
	print("\x0a")

char* hex(int v):
	char* s = "0x00000000"
	int i = 7
	int digit
	while (i >= 0):
		digit = (v & 15)
		if (digit < 10):
			digit = digit + '0'
		else:
			digit = digit - 10 + 'a'
		s[i + 2] = digit
		v = v >> 4
		i = i - 1
	return s

void print_hex(char* c, int v):
	print(c)
	print(hex(v))
	print("\x0a")

void println(char *s):
	print(s)
	putchar(10)

################################################################################
int create(char* filename, int permissions):
	return syscall(8, filename, permissions, 0)

/* mode: 0 - read, 1 - write, 2 - readwrite */
int open(char *filename, int mode, int permissions)
	return syscall(5, filename, mode, permissions)

int write(int file, char* s):
	return syscall(4, file, s, strlen(s))

int read(int file, char* buf, int size):
	return syscall(3, file, buf, size)

int close(int file):
	return syscall(6, file, 0, 0)

/* reference: 0 - beginning, 1 - current position, 2 - end of file */
int seek(int file, int offset, int reference):
	return syscall(19, file, offset, reference)
################################################################################
