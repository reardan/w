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
extern int MoveFileA(char* oldpath, char* newpath)
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
extern int VirtualQuery(int addr, char* info, int length)
extern char* GetEnvironmentStringsA()
extern int AddVectoredExceptionHandler(int first, int handler)
extern int FlushInstructionCache(int process, int addr, int size)
extern int GetModuleHandleA(char* name)
extern int LoadLibraryA(char* name)
extern int GetProcAddress(int module, char* name)


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
	int flags = 128
	if (rw == 0):
		# FILE_FLAG_BACKUP_SEMANTICS lets a read-only open succeed on a
		# directory, as open(dir, O_RDONLY) does on Linux (existence
		# probes rely on it); reads from such a handle simply fail.
		flags = flags + 33554432
	int handle = CreateFileA(filename, access, 3, 0, creation, flags, 0)
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


int rename(char* oldpath, char* newpath):
	if (MoveFileA(oldpath, newpath) == 0):
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


# Portable metadata wrappers are Linux-first (lib/stat.w).
int at_fdcwd():
	return 0 - 100


int at_symlink_nofollow():
	return 256


int statx(char* path, int flags, int mask, char* buf):
	return -1


# inotify is Linux-only (lib/inotify.w).
int sys_inotify_init1(int flags):
	return -1


int sys_inotify_add_watch(int fd, char* path, int mask):
	return -1


int sys_inotify_rm_watch(int fd, int wd):
	return -1


int chmod(char* path, int mode):
	return -1


int utimensat(char* path, int times, int flags):
	return -1


int fchownat(char* path, int uid, int gid, int flags):
	return -1


int chown(char* path, int uid, int gid):
	return -1


int lchown(char* path, int uid, int gid):
	return -1


int getuid():
	return -1


int getgid():
	return -1


int readlink(char* path, char* buf, int size):
	return -1


int symlink(char* target, char* linkpath):
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


/* C -> W callbacks */

# Page of generated thunks and the fill position inside it.
int win_thunk_page
int win_thunk_used


void win_thunk_byte(char* p, int k, int v):
	p[k] = v


