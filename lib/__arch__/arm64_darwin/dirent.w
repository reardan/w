# lib/dir.w's directory read for this target. The getdents shim returns
# raw getdirentries64 records (d_ino u64, d_seekoff u64, d_reclen u16
# at 16, d_namlen u16, d_type u8 at 20, the name at 21); open
# translates the Linux O_DIRECTORY (0x10000) itself.
import lib.dir_getdents


int dir_platform_read(char* path, list[char*] names, list[int] kinds):
	return dir_getdents_read(path, names, kinds, 65536, 16, 21, 20)
