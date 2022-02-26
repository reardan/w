char *code
int code_size
int codepos
int base_code_offset
int code_offset


void save_i(char* p, int v, int n):
	int i = 0
	while (i < n):
		p[i] = v
		v = v >> 8
		i = i + 1


void save_int(char *p, int v):
	save_i(p, v, 4)


int load_int(char *p):
	return ((p[0] & 255) + ((p[1] & 255) << 8) +
					((p[2] & 255) << 16) + ((p[3] & 255) << 24))


void resize_code(int n):
	if (code_size <= codepos + n):
		int x = (codepos + n) << 1
		code = realloc(code, code_size, x)
		code_size = x


void emit(int n, char *s):
	resize_code(n)
	int i = 0
	while (i <= n - 1):
		code[codepos] = s[i]
		codepos = codepos + 1
		i = i + 1


void emit_string(char* s):
	emit(strlen(s) + 1, s)


void emit_i(int v, int n):
	resize_code(n)
	char* p = code + codepos
	save_i(p, v, n)
	codepos = codepos + n


void emit_int8(int v):
	emit_i(v, 1)


void emit_int16(int v):
	emit_i(v, 2)


void emit_int32(int v):
	emit_i(v, 4)


void emit_int(int v):
	emit_int32(v)


void be_push():
	emit(1, "\x50") /* push %eax */


void be_pop(int n):
	emit(6, "\x81\xc4....") /* add $(n * 4),%esp */
	save_int(code + codepos - 4, n << 2)


void sym_define_declare_global_function(char* name); /* defined in symbol_table */


void elf_header():
	/* ELF Header: 52 bytes */
	/* NIDENT */
	emit(4, "\x7f\x45\x4c\x46") /* magic */
	emit(1, "\x01") /* class: 0: none, 1: 32 bit, 2: 64 bit. */
	emit(1, "\x01") /* data encoding: 0: none, 1: Least signficiant, 2: Most significant */
	emit(1, "\x01") /* version: always 1 */
	emit(1, "\x00") /* OS ABI: 0: none (usually used), 1: HP-UX, 2: NetBSD, 3: Linux */
	emit(1, "\x00") /* ABI VERSION */
	emit(7, "\x00\x00\x00\x00\x00\x00\x00") /* padding */

	/* ElfHeader32 */
	emit(2, "\x02\x00") /* type */
	emit(2, "\x03\x00")  /* machine */
	emit(4, "\x01\x00\x00\x00") /* version */
	emit(4, "\x54\x80\x04\x08") /* entry */
	emit(4, "\x34\x00\x00\x00") /* program header offset */
	emit(4, "\x00\x00\x00\x00") /* segment header offset */
	emit(4, "\x00\x00\x00\x00") /* flags */
	emit(2, "\x34\x00") /* size of this elf header */
	emit(2, "\x20\x00") /* size per program header */
	emit(2, "\x01\x00") /* number of program headers */
	emit(2, "\x28\x00") /* size per section header  */
	emit(2, "\x00\x00") /* number of section headers */
	emit(2, "\x00\x00") /* section header string table index */


/* ProgramHeader32: 32 bytes */
void elf_program_header(int type):
	emit_int(type) /* type: 0: NULL, 1: LOAD, 2: DYNAMIC, ... */
	emit_int(0) /* offset: where in the elf file the content of this segment is located */
	emit(4, "\x00\x80\x04\x08") /* vaddr: where first byte will be in memory */
	emit(4, "\x00\x80\x04\x08") /* paddr: physical memory address, not usually used (e.g. firmware) */
	emit(4, "\x10\x4b\x00\x00") /* filesz: size of segment in file, 0=no content */
	emit(4, "\x10\x4b\x00\x00") /* memsz: size of the segment in memory */
	emit(4, "\x07\x00\x00\x00") /* flags: X, W, R */
	emit(4, "\x00\x10\x00\x00") /* align: byte boundary e.g. 4/8 */


/* SectionHeader32: 40 bytes */
void elf_section_header(int type):
	emit_int(0) /* name: string index */
	emit_int(type) /* type: 2: sym_table, 3: string table */
	emit_int(0) /* flags: 0x1: write, 0x2: alloc, 0x4: exec */
	emit_int(0) /* addr */
	emit_int(0) /* offset */
	emit_int(0) /* size */
	emit_int(1) /* link: strings section that we're linked with */
	emit_int(0) /* info (num symbols in symtable, etc.) */
	emit_int(1) /* addralign (1,2,4,8,16,32 typically used) */
	emit_int(16) /* entry size */
	/* # entries = size / entry size */


void elf_sym_table_entry(int name, int address, int size, int binding, int symtype, int type):
	emit_int(name) /* name */
	emit_int(address) /* address */
	emit_int(size) /* size */
	/* binding: 0:local, 1:global, 2:weak */
	/* symtype: 0:none, 1:object, 2:func, ... */
	int info = (binding << 4) + (symtype & 15)
	emit_int8(info) /* info */
	emit_int8(0) /* other: visibility */
	emit_int16(type) /* shndx */


void be_start():
	base_code_offset = 134512640 /* 0x08048000 */
	code_offset = base_code_offset

	elf_header()
	elf_program_header(1)
	 /* TODO: Symbol Table Header: 32 bytes */

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

	sym_define_declare_global_function("syscall")
	/* mov eax,[esp+16] ; mov ebx,[esp+12] ; mov ecx,[esp+8] ; mov edx,[esp+4] ; int 0x80 ; ret */
	emit(19, "\x8b\x44\x24\x10\x8b\x5c\x24\x0c\x8b\x4c\x24\x08\x8b\x54\x24\x04\xcd\x80\xc3")

	# OG: 85, 89
	save_int(code + 90, codepos - 94) /* entry set to first thing in file */
	if (verbosity > 0):
		print_error("codepos - 94: ")
		print_error(itoa(codepos - 94))
		print_error("\x0a")


int sym_address(char *s);
void be_finish():
	if (verbosity > 0):
		print_error("codepos: '")
		print_error(hex(codepos))
		print_error("'\x0a")

	# Store pointer to library _main()
	int t = sym_address("_main")
	t = t - code_offset - 94

	if (verbosity > 0):
		print_error("looking up _main() t = ")
		print_error(itoa(t))
		print_error("\x0aold start = ")
		print_error(itoa(load_int(code + 90)))
		print_error("\x0a")

	save_int(code + 90, t)

	# Save the size
	save_int(code + 68, codepos) /* FileSize */
	save_int(code + 72, codepos) /* MemSize */
	write(1, code, codepos - 1)
