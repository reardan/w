# Windows x64 "syscall" layer. Windows has no stable raw-syscall ABI, so
# every primitive is implemented on kernel32.dll imports that arrive
# through the PE import table (code_generator/pe_64.w). The module keeps
# the same function surface as the Linux per-arch modules where a
# reasonable mapping exists, so lib/ code compiles unchanged; primitives
# with no Windows equivalent return -1 (see the bottom of the file).

c_lib "kernel32.dll"
extern void ExitProcess(int code)
extern int GetStdHandle(int which)
extern int WriteFile(int handle, char* buf, int len, int* written, int overlapped)
extern int ReadFile(int handle, char* buf, int len, int* nread, int overlapped)
extern int CreateFileA(char* path, int access, int share, int security, int creation, int flags, int template_file)
extern int CloseHandle(int handle)
extern int SetFilePointer(int handle, int distance, int* distance_high, int method)
extern int DeleteFileA(char* path)
extern int FlushFileBuffers(int handle)
extern int VirtualAlloc(int addr, int size, int alloc_type, int protect)
extern int VirtualFree(int addr, int size, int free_type)
extern int VirtualProtect(int addr, int size, int new_protect, int* old_protect)
extern char* GetCommandLineA()
extern int GetLastError()
extern void Sleep(int milliseconds)
extern void GetSystemTimeAsFileTime(int* filetime)
extern int QueryPerformanceCounter(int* count)
extern int QueryPerformanceFrequency(int* frequency)
extern int CreateDirectoryA(char* path, int security)
extern int RemoveDirectoryA(char* path)
extern int GetCurrentDirectoryA(int size, char* buf)
extern int SetCurrentDirectoryA(char* path)
extern int GetCurrentProcessId()
extern int CreateProcessA(char* app, char* cmdline, int proc_attr, int thread_attr, int inherit_handles, int flags, int env, char* dir, char* startup_info, char* proc_info)
extern int WaitForSingleObject(int handle, int milliseconds)
extern int GetExitCodeProcess(int handle, int* code)
extern int CreatePipe(int* read_end, int* write_end, int security, int size)
extern int TerminateProcess(int handle, int exit_code)
extern int SetHandleInformation(int handle, int mask, int flags)
extern int PeekNamedPipe(int handle, char* buf, int buf_size, int* bytes_read, int* bytes_avail, int* bytes_left)
extern int GetCurrentProcess()
extern int FindFirstFileA(char* pattern, char* find_data)
extern int FindNextFileA(int handle, char* find_data)
extern int FindClose(int handle)


/* File IO: */

# Standard descriptors 0/1/2 map to the console handles; anything else is
# already a Windows handle returned by open/create_file.
int win_handle_for_fd(int fd):
	if (fd == 0):
		return GetStdHandle(-10)
	if (fd == 1):
		return GetStdHandle(-11)
	if (fd == 2):
		return GetStdHandle(-12)
	return fd


# mode uses the Linux open(2) flag encoding the rest of lib/ passes in:
# low two bits select read/write, 0x40 is O_CREAT, 0x200 is O_TRUNC.
int open(char *filename, int mode, int permissions):
	int access = 2147483648 /* GENERIC_READ */
	int rw = mode & 3
	if (rw == 1):
		access = 1073741824 /* GENERIC_WRITE */
	if (rw == 2):
		access = 2147483648 + 1073741824
	int creation = 3 /* OPEN_EXISTING */
	if (mode & 64):
		if (mode & 512):
			creation = 2 /* CREATE_ALWAYS */
		else:
			creation = 4 /* OPEN_ALWAYS */
	else if (mode & 512):
		creation = 5 /* TRUNCATE_EXISTING */
	/* share read+write, no security attributes, normal attributes */
	int handle = CreateFileA(filename, access, 3, 0, creation, 128, 0)
	if (handle == -1):
		return -1
	return handle


int create_file(char* filename, int permissions):
	int handle = CreateFileA(filename, 1073741824, 3, 0, 2, 128, 0)
	if (handle == -1):
		return -1
	return handle


int write(int file, char* s, int length):
	int written = 0
	if (WriteFile(win_handle_for_fd(file), s, length, &written, 0) == 0):
		return -1
	return written


int read(int file, char* buf, int size):
	int nread = 0
	if (ReadFile(win_handle_for_fd(file), buf, size, &nread, 0) == 0):
		return -1
	return nread


int close(int file):
	if (CloseHandle(file) == 0):
		return -1
	return 0


# reference: 0 - beginning, 1 - current position, 2 - end of file
# (FILE_BEGIN / FILE_CURRENT / FILE_END use the same values).
int seek(int file, int offset, int reference):
	return SetFilePointer(file, offset, 0, reference)


int unlink(char* path):
	if (DeleteFileA(path) == 0):
		return -1
	return 0


