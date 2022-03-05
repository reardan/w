/*
lib.w
Our library functions.

No dependencies except calls provided by the compiler.  May change.
This should only be functions that are highly common and every application requires.
*/
void exit(int);
void *malloc(int);


int verbosity;


/*
The main Undefined declaration.
This will be provided by the importing program as an entry point to their code.
*/
int main(int argc, int argv);
/*
The _main() function is what will be called

ELF/PE -> Entry Point directly after main headers.
Entry Point: Setup argc and argv via assembly.
Then we call this _main() which passes the command line arguments to main().
The compiler writes the address of this function
from the symbol table to the call instruction at the entry point.
*/
int _main(int argc, int argv):
	exit(main(argc, argv))


# string functions
char *realloc(char *old, int oldlen, int newlen):
	char *new = malloc(newlen)
	int i = 0
	while (i < oldlen):
		new[i] = old[i]
		i = i + 1

	return new


int free(int mem_address):
	return 1


int strlen(char *c):
	int length = 0
	while(c[length]):
		length = length + 1
	return length


void strncpy(char* dst, char* src, int n):
	int i = 0
	while ((i < n) & (src[i] != 0)):
		dst[i] = src[i]
		i = i + 1



# Note the return value is the final index, NOT the original dst
char* strcpy(char *dst, char *src):
	while (src[0]):
		dst[0] = src[0]
		src = src + 1
		dst = dst + 1
	dst[0] = 0
	return dst


char* strclone(char *c):
	char *clone = malloc(strlen(c) + 1)
	strcpy(clone, c)
	return clone


char* strjoin(char* s1, char* s2):
	int size = strlen(s1) + strlen(s2) + 1
	char* joined = malloc(size)
	strcpy(strcpy(joined, s1), s2)
	return joined


# Warning: DANGER!  Not recommended, use string instead.
# can easily bleed beyond s1 if not enough space is allocated
char* strappend(char* dst, char* src):
	dst = dst + strlen(dst)
	return strcpy(dst, src)


void reverse_n(char* s, int n):
	int i = 0
	int j = n-1
	int c
	while(i < j):
		c = s[i]
		s[i] = s[j]
		s[j] = c
		i = i + 1
		j = j -1


void reverse(char *s):
	reverse_n(s, strlen(s))


char* itoa(int n):
	# definitely not thread-safe
	# instead we could use a thread local variable
	# or just malloc and expect the caller to free
	char *s = "012345678901234567890"
	int i = 0
	int sign = n
	if(n < 0):
		n = 0-n
	if (n == 0):
		s[i] = '0'
		i = i + 1
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


int atoi(char* s):
	int result = 0
	int negative = 0
	if (s[0] == '-'):
		s = s + 1
		negative = 1
	while (s[0] >= '0' & s[0] <= '9'):
		result = result * 10 + s[0] - '0'
		s = s + 1
	if (negative == 1):
		return 0-result
	return result


int intstrlen(int i):
	int len = 0
	if (i == 0):
		return 1
	if (i < 0):
		i = 0-i
		len = len + 1  /* for '-' */
	while (i > 0):
		i = i / 10
		len = len + 1
	return len


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


int from_hex(char* s):
	int result = 0
	
	int i = 0
	int ch = s[i]
	while ((ch != 0) & (i < 18)):
		if (ch >= '0' & ch <= '9'):
			result = (result << 4) + ch - '0'
		else if(ch >= 'a' & ch <= 'f'):
			result = (result << 4) + ch - 'a' + 10
		i = i + 1
		ch = s[i]
	return result


int ip4_from_string(char* ips):
	int ip4 = 0
	int i = 0
	while (i < 4):
		int b = atoi(ips)
		ip4 = (ip4 << 8) + b
		ips = ips + intstrlen(b) + 1
		i = i + 1
	return ip4


# TODO: figure out why *(char*) is broken
# (it uses full int instead of zero extending)
# type is always 2, but needs to be reset to char
# based on the symbol table
int starts_with(char *s, char* prefix):
	while (prefix[0]):
		if (s[0] == 0):
			return 0
		if (s[0] != prefix[0]):
			return 0
		s = s + 1
		prefix = prefix + 1
	return 1


int strcmp(char *dst, char *src):
	while (dst[0] & src[0]):
		if (dst[0] != src[0]):
			return dst[0] - src[0]
		dst = dst + 1
		src = src + 1
	return dst[0] - src[0]



################################################################################
int create_file(char* filename, int permissions):
	return syscall(8, filename, permissions, 0)

/* mode: 0 - read, 1 - write, 2 - readwrite */
int open(char *filename, int mode, int permissions)
	return syscall(5, filename, mode, permissions)

int write(int file, char* s, int length):
	return syscall(4, file, s, length)

int read(int file, char* buf, int size):
	return syscall(3, file, buf, size)

int close(int file):
	return syscall(6, file, 0, 0)

/* reference: 0 - beginning, 1 - current position, 2 - end of file */
int seek(int file, int offset, int reference):
	return syscall(19, file, offset, reference)
################################################################################


int open_or_create(char *filename, int mode, int permissions):
	int file = open(filename, mode, permissions)
	if (file < 0):
		file = create_file(filename, permissions)
	return file


# A bit hacky, ideally this would be seek:
int file_size(int file):
	int result = seek(file, 0, 2)  /* seek to end to get file size */
	seek(file, 0, 0) /* seek back to beginning */
	return result

# A nice function to have would be char* read_filename(char* filename)
# which would read the entire file in one go, failing with exit(1) if open/read fails.
# This would use blocks of 1MB and realloc to read the file
# ensuring that it can work with sockets, etc.


int write_string(int file, char* s):
	return write(file, s, strlen(s)) /* +1? */


int getchar(int file):
	char* buf = "\x00"
	int result = read(file, buf, 1)
	if (result == 0):
		return (0-1)
	return buf[0]


void putc(int file, int c):
	char* buf = "\x00"
	buf[0] = c
	write(file, buf, file)
	# write(file, &c, 1)


void put_char(int c):
	putc(1, c)


void put_error(int c):
	putc(2, c)


void print(char *s):
	write_string(1, s)


void print_error(char* s):
	write_string(2, s)


void print2(char* s):
	write_string(2, s)


void print_int0(char* c, int v):
	print_error(c)
	print_error(itoa(v))


void print_int(char* c, int v):
	print_int0(c, v)
	print_error("\x0a")


void print_hex0(char* c, int v):
	print_error(c)
	print_error(hex(v))


void print_hex(char* c, int v):
	print_hex0(c, v)
	print_error("\x0a")


void print_string(char* s1, char* s2):
	print_error(s1)
	print_error(s2)
	print_error("\x0a")


void println(char *s):
	print(s)
	put_char(10)


void println2(char *s):
	print_error(s)
	put_error(10)


void print_n(char *s, int n):
	write(1, s, n)


# Debugging:
void print_words(int addr, int count):
	int i = 0
	while (i < count):
		print(hex(addr))
		print(": ")
		println(hex(*addr))
		addr = addr + 4
		i = i + 1


void print_registers():
	int i


void print_stack():
	int i

