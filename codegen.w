import integer


char *code
int code_size
int codepos
int base_code_offset
int code_offset


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


void emit_string_raw(char* s):
	print_int("strlen(s)= ", strlen(s))
	emit(strlen(s), s)


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


################################# x86 opcodes #################################
void push_int8(int v):
	emit_int8("\x6a") /* push dword 0x12 */
	emit_int8(v)


void push_int32(int v):
	emit_int8("\x68") /* push dword 0x12345678 */
	emit_int32(v)


void push_int(int v):
	push_int32(v)


void mov_eax_int32(int v):
	emit(1, "\xb8") /* mov eax, 0x12345678 */
	emit_int32(v)


void mov_eax_int(int v):
	mov_eax_int32(v)


void push_eax():
	emit(1, "\x50") /* push %eax */


void lea_eax_esp_plus(int v):
	emit(3, "\x8d\x84\x24") /* lea eax,[esp+0x12345678] */
	emit_int(v)


void store_stack_var(int variable_offset):
	emit(3, "\x89\x84\x24") /* mov [esp+0x12345678], eax */
	emit_int(variable_offset)


void be_pop(int n):
	emit(6, "\x81\xc4....") /* add $(n * 4),%esp */
	save_int(code + codepos - 4, n << 2)


char* compare_opcode(char* opcode_charp):
	char* result = "\x5b\x39\xc3\x0f\x9c\xc0\x0f\xb6\xc0"
	/* pop %ebx ; cmp %eax,%ebx ; OPCODE (e.g. "\x9c" for setl %al) ; movzbl %al,%eax */
	result[4] = opcode_charp[0]
	return result


