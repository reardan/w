import lib.lib
import lib.file
import lib.path
import libs.standard.pkg.metadata


int pkg_resource_declared(package_meta* meta, char* resource_name):
	for char* resource in meta.resources:
		if (strcmp(resource, resource_name) == 0):
			return 1
	return 0


char* pkg_resource_path(package_meta* meta, char* resource_name):
	if (pkg_path_safe(resource_name) == 0):
		return 0
	if (pkg_resource_declared(meta, resource_name) == 0):
		return 0
	char* root = path_join(meta.dir, meta.root)
	char* full = path_join(root, resource_name)
	free(root)
	return full


int pkg_resource_exists(package_meta* meta, char* resource_name):
	char* path = pkg_resource_path(meta, resource_name)
	if (path == 0):
		return 0
	int exists = path_exists(path)
	free(path)
	return exists


char* pkg_resource_read_text(package_meta* meta, char* resource_name):
	char* path = pkg_resource_path(meta, resource_name)
	if (path == 0):
		return 0
	char* text = file_read_text(path)
	free(path)
	return text
