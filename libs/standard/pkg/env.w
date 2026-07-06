import lib.lib
import lib.env


char* pkg_default_root():
	return c"libs"


list[char*] pkg_search_roots_from_env(char* env_name):
	list[char*] roots = new list[char*]
	char* value = env_get(env_name)
	if (value == 0):
		roots.push(strclone(pkg_default_root()))
		return roots
	int i = 0
	int start = 0
	while (1):
		if ((value[i] == ':') | (value[i] == 0)):
			int n = i - start
			if (n > 0):
				char* root = malloc(n + 1)
				int j = 0
				while (j < n):
					root[j] = value[start + j]
					j = j + 1
				root[n] = 0
				roots.push(root)
			start = i + 1
		if (value[i] == 0):
			break
		i = i + 1
	return roots


int pkg_is_virtual_root(char* root):
	char* marker = strjoin(root, c"/pyvenv.cfg")
	int fd = open(marker, 0, 0)
	if (fd < 0):
		free(marker)
		return 0
	close(fd)
	free(marker)
	return 1
