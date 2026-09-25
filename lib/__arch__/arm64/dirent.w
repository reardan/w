# lib/dir.w's directory read for this target. AArch64's getdents is
# getdents64 (d_ino u64, d_off u64, d_reclen u16 at 16, d_type u8 at
# 18, the name at 19), and its O_DIRECTORY is 0x4000 (0x10000 is
# O_DIRECT there).
import lib.dir_getdents


int dir_platform_read(char* path, list[char*] names, list[int] kinds):
	return dir_getdents_read(path, names, kinds, 16384, 16, 19, 18)
