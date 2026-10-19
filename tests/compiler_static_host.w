# Invoked by compiler_static_test after building the library consumer.
# wbuild: binary=compiler_static_host_check
import tools.host_tools

int main(int argc, int argv):
	args_init(argc, argv)
	ht_require(argc == 2, c"usage: compiler_static_host_check compiler")
	string_builder* image = ht_read(args_get(1))
	int phoff = ht_uint(image, 32, 8)
	int phsize = ht_uint(image, 54, 2)
	int phcount = ht_uint(image, 56, 2)
	ht_require(phsize >= 4 && phoff <= image.length && phcount <= (image.length - phoff) / phsize, c"invalid program headers")
	for i in range(phcount):
		int kind = ht_uint(image, phoff + phsize * i, 4)
		ht_require(kind != 2 && kind != 3, c"static compiler carries a dynamic table/interpreter")
	char* directory = ht_temp()
	char* executable = path_join(directory, c"compiler")
	ht_require(shutil_copy(args_get(1), executable) == 0, c"cannot copy standalone compiler")
	list[char*] command = new list[char*]
	command.push(executable)
	command.push(c"--version")
	spawn_options* options = spawn_options_new()
	options.cwd = directory
	process_result* result = ht_run(command, options, 0, 30000)
	ht_success(result)
	ht_require(strcmp(result.stdout_text, c"w 0.3.0\n") == 0, c"unexpected standalone compiler version")
	ht_cleanup()
	println(c"static compiler standalone OK")
	return 0
