char *code
int code_size
int codepos
int code_offset

void save_int(char *p, int n):
	p[0] = n
	p[1] = n >> 8
	p[2] = n >> 16
	p[3] = n >> 24


int load_int(char *p):
	return ((p[0] & 255) + ((p[1] & 255) << 8) +
					((p[2] & 255) << 16) + ((p[3] & 255) << 24))


void emit(int n, char *s):
	int i = 0
	if (code_size <= codepos + n):
		int x = (codepos + n) << 1
		code = realloc(code, code_size, x)
		code_size = x

	while (i <= n - 1):
		code[codepos] = s[i]
		codepos = codepos + 1
		i = i + 1



void be_push():
	emit(1, "\x50") /* push %eax */


void be_pop(int n):
	emit(6, "\x81\xc4....") /* add $(n * 4),%esp */
	save_int(code + codepos - 4, n << 2)


void sym_define_declare_global_function(char* name); /* defined in symbol_table */


void be_start():
	emit(16, "\x7f\x45\x4c\x46\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00")
	emit(16, "\x02\x00\x03\x00\x01\x00\x00\x00\x54\x80\x04\x08\x34\x00\x00\x00")
	emit(16, "\x00\x00\x00\x00\x00\x00\x00\x00\x34\x00\x20\x00\x01\x00\x00\x00")
	emit(16, "\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x80\x04\x08")
	emit(16, "\x00\x80\x04\x08\x10\x4b\x00\x00\x10\x4b\x00\x00\x07\x00\x00\x00")
	emit(4, "\x00\x10\x00\x00")

	/* setup command line args */
	emit(5, "\x8d\x44\x24\x04\x50")
	/* lea eax, [esp+4]; push eax */

	emit(5, "\xe8....")
	/* call [first function ] - set with the save_int() at the end of this func */

	sym_define_declare_global_function("exit")
	/* pop %ebx ; pop %ebx ; xor %eax,%eax ; inc %eax ; int $0x80 */
	emit(7, "\x5b\x5b\x31\xc0\x40\xcd\x80")

	sym_define_declare_global_function("malloc")
	/* mov 4(%esp),%eax */
	emit(4, "\x8b\x44\x24\x04")
	/* push %eax ; xor %ebx,%ebx ; mov $45,%eax ; int $0x80 */
	emit(10, "\x50\x31\xdb\xb8\x2d\x00\x00\x00\xcd\x80")
	/* pop %ebx ; add %eax,%ebx ; push %eax ; push %ebx ; mov $45,%eax */
	emit(10, "\x5b\x01\xc3\x50\x53\xb8\x2d\x00\x00\x00")
	/* int $0x80 ; pop %ebx ; cmp %eax,%ebx ; pop %eax ; je . + 7 */
	emit(8, "\xcd\x80\x5b\x39\xc3\x58\x74\x05")
	/* mov $-1,%eax ; ret */
	emit(6, "\xb8\xff\xff\xff\xff\xc3")

	sym_define_declare_global_function("putchar")
	/* mov $4,%eax ; xor %ebx,%ebx ; inc %ebx */
	emit(8, "\xb8\x04\x00\x00\x00\x31\xdb\x43")
	/*  lea 4(%esp),%ecx ; mov %ebx,%edx ; int $0x80 ; ret */
	emit(9, "\x8d\x4c\x24\x04\x89\xda\xcd\x80\xc3")

	sym_define_declare_global_function("puterror")
	/* mov $4,%eax ; xor %ebx,%ebx ; inc %ebx */
	emit(8, "\xb8\x04\x00\x00\x00\x31\xdb\x43")
	/*  lea 4(%esp),%ecx ; mov %ebx,%edx ; inc %ebx ; int $0x80 ; ret */
	emit(10, "\x8d\x4c\x24\x04\x89\xda\x43\xcd\x80\xc3")

	sym_define_declare_global_function("syscall")
	/* mov eax,[esp+16] ; mov ebx,[esp+12] ; mov ecx,[esp+8] ; mov edx,[esp+4] ; int 0x80 ; ret */
	emit(19, "\x8b\x44\x24\x10\x8b\x5c\x24\x0c\x8b\x4c\x24\x08\x8b\x54\x24\x04\xcd\x80\xc3")

	# OG: 85, 89
	save_int(code + 90, codepos - 94) /* entry set to first thing in file */


void be_finish():
	save_int(code + 68, codepos)
	save_int(code + 72, codepos)
	int i = 0
	while (i <= codepos - 1):
		putchar(code[i])
		i = i + 1
