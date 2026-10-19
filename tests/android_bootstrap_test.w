import tools.host_tools

void ab_script(char* root, char* path, char* body):
	char* content = strjoin(c"#!/bin/sh\n", body)
	char* target = path_join(root, path)
	ht_write(target, content, strlen(content))
	ht_require(chmod(target, 493) == 0, c"cannot chmod fixture")

void ab_case(int scenario):
	char* root = ht_temp()
	ht_require(shutil_copyfile(c"wbuild", path_join(root, c"wbuild")) == 0, c"cannot copy wbuild")
	ht_require(file_write_text(path_join(root, c"SEEDS"), c"# No Android seed is published yet\n"), c"cannot write seeds")
	ht_require(mkdir(path_join(root, c"bin"), 448) == 0 && mkdir(path_join(root, c"commands"), 448) == 0, c"cannot create fixture directories")
	ab_script(root, c"commands/uname", c"echo aarch64\n")
	spawn_options* options = spawn_options_new()
	options.cwd = root
	options.env = env_copy_with(env_current(), c"ANDROID_ROOT", c"/system")
	options.env = env_copy_with(options.env, c"WBUILDD", c"1")
	char* path = env_get(c"PATH")
	if (path == 0): path = c"/usr/bin:/bin"
	options.env = env_copy_with(options.env, c"PATH", strjoin(path_join(root, c"commands:"), path))
	list[char*] command = ht_command(c"sh ./wbuild")
	if (scenario == 0): command.push(c"verify")
	if (scenario == 1):
		ab_script(root, c"commands/uname", c"echo armv7l\n")
		command.push(c"build")
	if (scenario == 2):
		ab_script(root, c"w_android", c"exit 93\n")
		ab_script(root, c"bin/wexec_android", c"printf '%s\\n' \"$@\" >> calls\n")
		command.push(c"-j")
		command.push(c"2")
		command.push(c"tests")
	if (scenario == 3):
		ab_script(root, c"w_android", c"[ \"$1\" = arm64_android ] || exit 90\n[ \"$2\" = w.w ] || exit 91\ncp compiler_template \"$4\"\nchmod +x \"$4\"\n")
		ab_script(root, c"compiler_template", c"[ \"$1\" = arm64_android ] || exit 92\n[ \"$2\" = tools/wexec_main.w ] || exit 93\ncp executor_template \"$4\"\nchmod +x \"$4\"\n")
		ab_script(root, c"executor_template", c"printf '%s\\n' \"$@\" >> calls\n")
		command.push(c"verify_android")
	process_result* result = ht_run(command, options, 0, 30000)
	if (scenario == 0):
		ht_require(result.status != 0 && ht_contains(result.stderr_text, c"bin/wv2 arm64_android w.w -o w_android") && ht_contains(result.stderr_text, c"Termux's private home"), c"missing seed guidance regression")
		ht_require(!path_exists(path_join(root, c"w.download")), c"unexpected seed download")
	if (scenario == 1): ht_require(result.status != 0 && ht_contains(result.stderr_text, c"requires ARM64"), c"unsupported CPU accepted")
	if (scenario >= 2):
		ht_success(result)
		char* expected = c"wexec_android\n-j\n2\ntests\n"
		if (scenario == 3):
			expected = c"wexec_android\nverify_android\n"
			ht_require(path_exists(path_join(root, c"bin/wv2_android")), c"compiler was not bootstrapped")
		ht_require(strcmp(ht_read(path_join(root, c"calls")).data, expected) == 0, c"executor arguments changed")

int main():
	for i in range(4): ab_case(i)
	ht_cleanup()
	println(c"Android bootstrap checks OK")
	return 0
