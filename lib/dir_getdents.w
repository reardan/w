/*
The getdents(2) record walk behind lib/dir.w, parameterized by the
per-target record layout, which lib/__arch__/<target>/dirent.w
supplies (dir_platform_read). Callers want lib/dir.w, not this.
*/
import lib.lib


int dir_getdents_uint16(char* p):
	return (p[0] & 255) + ((p[1] & 255) << 8)


# Appends each entry of the directory at path, "." and ".." included,
# to names (fresh strings) and its d_type to kinds, in getdents order.
# open_flags opens a directory read-only (the target's O_DIRECTORY);
# reclen_at, name_at and type_at are record byte offsets, with
# type_at < 0 meaning the record's last byte (the legacy Linux layout).
# Returns 0, or -1 when path cannot be opened.
int dir_getdents_read(char* path, list[char*] names, list[int] kinds, int open_flags, int reclen_at, int name_at, int type_at):
	int fd = open(path, open_flags, 0)
	if (fd < 0): return -1
	int buffer_size = 65536
	char* buffer = malloc(buffer_size)
	int n = getdents(fd, buffer, buffer_size)
	while (n > 0):
		int off = 0
		while (off < n):
			char* record = buffer + off
			int reclen = dir_getdents_uint16(record + reclen_at)
			if (reclen <= 0): break
			int at = type_at
			if (at < 0): at = reclen - 1
			names.push(strclone(record + name_at))
			kinds.push(record[at] & 255)
			off = off + reclen
		n = getdents(fd, buffer, buffer_size)
	free(buffer)
	close(fd)
	return 0