/*
Returns the address of a Microsoft-x64-ABI function that forwards its
first nargs arguments (up to 16, all word-sized integers or pointers) to
the W function at fn and returns fn's result in rax. This is how Win32
calls back into W: window procedures, exception filters, thread starts.

W functions take their arguments pushed on the stack in declaration
order (the caller pops them) and may clobber any register, so the thunk
saves every Win64 callee-saved general register, pushes rcx, rdx, r8,
r9 and then the caller's stack arguments (above the 32-byte shadow
space) in order, calls fn, and restores:

	push rbp ; mov rbp,rsp ; push rbx,rsi,rdi,r12..r15
	push rcx ; push rdx ; push r8 ; push r9          (first nargs of them)
	push qword [rbp+48+8k]                            (args 4..nargs-1)
	mov rax,fn ; call rax
	lea rsp,[rbp-56] ; pop r15..r12,rdi,rsi,rbx ; pop rbp ; ret

Float arguments/results and xmm6-xmm15 are not handled (W code never
touches the callee-saved xmm registers). Thunks live in read-execute
pages, flipped writable only while a new thunk is written. Returns 0
when fn is 0 or nargs is out of range.
*/
int win_callback(int fn, int nargs):
	if ((fn == 0) || (nargs < 0) || (nargs > 16)):
		return 0
	int size = 64 + nargs * 7
	if ((win_thunk_page == 0) || (win_thunk_used + size > 4096)):
		win_thunk_page = VirtualAlloc(0, 4096, 12288, 4) /* commit, PAGE_READWRITE */
		if (win_thunk_page == 0):
			return 0
		win_thunk_used = 0
	else:
		int old = 0
		VirtualProtect(win_thunk_page, 4096, 4, &old)
	int start = win_thunk_page + win_thunk_used
	char* p = cast(char*, start)
	int k = 0
	win_thunk_byte(p, 0, 85)        /* push rbp */
	win_thunk_byte(p, 1, 72)        /* mov rbp,rsp */
	win_thunk_byte(p, 2, 137)
	win_thunk_byte(p, 3, 229)
	win_thunk_byte(p, 4, 83)        /* push rbx */
	win_thunk_byte(p, 5, 86)        /* push rsi */
	win_thunk_byte(p, 6, 87)        /* push rdi */
	win_thunk_byte(p, 7, 65)        /* push r12 */
	win_thunk_byte(p, 8, 84)
	win_thunk_byte(p, 9, 65)        /* push r13 */
	win_thunk_byte(p, 10, 85)
	win_thunk_byte(p, 11, 65)       /* push r14 */
	win_thunk_byte(p, 12, 86)
	win_thunk_byte(p, 13, 65)       /* push r15 */
	win_thunk_byte(p, 14, 87)
	k = 15
	if (nargs > 0):
		win_thunk_byte(p, k, 81)    /* push rcx */
		k = k + 1
	if (nargs > 1):
		win_thunk_byte(p, k, 82)    /* push rdx */
		k = k + 1
	if (nargs > 2):
		win_thunk_byte(p, k, 65)    /* push r8 */
		win_thunk_byte(p, k + 1, 80)
		k = k + 2
	if (nargs > 3):
		win_thunk_byte(p, k, 65)    /* push r9 */
		win_thunk_byte(p, k + 1, 81)
		k = k + 2
	int i = 4
	while (i < nargs):
		win_thunk_byte(p, k, 255)   /* push qword [rbp+disp32] */
		win_thunk_byte(p, k + 1, 181)
		save_int32(p + k + 2, 48 + (i - 4) * 8)
		k = k + 6
		i = i + 1
	win_thunk_byte(p, k, 72)        /* mov rax,imm64 */
	win_thunk_byte(p, k + 1, 184)
	save_int64(p + k + 2, fn)
	k = k + 10
	win_thunk_byte(p, k, 255)       /* call rax */
	win_thunk_byte(p, k + 1, 208)
	k = k + 2
	win_thunk_byte(p, k, 72)        /* lea rsp,[rbp-56] */
	win_thunk_byte(p, k + 1, 141)
	win_thunk_byte(p, k + 2, 101)
	win_thunk_byte(p, k + 3, 200)
	k = k + 4
	win_thunk_byte(p, k, 65)        /* pop r15 */
	win_thunk_byte(p, k + 1, 95)
	win_thunk_byte(p, k + 2, 65)    /* pop r14 */
	win_thunk_byte(p, k + 3, 94)
	win_thunk_byte(p, k + 4, 65)    /* pop r13 */
	win_thunk_byte(p, k + 5, 93)
	win_thunk_byte(p, k + 6, 65)    /* pop r12 */
	win_thunk_byte(p, k + 7, 92)
	win_thunk_byte(p, k + 8, 95)    /* pop rdi */
	win_thunk_byte(p, k + 9, 94)    /* pop rsi */
	win_thunk_byte(p, k + 10, 91)   /* pop rbx */
	win_thunk_byte(p, k + 11, 93)   /* pop rbp */
	win_thunk_byte(p, k + 12, 195)  /* ret */
	k = k + 13
	win_thunk_used = win_thunk_used + ((k + 15) & -16)
	int prev = 0
	VirtualProtect(win_thunk_page, 4096, 32, &prev) /* PAGE_EXECUTE_READ */
	FlushInstructionCache(GetCurrentProcess(), start, k)
	return start


