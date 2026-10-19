# wbuild: binary=sql_postgres_fixture
import tools.host_tools
import libs.standard.fs.glob

int main(int argc, int argv):
	args_init(argc, argv)
	ht_require(argc == 2, c"usage: sql_postgres_fixture binary")
	char* initdb = process_which(c"initdb")
	list[char*] candidates = glob_glob(c"/usr/lib/postgresql/*/bin/initdb")
	if (initdb == 0 && candidates.length > 0): initdb = candidates[candidates.length - 1]
	if (initdb == 0 || getuid() == 0):
		println(c"sql PostgreSQL local: SKIP (initdb unavailable or running as root)")
		return 0
	char* pgctl = path_join(path_dirname(initdb), c"pg_ctl")
	char* directory = ht_temp()
	char* data = path_join(directory, c"data")
	list[char*] command = new list[char*]
	command.push(initdb)
	command.push(c"-D")
	command.push(data)
	for char* arg in ht_command(c"-A trust -U postgres --no-locale --encoding=UTF8"): command.push(arg)
	ht_checked(command)
	command = new list[char*]
	command.push(pgctl)
	command.push(c"-D")
	command.push(data)
	command.push(c"-l")
	command.push(path_join(directory, c"server.log"))
	command.push(c"-o")
	command.push(strjoin(strjoin(c"-k ", directory), c" -h '' -p 5432"))
	for char* arg in ht_command(c"-w -t 15 start"): command.push(arg)
	process_result* started = ht_run(command, 0, 0, 20000)
	process_result* result = started
	if (started.status == 0):
		spawn_options* options = spawn_options_new()
		options.env = env_copy_with(env_current(), c"W_SQL_POSTGRES", strjoin(strjoin(c"host=", directory), c" port=5432 user=postgres dbname=postgres connect_timeout=2"))
		command = new list[char*]
		command.push(args_get(1))
		result = ht_run(command, options, 0, 30000)
	if (started.status == 0 || path_exists(path_join(data, c"postmaster.pid"))):
		command = new list[char*]
		command.push(pgctl)
		command.push(c"-D")
		command.push(data)
		for char* arg in ht_command(c"-m immediate -w stop"): command.push(arg)
		# Always stop the private cluster before reporting a failed test.
		ht_success(ht_run(command, 0, 0, 20000))
	ht_success(result)
	print(result.stdout_text)
	print2(result.stderr_text)
	ht_cleanup()
	return 0
