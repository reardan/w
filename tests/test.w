import lib.lib


int main(int arg, char** argv):
	# Get current directory
	int max_path_size = 4096
	char* cwd = malloc(max_path_size)
	getcwd(cwd, max_path_size)
	print_string("cwd: ", cwd)

	# Go back up one directory
	char* up_one = strclone(cwd)
	int index = strlen(up_one) - 1
	while (index > 0):
		if (up_one[index] == '/'):
			up_one[index + 1] = 0
			index = 1 /* hacky way to break from loop */
		index = index - 1
	print_string("up_one: ", up_one)


	free(cwd)
	return 0