/*
The opposite direction: returns a W-callable address that forwards its
nargs word arguments (up to 16) to the Microsoft-x64-ABI function at sym
-- for C function pointers only known at run time (GetProcAddress,
wglGetProcAddress), which extern cannot bind. The Windows counterpart
of lib/dlcall.w's System V dl_trampoline:

	push rbp ; mov rbp,rsp ; and rsp,-16 ; sub rsp,frame
	mov rax,[rbp+off(i)] ; mov [rsp+32+8(i-4)],rax   (args 4..nargs-1)
	mov rcx/rdx/r8/r9,[rbp+off(i)] ; movq xmm_i,<same> (args 0..3)
	mov rax,sym ; call rax
	[movsxd rax,eax] ; leave ; ret

where off(i) = 16 + 8*(nargs-1-i) is W's slot for argument i. Every
register argument is loaded into both its GP and its xmm register (the
win64 convention is positional), so float32/float64 arguments work
when the W function-pointer type declares them as such: the callee
reads the low bits of the xmm register, as with emit_c_abi_call_win64.
ret32 = 1 sign-extends a 32-bit C int result (GLint -1 stays -1);
float results are not supported. Returns 0 when sym is 0 or nargs is
out of range.
*/
int win_c_function(int sym, int nargs, int ret32):
	if ((sym == 0) || (nargs < 0) || (nargs > 16)):
		return 0
	int size = 48 + nargs * 18
	if ((win_thunk_page == 0) || (win_thunk_used + size > 4096)):
		win_thunk_page = VirtualAlloc(0, 4096, 12288, 4) /* commit, PAGE_READWRITE */
		if (win_thunk_page == 0):
			return 0
		win_thunk_used = 0
	else:
		int old = 0
		VirtualProtect(win_thunk_page, 4096, 4, &old)
	int start = win_thunk_page + win_thunk_used
	char* p = cast(char*, start)
	int stack_args = 0
	if (nargs > 4):
		stack_args = nargs - 4
	int frame = 32 + stack_args * 8
	if ((frame & 15) != 0):
		frame = frame + 8
	win_thunk_byte(p, 0, 85)        /* push rbp */
	win_thunk_byte(p, 1, 72)        /* mov rbp,rsp */
	win_thunk_byte(p, 2, 137)
	win_thunk_byte(p, 3, 229)
	win_thunk_byte(p, 4, 72)        /* and rsp,-16 */
	win_thunk_byte(p, 5, 131)
	win_thunk_byte(p, 6, 228)
	win_thunk_byte(p, 7, 240)
	win_thunk_byte(p, 8, 72)        /* sub rsp,imm32 */
	win_thunk_byte(p, 9, 129)
	win_thunk_byte(p, 10, 236)
	save_int32(p + 11, frame)
	int k = 15
	int i = 4
	while (i < nargs):
		win_thunk_byte(p, k, 72)    /* mov rax,[rbp+disp32] */
		win_thunk_byte(p, k + 1, 139)
		win_thunk_byte(p, k + 2, 133)
		save_int32(p + k + 3, 16 + (nargs - 1 - i) * 8)
		win_thunk_byte(p, k + 7, 72)    /* mov [rsp+disp32],rax */
		win_thunk_byte(p, k + 8, 137)
		win_thunk_byte(p, k + 9, 132)
		win_thunk_byte(p, k + 10, 36)
		save_int32(p + k + 11, 32 + (i - 4) * 8)
		k = k + 15
		i = i + 1
	# REX prefix, ModRM of mov reg,[rbp+disp32] and of movq xmm_i,reg
	# for rcx/xmm0, rdx/xmm1, r8/xmm2, r9/xmm3.
	char* rex = c"\x48\x48\x4c\x4c"
	char* modrm = c"\x8d\x95\x85\x8d"
	char* movq_rex = c"\x48\x48\x49\x49"
	char* movq_modrm = c"\xc1\xca\xd0\xd9"
	i = 0
	while ((i < nargs) && (i < 4)):
		win_thunk_byte(p, k, rex[i])
		win_thunk_byte(p, k + 1, 139)
		win_thunk_byte(p, k + 2, modrm[i])
		save_int32(p + k + 3, 16 + (nargs - 1 - i) * 8)
		win_thunk_byte(p, k + 7, 102)   /* movq xmm_i,reg: 66 REX.W 0f 6e /r */
		win_thunk_byte(p, k + 8, movq_rex[i])
		win_thunk_byte(p, k + 9, 15)
		win_thunk_byte(p, k + 10, 110)
		win_thunk_byte(p, k + 11, movq_modrm[i])
		k = k + 12
		i = i + 1
	win_thunk_byte(p, k, 72)        /* mov rax,imm64 */
	win_thunk_byte(p, k + 1, 184)
	save_int64(p + k + 2, sym)
	k = k + 10
	win_thunk_byte(p, k, 255)       /* call rax */
	win_thunk_byte(p, k + 1, 208)
	k = k + 2
	if (ret32):
		win_thunk_byte(p, k, 72)    /* movsxd rax,eax */
		win_thunk_byte(p, k + 1, 99)
		win_thunk_byte(p, k + 2, 192)
		k = k + 3
	win_thunk_byte(p, k, 201)       /* leave */
	win_thunk_byte(p, k + 1, 195)   /* ret */
	k = k + 2
	win_thunk_used = win_thunk_used + ((k + 15) & -16)
	int prev = 0
	VirtualProtect(win_thunk_page, 4096, 32, &prev) /* PAGE_EXECUTE_READ */
	FlushInstructionCache(GetCurrentProcess(), start, k)
	return start

