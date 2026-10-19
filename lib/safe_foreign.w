# Audited synchronous foreign byte I/O. The caller retains ownership of the
# storage. The OS borrows its initialized bytes only until the call returns.
# An exclusive destination prevents concurrent checked reads/writes; a shared
# source permits reads but no writes. Neither operation retains the pointer.
import lib.lib


int foreign_read(int descriptor, refmut byte[] destination):
	if destination.length == 0: return 0
	return read(descriptor, cast(char*, &destination[0]), destination.length)


int foreign_write(int descriptor, ref byte[] source):
	if source.length == 0: return 0
	return write(descriptor, cast(char*, &source[0]), source.length)
