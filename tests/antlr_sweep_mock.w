# wbuild: binary=antlr_sweep_mock
# Offline subprocess fixture for the sweep driver; no interpreter dependency.
import tools.host_tools
import lib.str

char* sm_option(char* name):
	for i in range(1, args_count() - 1):
		if (strcmp(args_get(i), name) == 0): return args_get(i + 1)
	return 0
int sm_flag(char* name):
	for i in range(1, args_count()):
		if (strcmp(args_get(i), name) == 0): return 1
	return 0
int main(int argc, int argv):
	args_init(argc, argv)
	char* name = path_basename(args_program())
	# The compiler mock installs itself as the compiled example driver: an
	# example whose text names an outcome produces it, any other is accepted.
	if (ends_with(name, c".bin")):
		char* example = ht_read(args_get(1)).data
		if (contains(example, c"reject")):
			println(c"example: syntax error")
			return 1
		if (contains(example, c"hang")): process_sleep_ms(5000)
		if (contains(example, c"crash")): kill(getpid(), 15)
		return 0
	char* mode_path = strjoin(args_program(), c".mode")
	char* mode = c""
	if (path_exists(mode_path)): mode = ht_read(mode_path).data
	println(strjoin(name, c": complete log, including commas and \"quotes\""))
	char* audit = sm_option(c"--audit-json")
	if (audit != 0 && strcmp(mode, c"missing") != 0):
		json_value* finding = json_parse(c"{\"code\":\"AT_FIXTURE\",\"stage\":\"translate\",\"feature\":\"fixture\",\"classification\":\"unproven\",\"line\":1,\"column\":2,\"rule\":\"root\",\"reason\":\"fixture reason\"}")
		json_object_set(finding, c"file", json_string(args_get(1)))
		json_value* document = json_parse(c"{\"schema_version\":1,\"findings\":[]}")
		json_array_push(ht_field(document, c"findings"), finding)
		char* text = json_stringify(document)
		ht_write(audit, text, strlen(text))
	if (strcmp(mode, c"timeout") == 0): process_sleep_ms(5000)
	if (strcmp(mode, c"crash") == 0): kill(getpid(), 15)
	if (strcmp(mode, c"fail") == 0 || (strcmp(mode, c"strict_fail") == 0 && sm_flag(c"--strict"))): return 7
	if (strcmp(mode, c"stateful_fail") == 0 && sm_flag(c"--stateful")): return 8
	if (strcmp(mode, c"missing") == 0): return 0
	if (strcmp(name, c"compiler") == 0):
		char* program = ht_read(args_get(1)).data
		int at = index_of(program, c"int main(")
		ht_require(at >= 0 && index_of(program + at + 1, c"int main(") < 0, c"compile harness must have exactly one main")
		ht_require(shutil_copy(args_program(), sm_option(c"-o")) == 0, c"cannot install example driver")
		return 0
	char* dependencies = sm_option(c"--dependencies")
	if (dependencies != 0):
		char* text = strjoin(args_get(1), c"\n")
		ht_write(dependencies, text, strlen(text))
	for char* flag in ht_command(c"-o --matchers --report --audit"):
		char* path = sm_option(flag)
		if (path != 0): ht_write(path, c"# generated\n", 12)
	return 0
