# wbuild: binary=android_selfhost tag=tests
# Explicit-device Android compiler fixpoint, with bounded source staging.
import tools.host_tools
import lib.str
import libs.standard.cli.argparse
import libs.standard.archive.tar

char* ash_serial
process_result* ash_adb(list[char*] args, int timeout = 30000):
	list[char*] command = ht_argv(c"adb", c"-s", ash_serial)
	for char* arg in args: command.push(arg)
	process_result* result = ht_run(command, 0, 0, timeout)
	ht_success(result)
	return result

int main(int argc, int argv):
	arg_parser* parser = argparse_new(c"android_selfhost")
	argparse_arg_required(argparse_add_option(parser, c"--serial", c"SERIAL", c"adb device serial"))
	argparse_arg_default(argparse_add_option(parser, c"--compiler", c"FILE", c"host compiler"), c"bin/wv2")
	argparse_arg_default(argparse_add_option(parser, c"--remote", c"PATH", c"dedicated device staging directory"), c"/data/local/tmp/w-android-selfhost")
	arg_namespace* args = argparse_parse_or_exit(parser, argc, argv)
	ash_serial = argparse_get(args, c"serial")
	char* remote = argparse_get(args, c"remote")
	ht_require(starts_with(remote, c"/data/local/tmp/") && strlen(remote) > 16, c"--remote must name a dedicated directory below /data/local/tmp")
	for char* part in ht_split(remote, '/'): ht_require(strcmp(part, c"..") != 0, c"--remote must not contain '..'")
	for i in range(strlen(remote)): ht_require((remote[i] & 255) >= 32, c"--remote contains a control character")
	remote = path_normalize(remote)
	ht_require(starts_with(remote, c"/data/local/tmp/"), c"--remote must be a dedicated subdirectory")
	char* compiler = ht_resolve(argparse_get(args, c"compiler"))
	println(strjoin(c"Android device page size: ", strip(ash_adb(ht_argv(c"shell", c"getconf PAGESIZE")).stdout_text)))
	char* work = ht_temp()
	char* imports = c"tests/android_elf_imports.w"
	char* smoke_source = c"tests/android_runtime_smoke.w"
	char* seed = path_join(work, c"w_seed")
	char* smoke = path_join(work, c"runtime_smoke")
	for i in range(2):
		char* source = c"w.w"
		char* output = seed
		if (i == 1):
			source = smoke_source
			output = smoke
		ht_success(ht_run(ht_argv(compiler, c"arm64_android", c"--strict", source, imports, c"-o", output), 0, 0, 300000))
	set[char*] paths = new set[char*]
	char* root = ht_resolve(c".")
	for char* source in ht_argv(c"w.w", smoke_source, imports):
		paths.add(source)
		process_result* dependencies = ht_checked(ht_argv(compiler, c"deps", c"--json", c"arm64_android", source))
		for char* line in ht_split(dependencies.stdout_text, 10):
			if (strip(line)[0] != 0): paths.add(ht_text(json_parse(line), c"file"))
	list[char*] names = paths.keys()
	ht_sort(names)
	tar_writer* archive = tar_writer_new()
	for char* name in names:
		char* source = ht_resolve(name)
		ht_require(source != 0 && starts_with(source, strjoin(root, c"/")), c"dependency is outside checkout")
		string_builder* data = ht_read(source)
		tar_add_file(archive, source + strlen(root) + 1, data.data, data.length, 420, 0)
		string_free(data)
	int length = 0
	char* bytes = tar_writer_finish(archive, &length)
	char* tar_path = path_join(work, c"sources.tar")
	ht_write(tar_path, bytes, length)
	ash_adb(ht_argv(c"shell", strjoin(c"mkdir -p ", ht_quote(remote))))
	for char* file in ht_argv(seed, smoke, tar_path): ash_adb(ht_argv(c"push", file, path_join(remote, path_basename(file))))
	string_builder* script = string_from(strjoin(c"cd ", ht_quote(remote)))
	string_append(script, c" && tar -xf sources.tar && chmod 755 w_seed runtime_smoke")
	char* previous = c"w_seed"
	for char* output in ht_command(c"wv3 wv4 wv5"):
		string_append(script, strjoin(c" && ./", previous))
		string_append(script, strjoin(c" arm64_android --strict w.w tests/android_elf_imports.w -o ", output))
		string_append(script, strjoin(c" && chmod 755 ", output))
		previous = output
	string_append(script, c" && cmp wv3 wv4 && cmp wv4 wv5 && ./runtime_smoke && sha256sum wv3 wv4 wv5")
	print(ash_adb(ht_argv(c"shell", script.data), 1800000).stdout_text)
	ht_cleanup()
	println(c"Android compiler fixpoint (wv3 == wv4 == wv5) and runtime smoke: OK")
	println(strjoin(c"Device artifacts retained in ", remote))
	return 0
