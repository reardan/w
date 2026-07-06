import lib.lib
import lib.path
import libs.standard.pkg.metadata


struct package_index:
	list[char*] roots
	list[package_meta*] packages
	list[char*] diagnostics


package_index* pkg_index_new():
	package_index* index = new package_index
	index.roots = new list[char*]
	index.packages = new list[package_meta*]
	index.diagnostics = new list[char*]
	return index


void pkg_index_diag(package_index* index, char* root, char* message):
	char* prefix = strjoin(root, c": ")
	char* full = strjoin(prefix, message)
	free(prefix)
	index.diagnostics.push(full)


int pkg_index_seen(package_index* index, char* normalized):
	for package_meta* meta in index.packages:
		char* other = pkg_normalize_name(meta.name)
		if (strcmp(other, normalized) == 0):
			free(other)
			return 1
		free(other)
	return 0


int pkg_index_add_meta(package_index* index, char* meta_path):
	package_meta* meta = pkg_read_metadata(meta_path)
	if (meta.diagnostics.length > 0):
		for char* diag in meta.diagnostics:
			pkg_index_diag(index, meta_path, diag)
		return 0
	char* normalized = pkg_normalize_name(meta.name)
	if (pkg_index_seen(index, normalized)):
		free(normalized)
		return 1
	free(normalized)
	index.packages.push(meta)
	return 1


int pkg_load_uint16(char* p):
	return (p[0] & 255) + ((p[1] & 255) << 8)


int pkg_index_scan_root(package_index* index, char* root):
	int fd = open(root, 65536, 0)
	if (fd < 0):
		pkg_index_diag(index, root, c"cannot open root")
		return 0
	int added = 0
	int buffer_size = 4096
	char* buffer = malloc(buffer_size)
	int n = getdents(fd, buffer, buffer_size)
	while (n > 0):
		int pos = 0
		while (pos < n):
			char* ent = buffer + pos
			int reclen = pkg_load_uint16(ent + 2 * __word_size__)
			char* name = ent + 2 * __word_size__ + 2
			if ((strcmp(name, c".") != 0) & (strcmp(name, c"..") != 0)):
				char* pkg_dir = path_join(root, name)
				char* meta_path = path_join(pkg_dir, c"package.wmeta")
				if (path_exists(meta_path)):
					added = added + pkg_index_add_meta(index, meta_path)
				free(pkg_dir)
				free(meta_path)
			pos = pos + reclen
		n = getdents(fd, buffer, buffer_size)
	close(fd)
	free(buffer)
	return added


int pkg_index_add_root(package_index* index, char* root):
	index.roots.push(strclone(root))
	return pkg_index_scan_root(index, root)


package_meta* pkg_find(package_index* index, char* name):
	char* normalized = pkg_normalize_name(name)
	for package_meta* meta in index.packages:
		char* meta_name = pkg_normalize_name(meta.name)
		if (strcmp(meta_name, normalized) == 0):
			free(meta_name)
			free(normalized)
			return meta
		free(meta_name)
	free(normalized)
	return 0


list[char*] pkg_list_modules(package_meta* meta):
	return meta.modules


char* pkg_module_path(package_meta* meta, char* dotted_name):
	int declared = 0
	for char* module in meta.modules:
		if (strcmp(module, dotted_name) == 0):
			declared = 1
	if (declared == 0):
		return 0
	char* rel = pkg_dotted_to_path(dotted_name)
	char* file_rel = strjoin(rel, c".w")
	char* root = path_join(meta.dir, meta.root)
	char* full = path_join(root, file_rel)
	free(rel)
	free(file_rel)
	free(root)
	return full
