/*
lib.w
Our library functions.

No dependencies except calls provided by the compiler.  May change.
This should only be functions that are highly common and every application requires.
*/
import lib.linux


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


int ends_with(char *str, char* suffix):
	# Find end of string
	char* cur_str = str
	while (cur_str[0]):
		cur_str = cur_str + 1

	# Find end of suffix
	char* cur_suffix = suffix
	while (cur_suffix[0]):
		cur_suffix = cur_suffix + 1

	# Reverse backwards through both strings
	while (cur_str >= str & cur_suffix >= suffix):
		if (cur_str[0] != cur_suffix[0]):
			return 0
		cur_str = cur_str - 1
		cur_suffix = cur_suffix - 1

	# Return true if we processed the entire suffix
	if (cur_suffix < suffix):
		return 1
	return 0


int str_replace(char* str, int search, int replace):
	int replacement_count = 0
	while (str[0]):
		if (str[0] == search):
			str[0] = replace
			replacement_count = replacement_count + 1
		str = str + 1
	return replacement_count


int strcmp(char *dst, char *src):
	while (dst[0] & src[0]):
		if (dst[0] != src[0]):
			return dst[0] - src[0]
		dst = dst + 1
		src = src + 1
	return dst[0] - src[0]


int open_or_create(char *filename, int mode, int permissions):
	int file = open(filename, mode, permissions)
	if (file < 0):
		file = create_file(filename, permissions)
	return file



# A bit hacky, ideally this would be fstat:
int file_size(int file):
	int result = seek(file, 0, 2)  /* seek to end to get file size */
	seek(file, 0, 0) /* seek back to beginning */
	return result

# A nice function to have would be char* read_until_empty(char* filename)
# which would read the entire file in one go, failing with exit(1) if open/read fails.
# This would use blocks of 1MB and realloc to read the file
# ensuring that it can work with sockets, etc.


int write_string(int file, char* s):
	return write(file, s, strlen(s)) /* +1? */


int getchar(int file):
	char* buf = "\x00"
	int result = read(file, buf, 1)
	if (result == 0):
		return (-1)
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


void print_char0(char* c, int v):
	print_error(c)
	put_error(v)


void print_int0(char* c, int v):
	print_error(c)
	print_error(itoa(v))


void print_int(char* c, int v):
	print_int0(c, v)
	print_error("\x0a")


void print_int_v1(char* c, int v):
	if (verbosity >= 1):
		print_int(c, v)


void print_hex0(char* c, int v):
	print_error(c)
	print_error(hex(v))


void print_hex(char* c, int v):
	print_hex0(c, v)
	print_error("\x0a")


void print_string0(char* s1, char* s2):
	print_error(s1)
	print_error(s2)


void print_string(char* s1, char* s2):
	print_string0(s1, s2)
	print_error("\x0a")


void println(char *s):
	print(s)
	put_char(10)


void println2(char *s):
	print_error(s)
	put_error(10)


void print_color(char* s, int color):
	print2("\x1b[")
	print2(itoa(color))
	print2("m")
	print2(s)
	print2("\x1b[0m")


void print_color_bg(char* s, int color, int background):
	print2("\x1b[")
	print2(itoa(color))
	print2(";")
	print2(itoa(background))
	print2("m")
	print2(s)
	print2("\x1b[0m")


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



struct register_context:
	int32 eax
	int32 ecx
	int32 edx
	int32 ebx
	int32 esp
	int32 ebp
	int32 esi
	int32 edi


void print_stack():
	println2("Stack:")
	register_context context
	get_context(context)
	print_words(context.esp, 20)


void print_registers():
	println2("Registers:")
	register_context context
	get_context(context)
	print_hex("eax: ", context.eax)
	print_hex("ecx: ", context.ecx)
	print_hex("edx: ", context.edx)
	print_hex("ebx: ", context.ebx)
	print_hex("esp: ", context.esp)
	print_hex("ebp: ", context.ebp)
	print_hex("esi: ", context.esi)
	print_hex("edi: ", context.edi)
	println2("")


