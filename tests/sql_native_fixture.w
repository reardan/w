# wbuild: binary=sql_native_fixture
import tools.host_tools

void sql_fixture_run(char* binary, int missing):
	char* directory = ht_temp()
	char* library = path_join(directory, c"fixture.so")
	list[char*] command = ht_command(c"cc -std=c99 -Wall -Wextra -Werror -Wno-unused-parameter -shared -fPIC")
	char* input = 0
	if (missing):
		command.push(c"-x")
		command.push(c"c")
		command.push(c"-")
		input = c"int unrelated_symbol;\n"
	else: command.push(c"tests/sql_native_fixture.c")
	command.push(c"-o")
	command.push(library)
	ht_success(ht_run(command, 0, input, 30000))
	list[char*] names = ht_command(c"libmysqlclient.so.21 libsybdb.so.5 libclntsh.so")
	if (missing):
		names.push(c"libsqlite3.so.0")
		names.push(c"libpq.so.5")
	for char* name in names: ht_require(symlink(library, path_join(directory, name)) == 0, c"cannot create fixture symlink")
	spawn_options* options = spawn_options_new()
	options.env = env_copy_with(env_current(), c"LD_LIBRARY_PATH", directory)
	command = new list[char*]
	command.push(binary)
	command.push(c"fixture")
	if (missing): command.push(c"missing")
	process_result* result = ht_run(command, options, 0, 30000)
	ht_success(result)
	print(result.stdout_text)
	print2(result.stderr_text)

int main(int argc, int argv):
	args_init(argc, argv)
	ht_require(argc == 2, c"usage: sql_native_fixture binary")
	if (process_which(c"cc") == 0):
		println(c"sql native ABI fixtures: SKIP (cc unavailable)")
		return 0
	sql_fixture_run(args_get(1), 0)
	sql_fixture_run(args_get(1), 1)
	ht_cleanup()
	return 0
