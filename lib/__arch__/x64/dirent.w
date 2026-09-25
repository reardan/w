# lib/dir.w's directory read for this target: the legacy Linux
# getdents record (ino and off one word each, d_reclen u16, the name,
# d_type in the record's last byte), opened with O_DIRECTORY = 0x10000.
import lib.dir_getdents


int dir_platform_read(char* path, list[char*] names, list[int] kinds):
	return dir_getdents_read(path, names, kinds, 65536, 2 * __word_size__, 2 * __word_size__ + 2, -1)