############################## end of x86 opcodes ##############################


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
	base_code_offset = 134512640 /* 0x00804800 */
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

	sym_define_declare_global_function("syscall6")
	/* mov eax,[esp+24] ; mov ebx,[esp+20] ; mov ecx,[esp+16] ; mov edx,[esp+12] ; mov esi,[esp+8] ; mov edi,[esp+4] ; int 0x80 ; ret */
	emit(20, "\x8b\x44\x24\x18\x8b\x5c\x24\x14\x8b\x4c\x24\x10\x8b\x54\x24\x0c\x8b\x74\x24\x08")
	emit(7, "\x8b\x7c\x24\x04\xcd\x80\xc3")

	sym_define_declare_global_function("syscall7")
	/* mov eax,[esp+28] ; mov ebx,[esp+24] ; mov ecx,[esp+20] ; mov edx,[esp+16] ; mov esi,[esp+12] ; mov edi,[esp+8] ; mov ebp,[esp+4] ; int 0x80 ; ret */
	emit(20, "\x8b\x44\x24\x1c\x8b\x5c\x24\x18\x8b\x4c\x24\x14\x8b\x54\x24\x10\x8b\x74\x24\x0c")
	emit(10, "\x89\x68\x14\x89\x70\x18\x89\x78\x1c\xc3")

	# debug
	sym_define_declare_global_function("get_context")
	# push eax; mov eax,[esp+8] ; mov [eax+4],ecx ; pop ecx ; mov [eax+0],ecx ; mov [eax+8],edx ; mov [eax+12],ebx; mov [eax+16],esp ; mov [eax+20], ebp ; mov [eax+24], esi ; mov [eax+28],edi ; ret
	emit(20, "\x50\x8b\x44\x24\x08\x89\x48\x04\x59\x89\x08\x89\x50\x08\x89\x58\x0c\x89\x60\x10")
	emit(10, "\x89\x78\x14\x89\x70\x18\x89\x78\x1c\xc3")

	# push eax ; mov eax,[esp+8] ; mov [eax+4],ecx ; mov [eax+8],edx ; mov [eax+12],ebx ; mov [eax+16],esp ; mov [eax+20],ebp ; mov [eax+24],esi ; mov [eax+28],edi ; pop eax ; ret ; 
	sym_define_declare_global_function("store_context")
	emit(20, "\x50\x8b\x44\x24\x08\x89\x48\x04\x89\x50\x08\x89\x58\x0c\x89\x60\x10\x89\x68\x14")
	emit(9, "\x89\x70\x18\x89\x78\x1c\x58\xc3")

	# endian
	sym_define_declare_global_function("swap_endian")
	emit(7, "\x8b\x44\x24\x04\x0f\xc8\xc3")

	sym_define_declare_global_function("swap_endian16")
	emit(11, "\x8b\x44\x24\x04\x0f\xc8\xb1\x10\xd3\xfb\xc3")

	# tcp.asm
	sym_define_declare_global_function("socket_connect")
	emit(52, "\xb8\x66\x00\x00\x00\xbb\x01\x00\x00\x00\x31\xd2\x52\x53\x6a\x02\x89\xe1\xcd\x80\x92\xb0\x66\x68\x7f\x01\x01\x01\x66\x68\x11\x5c\x43\x66\x53\x89\xe1\x6a\x10\x51\x52\x89\xe1\x43\xcd\x80\x83\xc4\x20\x89\xd0\xc3")

	sym_define_declare_global_function("socket_connect_new")
	emit(76, "\xb8\x66\x00\x00\x00\xbb\x01\x00\x00\x00\x31\xd2\x6a\x00\x6a\x01\x6a\x02\x89\xe1\xcd\x80\x83\xc4\x0c\x50\x50\xb8\x66\x00\x00\x00\x8b\x54\x24\x04\x83\xc4\x08\x68\x7f\x01\x01\x01\x66\x68\x11\x5c\xbb\x02\x00\x00\x00\x66\x53\x89\xe1\x6a\x10\x51\x52\x89\xe1\xbb\x03\x00\x00\x00\xcd\x80\x83\xc4\x14\x89\xd0\xc3")

	sym_define_declare_global_function("socket")
	emit(35, "\x8b\x44\x24\x04\x8b\x5c\x24\x08\x8b\x4c\x24\x0c\x50\x53\x51\x89\xe1\xb8\x66\x00\x00\x00\xbb\x01\x00\x00\x00\x31\xd2\xcd\x80\x83\xc4\x0c\xc3")

	sym_define_declare_global_function("connect")
	emit(55, "\x89\xe5\x8b\x55\x0c\x8b\x45\x08\x8b\x5d\x04\x0f\xc8\x50\x0f\xcb\xb1\x10\xd3\xfb\x66\x53\xbb\x02\x00\x00\x00\x66\x53\x89\xe1\x6a\x10\x51\x52\x89\xe1\xb8\x66\x00\x00\x00\xbb\x03\x00\x00\x00\xcd\x80\x83\xc4\x14\x89\xd0\xc3")

	sym_define_declare_global_function("setsockopt")
	emit(30, "\x8b\x54\x24\x04\x6a\x04\x54\x6a\x02\x6a\x01\x52\x89\xe1\xb8\x66\x00\x00\x00\xbb\x0e\x00\x00\x00\xcd\x80\x83\xc4\x14\xc3")

	sym_define_declare_global_function("bind")
	emit(45, "\x8b\x54\x24\x08\x8b\x5c\x24\x04\x0f\xcb\xb1\x10\xd3\xfb\x6a\x00\x66\x53\x66\x6a\x02\x89\xe1\x6a\x10\x51\x52\xb8\x66\x00\x00\x00\xbb\x02\x00\x00\x00\x89\xe1\xcd\x80\x83\xc4\x14\xc3")

	sym_define_declare_global_function("listen")
	emit(27, "\x8b\x54\x24\x04\x6a\x00\x52\x89\xe1\xb8\x66\x00\x00\x00\xbb\x04\x00\x00\x00\xcd\x80\x83\xc4\x08\x89\xd0\xc3")

	sym_define_declare_global_function("socket_accept")
	emit(29, "\x8b\x54\x24\x04\xb8\x66\x00\x00\x00\xbb\x05\x00\x00\x00\x6a\x00\x6a\x00\x52\x89\xe1\xcd\x80\x89\xc2\x83\xc4\x0c\xc3")

	# thread_i386.s
	sym_define_declare_global_function("thread_create")
	emit(54, "\x53\xe8\x15\x00\x00\x00\x8d\x88\xf8\xff\x3f\x00\x8f\x01\xbb\x00\x8f\x01\x80\xb8\x78\x00\x00\x00\xcd\x80\xc3")
	
	sym_define_declare_global_function("stack_create")
	emit(28, "\xbb\x00\x00\x00\x00\xb9\x00\x00\x40\x00\xba\x03\x00\x00\x00\xbe\x22\x01\x00\x00\xb8\xc0\x00\x00\x00\xcd\x80\xc3")

	# function_call(func_ptr)
	sym_define_declare_global_function("function_call")
	# mov eax,[esp+4]; jmp eax
	emit(6, "\x8b\x44\x24\x04\xff\xe0")


int sym_address(char *s);
void be_finish():
	if (verbosity > 0):
		print_error("codepos: '")
		print_error(hex(codepos))
		print_error("'\x0a")

	# Store pointer to library _main()
	int t = sym_address("_main")
	# As a backup, try to use main()
	# TODO: should we allow this?
	if (t == 0):
		t = sym_address("main")
	if (t == 0):
		error("Failed to find a _main() function. Did you import lib/testing?")
	# Should we fix the asm so it doesnt crash on return?
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

	write(1, code, codepos)
