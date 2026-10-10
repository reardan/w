# Android's older app seccomp policies kill statx rather than returning
# ENOSYS. Use the long-established newfstatat syscall and translate its
# asm-generic stat layout into the Linux statx basic-stat contract.
# This deliberately does not claim birthtime, mount ID or attributes.
import code_generator.integer


void android_stat_to_statx(char* src, char* dst):
	for i in range(256): dst[i] = 0
	save_int32(dst, 2047)
	save_int32(dst + 4, load_int32(src + 56))
	save_int32(dst + 16, load_int32(src + 20))
	save_int32(dst + 20, load_int32(src + 24))
	save_int32(dst + 24, load_int32(src + 28))
	save_int16(dst + 28, load_int32(src + 16))
	save_i(dst + 32, load_i(src + 8, 8), 8)
	save_i(dst + 40, load_i(src + 48, 8), 8)
	save_i(dst + 48, load_i(src + 64, 8), 8)
	save_i(dst + 64, load_i(src + 72, 8), 8)
	save_int32(dst + 72, load_i(src + 80, 8))
	save_i(dst + 96, load_i(src + 104, 8), 8)
	save_int32(dst + 104, load_i(src + 112, 8))
	save_i(dst + 112, load_i(src + 88, 8), 8)
	save_int32(dst + 120, load_i(src + 96, 8))
	int rdev = load_i(src + 32, 8)
	int dev = load_i(src, 8)
	# Linux's new_encode_dev: 12 major bits, 20 minor bits.
	save_int32(dst + 128, (rdev >> 8) & 4095)
	save_int32(dst + 132, (rdev & 255) | ((rdev >> 12) & 1048320))
	save_int32(dst + 136, (dev >> 8) & 4095)
	save_int32(dst + 140, (dev & 255) | ((dev >> 12) & 1048320))


int android_statx(char* path, int flags, int mask, char* buf):
	# AT_SYMLINK_NOFOLLOW, AT_NO_AUTOMOUNT and AT_EMPTY_PATH are
	# supported by newfstatat. Sync modes and extended statx requests
	# have no equivalent and must fail explicitly.
	if ((flags & ~6400) != 0): return -22
	if ((mask & ~2047) != 0): return -95
	char[128] raw
	int err = syscall7(79, -100, path, cast(char*, &raw[0]), flags, 0, 0)
	if (err != 0): return err
	android_stat_to_statx(cast(char*, &raw[0]), buf)
	return 0