# FlushFileBuffers forces the file's buffered data to disk, the
# kernel32 equivalent of fsync(2).
int fsync(int file):
	if (FlushFileBuffers(win_handle_for_fd(file)) == 0):
		return -1
	return 0


# No separate data-only flush on kernel32; fsync's guarantee is a
# superset.
int fdatasync(int file):
	return fsync(file)


# Directory syscalls:
int mkdir(char* path, int mode):
	if (CreateDirectoryA(path, 0) == 0):
		return -1
	return 0


int rmdir(char* path):
	if (RemoveDirectoryA(path) == 0):
		return -1
	return 0


int chdir(char* path):
	if (SetCurrentDirectoryA(path) == 0):
		return -1
	return 0


# Linux getcwd returns the string length including the terminator.
int getcwd(char* buf, int size):
	int len = GetCurrentDirectoryA(size, buf)
	if (len == 0):
		return -1
	return len + 1


/* Time */

# Seconds since the Unix epoch. FILETIME counts 100ns units since
# 1601-01-01; the offset between the epochs is 11644473600 seconds
# (134774 days). That value overflows the compiler's 32-bit literal
# decode (grammar/int_literal.w rejects it), so it is computed at
# runtime as days * seconds-per-day in the target's 64-bit registers —
# the bare literal used to silently wrap to a wrong constant here.
int linux_time(int* out):
	int filetime = 0
	GetSystemTimeAsFileTime(&filetime)
	int seconds = filetime / 10000000 - 134774 * 86400
	if (out != 0):
		*out = seconds
	return seconds


# clock_id 1 is CLOCK_MONOTONIC. out points at a timespec of two words
# (seconds, nanoseconds), matching the Linux x64 module.
int clock_gettime(int clock_id, int* out):
	int count = 0
	int frequency = 0
	QueryPerformanceCounter(&count)
	QueryPerformanceFrequency(&frequency)
	if (frequency == 0):
		return -1
	out[0] = count / frequency
	# The remainder is below the frequency (usually 10MHz), so the
	# multiplication by 1e9 stays far from overflowing 64 bits.
	out[1] = (count % frequency) * 1000000000 / frequency
	return 0


int sys_clock_gettime(int clock_id, int ts):
	return clock_gettime(clock_id, cast(int*, ts))


# req points at a timespec (seconds, nanoseconds); Windows sleeps in
# integer milliseconds, rounding up so short sleeps do not spin.
int nanosleep(int* req, int* rem):
	int ms = req[0] * 1000 + (req[1] + 999999) / 1000000
	Sleep(ms)
	return 0


int sys_nanosleep(int req, int rem):
	return nanosleep(cast(int*, req), cast(int*, rem))


/* memory and threading */

# brk emulation on VirtualAlloc: a 256MB region is reserved up front and
# committed as the break grows. lib/memory.w's allocator only ever moves
# the break upward; when the region runs out it falls back to mmap.
int win_brk_base
int win_brk_end
int win_brk_committed


int win_brk_reserve_size():
	return 268435456 /* 256MB */


int brk(char* addr):
	int target = cast(int, addr)
	if (win_brk_base == 0):
		win_brk_base = VirtualAlloc(0, win_brk_reserve_size(), 8192, 4) /* MEM_RESERVE, PAGE_READWRITE */
		win_brk_end = win_brk_base
		win_brk_committed = win_brk_base
	if (target == 0):
		return win_brk_end
	# Like Linux brk, failure returns the unchanged break.
	if (target < win_brk_base):
		return win_brk_end
	if (target > win_brk_base + win_brk_reserve_size()):
		return win_brk_end
	if (target > win_brk_committed):
		int grow = target - win_brk_committed
		grow = ((grow + 65535) >> 16) << 16
		if (VirtualAlloc(win_brk_committed, grow, 4096, 4) == 0): /* MEM_COMMIT */
			return win_brk_end
		win_brk_committed = win_brk_committed + grow
	win_brk_end = target
	return win_brk_end


# prot 3 (read+write) maps to PAGE_READWRITE, anything with execute to
# PAGE_EXECUTE_READWRITE. flags (MAP_PRIVATE|MAP_ANONYMOUS) are implied.
# Returns -ENOMEM on failure like the Linux wrappers.
int mmap(int addr, int length, int prot, int flags):
	int protect = 4 /* PAGE_READWRITE */
	if (prot & 4):
		protect = 64 /* PAGE_EXECUTE_READWRITE */
	int base = VirtualAlloc(0, length, 12288, protect) /* MEM_RESERVE|MEM_COMMIT */
	if (base == 0):
		return -12
	return base


int munmap(int addr, int length):
	if (VirtualFree(addr, 0, 32768) == 0): /* MEM_RELEASE frees the whole allocation */
		return -1
	return 0


