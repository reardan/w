# Win32 and Windows-only stubs for every non-Windows native target
# (imported by lib/__arch__/{x86,x64,arm64,arm64_darwin}/syscalls.w).
# lib/__arch__/win64/syscalls.w has the real implementations.

# Returns 1 when running on Windows, 0 on all other platforms.
int os_windows():
	return 0


# The win64 module's C -> W callback thunks and unhandled-exception
# filter (lib/crash.w); Windows-only, so the stubs report failure.
int win_callback(int fn, int nargs):
	return 0


int win_crash_filter_install(int handler):
	return 0


# Win32 API surface used by the os_windows()-guarded paths in shared
# modules (lib/process.w's CreateProcessA spawning, tools/wexec.w's
# FindFirstFileA directory walk). Those paths never run on this target;
# the stubs only keep the modules linkable -- the mirror image of the
# Unix-primitive stubs at the bottom of lib/__arch__/win64/syscalls.w.
# Each returns its Win32 failure value.

int CloseHandle(int handle):
	return 0


int GetStdHandle(int which):
	return -1


int CreateFileA(char* path, int access, int share, int security, int creation, int flags, int template_file):
	return -1


int CreatePipe(int* read_end, int* write_end, int security, int size):
	return 0


int SetHandleInformation(int handle, int mask, int flags):
	return 0


int CreateProcessA(char* app, char* cmdline, int proc_attr, int thread_attr, int inherit_handles, int flags, int env, char* dir, char* startup_info, char* proc_info):
	return 0


int WaitForSingleObject(int handle, int milliseconds):
	return -1


int GetExitCodeProcess(int handle, int* code):
	return 0


int TerminateProcess(int handle, int exit_code):
	return 0


int PeekNamedPipe(int handle, char* buf, int buf_size, int* bytes_read, int* bytes_avail, int* bytes_left):
	return 0


int FindFirstFileA(char* pattern, char* find_data):
	return -1


int FindNextFileA(int handle, char* find_data):
	return 0


int FindClose(int handle):
	return 0