# /usr/include/asm-generic/errno-base.h
int translate_syscall_failure(int err):
	if (err >= 0):
		return err

	err = 0 - err
	print2(itoa(err))
	print2(": ")

	if(err == 1):
		println2("EPERM: Operation not permitted.")
	else if(err == 2):
		println2("ENOENT: No such file or directory.")
	else if(err == 3):
		println2("ESRCH: No such process.")
	else if(err == 4):
		println2("EINTR: Interrupted system call.")
	else if(err == 5):
		println2("EIO: I/O error.")
	else if(err == 6):
		println2("ENXIO: No such device or address.")
	else if(err == 7):
		println2("E2BIG: Argument list too long.")
	else if(err == 8):
		println2("ENOEXEC: Exec format error.")
	else if(err == 9):
		println2("EBADF: Bad file number.")
	else if(err == 10):
		println2("ECHILD: No child processes.")
	else if(err == 11):
		println2("EAGAIN: Try again.")
	else if(err == 12):
		println2("ENOMEM: Out of memory.")
	else if(err == 13):
		println2("EACCES: Permission denied.")
	else if(err == 14):
		println2("EFAULT: Bad address.")
	else if(err == 15):
		println2("ENOTBLK: Block device required.")
	else if(err == 16):
		println2("EBUSY: Device or resource busy.")
	else if(err == 17):
		println2("EEXIST: File exists.")
	else if(err == 18):
		println2("EXDEV: Cross-device link.")
	else if(err == 19):
		println2("ENODEV: No such device.")
	else if(err == 20):
		println2("ENOTDIR: Not a directory.")
	else if(err == 21):
		println2("EISDIR: Is a directory.")
	else if(err == 22):
		println2("EINVAL: Invalid argument.")
	else if(err == 23):
		println2("ENFILE: File table overflow.")
	else if(err == 24):
		println2("EMFILE: Too many open files.")
	else if(err == 25):
		println2("ENOTTY: Not a typewriter.")
	else if(err == 26):
		println2("ETXTBSY: Text file busy.")
	else if(err == 27):
		println2("EFBIG: File too large.")
	else if(err == 28):
		println2("ENOSPC: No space left on device.")
	else if(err == 29):
		println2("ESPIPE: Illegal seek.")
	else if(err == 30):
		println2("EROFS: Read-only file system.")
	else if(err == 31):
		println2("EMLINK: Too many links.")
	else if(err == 32):
		println2("EPIPE: Broken pipe.")
	else if(err == 33):
		println2("EDOM: Math argument out of domain of func.")
	else if(err == 34):
		println2("ERANGE: Math result not representable.")
	else if(err == 35):
		println2("EDEADLK: Resource deadlock would occur")
	else if(err == 36):
		println2("ENAMETOOLONG: File name too long")
	else if(err == 37):
		println2("ENOLCK: No record locks available")
	else if(err == 38):
		println2("ENOSYS: Invalid system call number")
	else if(err == 39):
		println2("ENOTEMPTY: Directory not empty")
	else if(err == 40):
		println2("ELOOP: Too many symbolic links encountered")
	else if(err == 41):
		println2("EWOULDBLOCK: Operation would block")
	else if(err == 42):
		println2("ENOMSG: No message of desired type")
	else if(err == 43):
		println2("EIDRM: Identifier removed")
	else if(err == 44):
		println2("ECHRNG: Channel number out of range")
	else if(err == 45):
		println2("EL2NSYNC: Level 2 not synchronized")
	else if(err == 46):
		println2("EL3HLT: Level 3 halted")
	else if(err == 47):
		println2("EL3RST: Level 3 reset")
	else if(err == 48):
		println2("ELNRNG: Link number out of range")
	else if(err == 49):
		println2("EUNATCH: Protocol driver not attached")
	else if(err == 50):
		println2("ENOCSI: No CSI structure available")
	else if(err == 51):
		println2("EL2HLT: Level 2 halted")
	else if(err == 52):
		println2("EBADE: Invalid exchange")
	else if(err == 53):
		println2("EBADR: Invalid request descriptor")
	else if(err == 54):
		println2("EXFULL: Exchange full")
	else if(err == 55):
		println2("ENOANO: No anode")
	else if(err == 56):
		println2("EBADRQC: Invalid request code")
	else if(err == 57):
		println2("EBADSLT: Invalid slot")
	else if(err == 58): 
		println2("EDEADLOCK: EDEADLOCK")
	else if(err == 59):
		println2("EBFONT: Bad font file format")
	else if(err == 60):
		println2("ENOSTR: Device not a stream")
	else if(err == 61):
		println2("ENODATA: No data available")
	else if(err == 62):
		println2("ETIME: Timer expired")
	else if(err == 63):
		println2("ENOSR: Out of streams resources")
	else if(err == 64):
		println2("ENONET: Machine is not on the network")
	else if(err == 65):
		println2("ENOPKG: Package not installed")
	else if(err == 66):
		println2("EREMOTE: Object is remote")
	else if(err == 67):
		println2("ENOLINK: Link has been severed")
	else if(err == 68):
		println2("EADV: Advertise error")
	else if(err == 69):
		println2("ESRMNT: Srmount error")
	else if(err == 70):
		println2("ECOMM: Communication error on send")
	else if(err == 71):
		println2("EPROTO: Protocol error")
	else if(err == 72):
		println2("EMULTIHOP: Multihop attempted")
	else if(err == 73):
		println2("EDOTDOT: RFS specific error")
	else if(err == 74):
		println2("EBADMSG: Not a data message")
	else if(err == 75):
		println2("EOVERFLOW: Value too large for defined data type")
	else if(err == 76):
		println2("ENOTUNIQ: Name not unique on network")
	else if(err == 77):
		println2("EBADFD: File descriptor in bad state")
	else if(err == 78):
		println2("EREMCHG: Remote address changed")
	else if(err == 79):
		println2("ELIBACC: Can not access a needed shared library")
	else if(err == 80):
		println2("ELIBBAD: Accessing a corrupted shared library")
	else if(err == 81):
		println2("ELIBSCN: .lib section in a.out corrupted")
	else if(err == 82):
		println2("ELIBMAX: Attempting to link in too many shared libraries")
	else if(err == 83):
		println2("ELIBEXEC: Cannot exec a shared library directly")
	else if(err == 84):
		println2("EILSEQ: Illegal byte sequence")
	else if(err == 85):
		println2("ERESTART: Interrupted system call should be restarted")
	else if(err == 86):
		println2("ESTRPIPE: Streams pipe error")
	else if(err == 87):
		println2("EUSERS: Too many users")
	else if(err == 88):
		println2("ENOTSOCK: Socket operation on non-socket")
	else if(err == 89):
		println2("EDESTADDRREQ: Destination address required")
	else if(err == 90):
		println2("EMSGSIZE: Message too long")
	else if(err == 91):
		println2("EPROTOTYPE: Protocol wrong type for socket")
	else if(err == 92):
		println2("ENOPROTOOPT: Protocol not available")
	else if(err == 93):
		println2("EPROTONOSUPPORT: Protocol not supported")
	else if(err == 94):
		println2("ESOCKTNOSUPPORT: Socket type not supported")
	else if(err == 95):
		println2("EOPNOTSUPP: Operation not supported on transport endpoint")
	else if(err == 96):
		println2("EPFNOSUPPORT: Protocol family not supported")
	else if(err == 97):
		println2("EAFNOSUPPORT: Address family not supported by protocol")
	else if(err == 98):
		println2("EADDRINUSE: Address already in use")
	else if(err == 99):
		println2("EADDRNOTAVAIL: Cannot assign requested address")
	else if(err == 100):
		println2("ENETDOWN: Network is down")
	else if(err == 101):
		println2("ENETUNREACH: Network is unreachable")
	else if(err == 102):
		println2("ENETRESET: Network dropped connection because of reset")
	else if(err == 103):
		println2("ECONNABORTED: Software caused connection abort")
	else if(err == 104):
		println2("ECONNRESET: Connection reset by peer")
	else if(err == 105):
		println2("ENOBUFS: No buffer space available")
	else if(err == 106):
		println2("EISCONN: Transport endpoint is already connected")
	else if(err == 107):
		println2("ENOTCONN: Transport endpoint is not connected")
	else if(err == 108):
		println2("ESHUTDOWN: Cannot send after transport endpoint shutdown")
	else if(err == 109):
		println2("ETOOMANYREFS: Too many references: cannot splice")
	else if(err == 110):
		println2("ETIMEDOUT: Connection timed out")
	else if(err == 111):
		println2("ECONNREFUSED: Connection refused")
	else if(err == 112):
		println2("EHOSTDOWN: Host is down")
	else if(err == 113):
		println2("EHOSTUNREACH: No route to host")
	else if(err == 114):
		println2("EALREADY: Operation already in progress")
	else if(err == 115):
		println2("EINPROGRESS: Operation now in progress")
	else if(err == 116):
		println2("ESTALE: Stale file handle")
	else if(err == 117):
		println2("EUCLEAN: Structure needs cleaning")
	else if(err == 118):
		println2("ENOTNAM: Not a XENIX named type file")
	else if(err == 119):
		println2("ENAVAIL: No XENIX semaphores available")
	else if(err == 120):
		println2("EISNAM: Is a named type file")
	else if(err == 121):
		println2("EREMOTEIO: Remote I/O error")
	else if(err == 122):
		println2("EDQUOT: Quota exceeded")
	else if(err == 123):
		println2("ENOMEDIUM: No medium found")
	else if(err == 124):
		println2("EMEDIUMTYPE: Wrong medium type")
	else if(err == 125):
		println2("ECANCELED: Operation Canceled")
	else if(err == 126):
		println2("ENOKEY: Required key not available")
	else if(err == 127):
		println2("EKEYEXPIRED: Key has expired")
	else if(err == 128):
		println2("EKEYREVOKED: Key has been revoked")
	else if(err == 129):
		println2("EKEYREJECTED: Key was rejected by service")
	else if(err == 130):
		println2("EOWNERDEAD: Owner died")
	else if(err == 131):
		println2("ENOTRECOVERABLE: State not recoverable")
	else if(err == 132):
		println2("ERFKILL: Operation not possible due to RF-kill")
	else if(err == 133):
		println2("EHWPOISON: Memory page has hardware error")
	else:
		println2("Unknown error number")
	exit(1)

