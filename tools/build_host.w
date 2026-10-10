# Host executables and target architecture are independent. In particular,
# bin/wv2 may be a Linux ELF even when this process runs on a Mac.
import lib.path


int build_host_darwin():
	return path_exists(c"/System/Library/CoreServices/SystemVersion.plist")


int build_host_android():
	return os_android()


char* build_host_compiler():
	if (build_host_android()): return c"bin/wv2_android"
	if (build_host_darwin()): return c"bin/wv2_darwin"
	if (os_windows()): return c"bin/wv2.exe"
	return c"bin/wv2"


char* build_host_executor():
	if (build_host_android()): return c"bin/wexec_android"
	if (build_host_darwin()): return c"bin/wexec_darwin"
	if (os_windows()): return c"bin/wexec.exe"
	return c"bin/wexec"