# prot 0 (PROT_NONE) maps to PAGE_NOACCESS, anything with execute to
# PAGE_EXECUTE_READWRITE, otherwise PAGE_READWRITE (mirrors mmap above).
# Returns -1 on failure like the Linux wrappers; the previous protection
# (which every caller here ignores) goes to a throwaway out-param.
int mprotect(int addr, int length, int prot):
	int protect = 1 /* PAGE_NOACCESS */
	if (prot != 0):
		protect = 4 /* PAGE_READWRITE */
		if (prot & 4):
			protect = 64 /* PAGE_EXECUTE_READWRITE */
	int old_protect = 0
	if (VirtualProtect(addr, length, protect, &old_protect) == 0):
		return -1
	return 0


/* Process management */

int getpid():
	return GetCurrentProcessId()


void exit(int error_code):
	ExitProcess(error_code)


# Windows threads are not wired up yet; a lone "thread" exiting ends the
# process, matching what a single-threaded Linux program observes.
void thread_exit(int error_code):
	ExitProcess(error_code)


# Primitives with no win64 implementation yet. They fail with -1 (the
# Linux wrappers' error convention) instead of being left undefined, so
# importing a module that merely mentions them still compiles; programs
# exercising them get a visible runtime error. Sockets are deliberately
# absent: lib/net.w does not compile on win64.

int getdents(int file, char* buf, int count):
	return -1


int fork():
	return -1


int execve(char* path, char** argv, char** envp):
	return -1


int wait4(int pid, int* status, int options, int rusage):
	return -1


# Create an anonymous pipe via CreatePipe. Returns 0 on success, -1 on failure.
# The two int32 fd values are stored at fds[0] (read end) and fds[1] (write end),
# matching the Linux pipe(2) layout that lib/process.w expects.
int pipe(int* fds):
	int read_end = 0
	int write_end = 0
	if (CreatePipe(&read_end, &write_end, 0, 0) == 0):
		return -1
	save_int32(cast(char*, fds), read_end)
	save_int32(cast(char*, fds) + 4, write_end)
	return 0


# Windows has no dup2; this stub keeps code that merely mentions it linkable.
int dup2(int oldfd, int newfd):
	return -1


int kill(int pid, int sig):
	return -1


# Returns 1 when running on Windows, 0 on all other platforms.
int os_windows():
	return 1


# ptrace has no win64 equivalent; the stub keeps the debugger's attach
# module linkable (attach mode is Linux x86/x86-64 only).
int sys_ptrace(int request, int pid, int addr, int data):
	return -1


int sys_clone(int flags, int child_stack):
	return -1


int sys_fcntl(int fd, int cmd, int arg):
	return -1


int sys_ioctl(int fd, int request, int arg):
	return -1


int sys_poll(int fds, int nfds, int timeout_ms):
	return -1


int poll(int* fds, int nfds, int timeout_ms):
	return -1


int sys_mincore(int addr, int length, int vec):
	return -1


int rt_sigaction(int signum, int* act, int* oldact):
	return -1


/* Startup */

# The PE entry stub calls _win_start (see code_generator/pe_64.w), which
# rebuilds the W (argc, argv) contract from the Windows command line and
# chains to _main. Memory comes from mmap directly because lib/memory.w's
# malloc is not necessarily part of the program.
int _main(int argc, int argv);


# Splits the command line the way everything expects argv: arguments are
# separated by spaces/tabs, double quotes group words. (The full
# CommandLineToArgvW backslash rules are not implemented.)
int _win_start(int stub_argc, int stub_argv):
	char* cmd = GetCommandLineA()
	int len = 0
	while (cmd[len] != 0):
		len = len + 1
	# Worst case one argument per two characters; the block holds the
	# argv array, a null environment vector, then the unquoted copy.
	int max_args = len / 2 + 2
	int block = mmap(0, (max_args + 2) * 8 + len + 1, 3, 34)
	if (block < 0):
		return _main(stub_argc, stub_argv)
	char** argv = cast(char**, block)
	char* buf = cast(char*, block + (max_args + 2) * 8)
	int argc = 0
	int i = 0
	int b = 0
	while (cmd[i] != 0):
		while ((cmd[i] == ' ') || (cmd[i] == 9)):
			i = i + 1
		if (cmd[i] == 0):
			break
		argv[argc] = buf + b
		argc = argc + 1
		int quoted = 0
		while (cmd[i] != 0):
			if (cmd[i] == 34): /* double quote toggles word grouping */
				quoted = 1 - quoted
				i = i + 1
			else if ((quoted == 0) && ((cmd[i] == ' ') || (cmd[i] == 9))):
				break
			else:
				buf[b] = cmd[i]
				b = b + 1
				i = i + 1
		buf[b] = 0
		b = b + 1
	argv[argc] = cast(char*, 0)
	argv[argc + 1] = cast(char*, 0) /* empty environment vector */
	return _main(argc, cast(int, argv))
