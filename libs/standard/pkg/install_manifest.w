import lib.lib
import lib.file
import lib.path
import libs.standard.pkg.metadata


struct pkg_install_manifest:
	char* path
	list[char*] files
	list[char*] diagnostics


pkg_install_manifest* pkg_manifest_read(char* path):
	pkg_install_manifest* manifest = new pkg_install_manifest
	manifest.path = strclone(path)
	manifest.files = new list[char*]
	manifest.diagnostics = new list[char*]
	list[char*] lines = file_read_lines(path)
	if (lines == 0):
		manifest.diagnostics.push(c"cannot read manifest")
		return manifest
	for char* raw in lines:
		char* line = pkg_trim(raw)
		if (line[0] != 0):
			manifest.files.push(strclone(line))
	return manifest


int pkg_manifest_validate(pkg_install_manifest* manifest, char* install_root):
	int i = 0
	while (i < manifest.files.length):
		char* rel = manifest.files[i]
		if (pkg_path_safe(rel) == 0):
			manifest.diagnostics.push(strjoin(c"invalid manifest path: ", rel))
		int j = 0
		while (j < i):
			if (strcmp(manifest.files[j], rel) == 0):
				manifest.diagnostics.push(strjoin(c"duplicate manifest path: ", rel))
			j = j + 1
		char* full = path_join(install_root, rel)
		if (path_exists(full) == 0):
			manifest.diagnostics.push(strjoin(c"missing manifest file: ", rel))
		free(full)
		i = i + 1
	return manifest.diagnostics.length == 0