# Install handler (a W function taking the EXCEPTION_POINTERS address
# and returning an EXCEPTION_* disposition) as a first vectored
# exception handler. Returns 1 on success. lib/crash.w uses it for
# symbolized crash reports; the other targets' stubs return 0.
# SetUnhandledExceptionFilter would be the natural hook, but W code
# carries no .pdata unwind info, so the frame-based dispatcher cannot
# unwind through W frames to the thread's top-level filter and the
# process dies without calling it. Vectored handlers run before any
# unwinding, so they see every exception; the handler must pass the
# ones it does not own through (EXCEPTION_CONTINUE_SEARCH).
int win_crash_filter_install(int handler):
	int thunk = win_callback(handler, 1)
	if (thunk == 0):
		return 0
	if (AddVectoredExceptionHandler(1, thunk) == 0):
		return 0
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


# One MEMORY_BASIC_INFORMATION (48 bytes on x64) for sys_mincore, allocated
# up front (the crash path calls sys_mincore and must not allocate).
char* win_mbi_buffer


char* win_mbi_scratch():
	if (win_mbi_buffer == 0):
		win_mbi_buffer = cast(char*, mmap(0, 4096, 3, 34))
	return win_mbi_buffer


# mincore(2) stand-in over VirtualQuery: 0 when every page of
# [addr, addr + length) is committed and readable, -12 (-ENOMEM, what
# Linux returns for an unmapped range) otherwise. vec is not filled in:
# the callers (lib/stack_trace.w, debugger/memory.w) only use it as a
# fault-free "is this mapped?" probe.
int sys_mincore(int addr, int length, int vec):
	char* info = win_mbi_scratch()
	int p = addr - (addr & 4095)
	int end = addr + length
	while (p < end):
		if (VirtualQuery(p, info, 48) == 0):
			return -12
		int state = load_int32(info + 32)
		int protect = load_int32(info + 36)
		if (state != 4096): /* MEM_COMMIT */
			return -12
		# PAGE_NOACCESS (1) and PAGE_GUARD (0x100) pages fault on read.
		if ((protect & 1) || (protect & 256)):
			return -12
		int region_end = load_int64(info) + load_int64(info + 24)
		if (region_end <= p):
			return -12
		p = region_end
	return 0



int rt_sigaction(int signum, int* act, int* oldact):
	return -1


int sys_sigaltstack(int ss, int old_ss):
	return -1


/* Startup */

# The PE entry stub calls _win_start (see code_generator/pe_64.w), which
# rebuilds the W (argc, argv) contract from the Windows command line and
# chains to _main. Memory comes from mmap directly because lib/memory.w's
# malloc is not necessarily part of the program.
int _main(int argc, int argv);


# Splits the command line the way everything expects argv: arguments are
# separated by spaces/tabs, double quotes group words. (The full
# CommandLineToArgvW backslash rules are not implemented.) The
# environment vector after argv's terminator points into the process
# environment block (GetEnvironmentStringsA: NAME=value entries, each
# NUL-terminated, the block ending in an empty entry),
# skipping the hidden "=C:=C:\..." per-drive entries.
int _win_start(int stub_argc, int stub_argv):
	char* cmd = GetCommandLineA()
	int len = 0
	while (cmd[len] != 0):
		len = len + 1
	char* env = GetEnvironmentStringsA()
	int env_count = 0
	if (env != 0):
		int e = 0
		while (env[e] != 0):
			if (env[e] != '='):
				env_count = env_count + 1
			while (env[e] != 0):
				e = e + 1
			e = e + 1
	# Worst case one argument per two characters; the block holds the
	# argv array, the environment vector, then the unquoted copy.
	int max_args = len / 2 + 2
	int slots = max_args + env_count + 2
	int block = mmap(0, slots * 8 + len + 1, 3, 34)
	if (block < 0):
		return _main(stub_argc, stub_argv)
	char** argv = cast(char**, block)
	char* buf = cast(char*, block + slots * 8)
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
	int n = argc + 1
	if (env != 0):
		int e2 = 0
		while (env[e2] != 0):
			if (env[e2] != '='):
				argv[n] = env + e2
				n = n + 1
			while (env[e2] != 0):
				e2 = e2 + 1
			e2 = e2 + 1
	argv[n] = cast(char*, 0)
	return _main(argc, cast(int, argv))


/* No epoll or eventfd here: -ENOSYS makes lib/event_loop.w fall back to
   poll and lib/task_runtime.w to a pipe. */

int epoll_event_bytes():
	return 16


int epoll_event_data_offset():
	return 8


int epoll_create1(int flags):
	return -38


int epoll_ctl(int epfd, int op, int fd, int event):
	return -38


int epoll_wait(int epfd, int events, int maxevents, int timeout_ms):
	return -38


int eventfd2(int initval, int flags):
	return -38
