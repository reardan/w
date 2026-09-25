/*
Directory listing, recursive walk and recursive removal.

dir_read lists one directory's entries with their kinds; the record
decoding is per target (lib/__arch__/<target>/dirent.w: the legacy
Linux getdents layout on x86/x64, getdents64 on arm64,
getdirentries64 on arm64_darwin, FindFirstFileA on win64; wasm has no
listing). dir_walk_files and dir_remove_all build on it.
*/
import lib.lib
import lib.path
import lib.container
import lib.__arch__.dirent


# Entry kinds (the d_type values; win64 reports only the first two).
const int DIR_KIND_DIR = 4
const int DIR_KIND_FILE = 8
const int DIR_KIND_LINK = 10


struct dir_entry:
	char* name   # the bare entry name (owned)
	int kind     # DIR_KIND_*, or another d_type (0 = unknown)


void dir_entries_free(list[dir_entry*] entries):
	if (entries == 0):
		return
	for dir_entry* e in entries:
		free(e.name)
		free(e)
	list_free[dir_entry*](entries)


# The entries of the directory at path, "." and ".." excluded, sorted
# by name (the platform order depends on filesystem state), or 0 when
# path cannot be opened as a directory. Free with dir_entries_free.
list[dir_entry*] dir_read(char* path):
	list[char*] names = new list[char*]
	list[int] kinds = new list[int]
	if (dir_platform_read(path, names, kinds) != 0):
		for char* name in names:
			free(name)
		list_free[char*](names)
		list_free[int](kinds)
		return 0
	list[dir_entry*] entries = new list[dir_entry*]
	int i = 0
	while (i < names.length):
		char* name = names[i]
		if ((strcmp(name, c".") == 0) || (strcmp(name, c"..") == 0)):
			free(name)
		else:
			dir_entry* e = new dir_entry
			e.name = name
			e.kind = kinds[i]
			# Insertion sort by name.
			entries.push(e)
			int j = entries.length - 2
			while ((j >= 0) && (strcmp(entries[j].name, name) > 0)):
				entries[j + 1] = entries[j]
				j = j - 1
			entries[j + 1] = e
		i = i + 1
	list_free[char*](names)
	list_free[int](kinds)
	return entries


# Just the sorted entry names of dir_read(path) (owned), or 0.
list[char*] dir_names(char* path):
	list[dir_entry*] entries = dir_read(path)
	if (entries == 0):
		return 0
	list[char*] names = new list[char*]
	for dir_entry* e in entries:
		names.push(e.name)
		free(e)
	list_free[dir_entry*](entries)
	return names


# Appends path/<rel> for every regular file under the directory at
# path, recursing into subdirectories (never through symlinks), in
# depth-first name order. An unopenable path appends nothing.
void dir_walk_files(char* path, list[char*] out):
	list[dir_entry*] entries = dir_read(path)
	if (entries == 0):
		return
	for dir_entry* e in entries:
		if ((e.kind == DIR_KIND_DIR) || (e.kind == DIR_KIND_FILE)):
			char* child = path_join(path, e.name)
			if (e.kind == DIR_KIND_DIR):
				dir_walk_files(child, out)
				free(child)
			else:
				out.push(child)
	dir_entries_free(entries)


# rm -rf path: a file or symlink (even one to a directory) is unlinked;
# a directory is emptied bottom-up and removed. A missing path is
# success. Returns 0, or -1 when something could not be removed.
int dir_remove_all(char* path):
	if (unlink(path) == 0):
		return 0
	list[dir_entry*] entries = dir_read(path)
	if (entries == 0):
		if (path_exists(path)):
			return -1
		return 0
	int status = 0
	for dir_entry* e in entries:
		char* child = path_join(path, e.name)
		if (dir_remove_all(child) != 0):
			status = -1
		free(child)
	dir_entries_free(entries)
	if (rmdir(path) != 0):
		status = -1
	return status
