# wbuild: binary=qualify_native arch=x64 tag=tests
# Reproducible ARM64 ordering/durability qualification, with explicit evidence scope.
import tools.host_report
import tools.mac.vm_source_identity
import libs.standard.cli.argparse

json_value* qn_report
char* qn_output
char* qn_serial
char* qn_remote

char* qn_run(list[char*] command, char* cwd = 0, int timeout = 30000):
	hm_sample* sample = hm_start(command, cwd)
	hm_finish(sample, timeout)
	char* output = strjoin(ht_read(sample.stdout_path).data, ht_read(sample.stderr_path).data)
	if (sample.status != 0 || sample.timed_out):
		print2(output)
		ht_require(0, strjoin(c"qualification command failed: ", command[0]))
	return output
char* qn_shell(char* command, int timeout = 30000):
	return qn_run(ht_argv(c"adb", c"-s", qn_serial, c"shell", command), 0, timeout)
void qn_cleanup():
	if (qn_report != 0):
		if (!ht_field(qn_report, c"passed").int_value): vj_s(qn_report, c"failure", c"qualification failed; see terminal diagnostics")
		vj_write(qn_output, qn_report)
		println(strjoin(c"evidence: ", qn_output))
	if (qn_remote != 0):
		# Best effort after transport failure; each trial also has a device watchdog.
		ht_run(ht_argv(c"adb", c"-s", qn_serial, c"shell", strjoin(c"rm -rf ", ht_quote(qn_remote))), 0, 0, 30000)

set[int] qn_cpus(char* value):
	set[int] result = new set[int]
	for char* item in ht_split(strip(value), ','):
		list[char*] ends = ht_split(item, '-')
		int first = atoi(ends[0])
		int last = first
		if (ends.length == 2): last = atoi(ends[1])
		ht_require(first >= 0 && last >= first && last <= 65535, c"invalid CPU inventory")
		for cpu in range(first, last + 1): result.add(cpu)
	return result
json_value* qn_device():
	json_value* info = json_object()
	list[char*] names = ht_command(c"uname machine model soc android_version build_fingerprint qemu boot_qemu native_bridge cpuinfo online_cpus status cgroup identity page_size")
	list[char*] commands = ht_split(c"uname -a|uname -m|getprop ro.product.model|getprop ro.soc.model|getprop ro.build.version.release|getprop ro.build.fingerprint|getprop ro.kernel.qemu|getprop ro.boot.qemu|getprop ro.dalvik.vm.native.bridge|cat /proc/cpuinfo|cat /sys/devices/system/cpu/online|cat /proc/self/status|cat /proc/self/cgroup|id|getconf PAGESIZE", '|')
	for i in range(names.length): vj_s(info, names[i], strip(qn_shell(commands[i])))
	char* machine = ht_text(info, c"machine")
	ht_require(strcmp(machine, c"arm64") == 0 || strcmp(machine, c"aarch64") == 0, c"ADB qualification requires a native ARM64 kernel; translation is not evidence")
	for char* name in ht_command(c"qemu boot_qemu native_bridge"):
		char* value = ht_text(info, name)
		ht_require(value[0] == 0 || strcmp(value, c"0") == 0, c"ADB qualification rejects emulators and configured native bridges")
	char* allowed = 0
	for char* line in ht_split(ht_text(info, c"status"), 10):
		if (starts_with(line, c"Cpus_allowed_list:")): allowed = strip(line + 18)
	ht_require(allowed != 0, c"missing CPU affinity inventory")
	set[int] available = qn_cpus(allowed)
	set[int] online = qn_cpus(ht_text(info, c"online_cpus"))
	list[int] cpus = new list[int]
	for int cpu in available:
		if (cpu in online): cpus.push(cpu)
	cpus.sort()
	ht_require(cpus.length >= 2, c"native concurrent qualification requires at least two available CPUs")
	json_value* array = json_array()
	for int cpu in cpus: json_array_push(array, json_int(cpu))
	json_object_set(info, c"available_cpus", array)
	qn_shell(c"command -v setsid && command -v timeout && command -v sha256sum")
	qn_remote = strip(qn_shell(c"mktemp -d /data/local/tmp/w-native-qualification-XXXXXX"))
	ht_require(starts_with(qn_remote, c"/data/local/tmp/w-native-qualification-"), c"unexpected device staging directory")
	# Durability trials run in subdirectories of qn_remote: record the
	# filesystem and mount options they exercised.
	vj_s(info, c"filesystem", strip(qn_shell(strjoin(c"df -k ", ht_quote(qn_remote)))))
	vj_s(info, c"mounts", strip(qn_shell(c"cat /proc/mounts")))
	return info
char* qn_stage(char* binary):
	char* remote = path_join(qn_remote, path_basename(binary))
	qn_run(ht_argv(c"adb", c"-s", qn_serial, c"push", binary, remote))
	qn_shell(strjoin(c"chmod 755 ", ht_quote(remote)))
	list[char*] fields = split(qn_shell(strjoin(c"sha256sum ", ht_quote(remote))))
	ht_require(fields.length > 0 && strcmp(fields[0], vsi_digest(binary)) == 0, c"device executable SHA256 differs from compiled binary")
	return remote
json_value* qn_trial(char* binary, int timeout):
	char* directory = strip(qn_shell(strjoin(c"mktemp -d ", ht_quote(path_join(qn_remote, c"trial-XXXXXX")))))
	ht_require(starts_with(directory, strjoin(qn_remote, c"/trial-")), c"unexpected device trial directory")
	char* body = strjoin(strjoin(c"cd ", ht_quote(directory)), c" || exit 1\necho $$ > group.pid\n")
	body = strjoin(body, strjoin(strjoin(c"timeout --foreground -s KILL ", itoa(timeout)), strjoin(c" ", ht_quote(binary))))
	body = strjoin(body, c" > output 2>&1\necho $? > status\nkill -KILL -- -$$\n")
	char* command = strjoin(c"setsid -w sh -c ", ht_quote(body))
	command = strjoin(command, strjoin(c" >/dev/null 2>&1; test -f ", ht_quote(path_join(directory, c"status"))))
	int start = vm_ns()
	process_result* result = ht_run(ht_argv(c"adb", c"-s", qn_serial, c"shell", command), 0, 0, (timeout + 15) * 1000)
	char* cleanup = strjoin(strjoin(c"cd ", ht_quote(directory)), c" && if test -f group.pid; then kill -KILL -- -$(cat group.pid) 2>/dev/null || true; fi")
	ht_run(ht_argv(c"adb", c"-s", qn_serial, c"shell", cleanup), 0, 0, 30000)
	if (result.status != 0):
		ht_run(ht_argv(c"adb", c"-s", qn_serial, c"shell", strjoin(c"rm -rf ", ht_quote(directory))), 0, 0, 30000)
		ht_success(result)
	int status = atoi(strip(qn_shell(strjoin(c"cat ", ht_quote(path_join(directory, c"status"))))))
	char* output = qn_shell(strjoin(c"cat ", ht_quote(path_join(directory, c"output"))))
	qn_shell(strjoin(c"rm -rf ", ht_quote(directory)))
	if (status != 0): print2(output)
	ht_require(status == 0, strjoin(c"device trial failed with status ", itoa(status)))
	json_value* record = vj_one(c"stdout", output)
	vj_i(record, c"exit_code", status)
	vj_f(record, c"elapsed_seconds", cast(float, vm_ns() - start) / 1000000000.0)
	return record
char* qn_tree_digest():
	process_result* result = ht_checked(ht_command(c"git ls-files --cached --others --exclude-standard -z"))
	list[char*] names = new list[char*]
	int start = 0
	for i in range(result.stdout_length):
		if (result.stdout_text[i] == 0):
			names.push(path_clone_range(result.stdout_text + start, i - start))
			start = i + 1
	ht_sort(names)
	whash* hash = whash_new(WHASH_SHA256)
	for char* name in names:
		file_stat st
		if (!ends_with(name, c".w") || file_stat_path(name, &st) != 0 || (st.mode & FILE_S_IFMT) != FILE_S_IFREG): continue
		string_builder* data = ht_read(name)
		char[32] digest
		sha256(data.data, data.length, &digest[0])
		whash_update(hash, name, strlen(name) + 1)
		whash_update(hash, &digest[0], 32)
		string_free(data)
	char[32] digest
	whash_final(hash, &digest[0])
	whash_free(hash)
	return hex_encode(&digest[0], 32)

int main(int argc, int argv):
	arg_parser* parser = argparse_new(c"qualify_native")
	arg_spec* suite = argparse_add_option(parser, c"--suite", c"NAME", c"fixture suite")
	argparse_arg_choices(suite, c"all,atomic,durability")
	argparse_arg_default(suite, c"all")
	argparse_add_option(parser, c"--compiler", c"FILE", c"host compiler")
	argparse_arg_choices(argparse_add_list(parser, c"--cross", c"ARCH", c"compile only (repeatable)"), c"arm64,arm64_darwin")
	argparse_add_flag(parser, c"--host-smoke", c"x64 supplementary harness validation")
	argparse_add_flag(parser, c"--emulated", c"arm64 under qemu-user via bin/wrun (supplementary, not native)")
	argparse_add_option(parser, c"--adb", c"SERIAL", c"physical Android ARM64 device")
	argparse_arg_choices(argparse_add_option(parser, c"--pac", c"MODE", c"pointer authentication"), c"off,ret,full")
	argparse_arg_default(argparse_add_int(parser, c"--rounds", c"N", c"runtime rounds"), c"10")
	argparse_arg_default(argparse_add_int(parser, c"--timeout", c"SECONDS", c"per command"), c"120")
	argparse_add_option(parser, c"--output", c"FILE", c"evidence JSON")
	argparse_add_option(parser, c"--scratch", c"PATH", c"existing filesystem being qualified")
	args_init(argc, argv)
	# Preserve the old --cross ARCH ARCH spelling as well as repeated options.
	list[char*] arguments = new list[char*]
	for i in range(1, argc):
		if (strcmp(args_get(i), c"--cross") != 0): arguments.push(args_get(i))
		else:
			int count = 0
			while (i + 1 < argc && args_get(i + 1)[0] != '-'):
				i = i + 1
				arguments.push(c"--cross")
				arguments.push(args_get(i))
				count = count + 1
			ht_require(count > 0, c"--cross requires at least one architecture")
	arg_namespace* args = argparse_parse_list(parser, arguments)
	if (args.help):
		print(argparse_help_for(args))
		return 0
	ht_require(args.error == 0, argparse_error_text(args))
	int rounds = argparse_get_int(args, c"rounds")
	int timeout = argparse_get_int(args, c"timeout")
	ht_require(rounds > 0 && timeout > 0 && timeout <= 2147468, c"rounds and timeout must be positive and bounded")
	list[char*] archs = argparse_get_list(args, c"cross")
	int cross = archs.length > 0
	int smoke = argparse_get_bool(args, c"host_smoke")
	int emulated = argparse_get_bool(args, c"emulated")
	qn_serial = argparse_get(args, c"adb")
	ht_require(cross + smoke + emulated + (qn_serial != 0) <= 1, c"--cross, --host-smoke, --emulated and --adb are mutually exclusive")
	char* suite_name = argparse_get(args, c"suite")
	char* scratch_parent = argparse_get(args, c"scratch")
	ht_require(qn_serial == 0 || scratch_parent == 0, c"--adb stages trials under /data/local/tmp and does not accept --scratch")
	char* machine = vm_command(c"uname -m")
	char* system = vm_command(c"uname -s")
	int darwin = strcmp(system, c"Darwin") == 0
	int cpus = 0
	if (darwin): cpus = atoi(vm_command(c"sysctl -n hw.logicalcpu"))
	else: cpus = atoi(vm_command(c"getconf _NPROCESSORS_ONLN"))
	char* evidence = c"cross-compilation only"
	char* runner = 0
	if (qn_serial != 0):
		archs.push(c"arm64")
		evidence = c"native runtime stress on Android Linux (host cross-compiled; process-crash, not power-loss evidence)"
		if (strcmp(suite_name, c"atomic") == 0): evidence = c"native concurrent ordering stress on Android Linux (host cross-compiled)"
	elif (emulated):
		# Exercises the arm64 adapters end to end on an x86_64 build host.
		# qemu-user forwards each guest syscall to the host kernel, so this
		# validates the ABI translation and the harness, never ARM64
		# hardware ordering or the device's flush behavior.
		ht_require(strcmp(machine, c"x86_64") == 0 && strcmp(system, c"Linux") == 0, c"--emulated requires an x64 Linux host")
		archs.push(c"arm64")
		runner = ht_resolve(c"bin/wrun")
		evidence = c"arm64 supplementary runtime harness validation under qemu-user (not native qualification)"
	elif (smoke):
		ht_require(strcmp(machine, c"x86_64") == 0 && strcmp(system, c"Linux") == 0, c"host smoke requires x64 Linux")
		archs.push(c"x64")
		evidence = c"x64 supplementary runtime harness validation"
	elif (!cross):
		ht_require((strcmp(machine, c"aarch64") == 0 || strcmp(machine, c"arm64") == 0) && (darwin || strcmp(system, c"Linux") == 0), c"native qualification requires ARM64 Linux or Apple Silicon; use --cross for builds")
		ht_require(cpus >= 2, c"native concurrent qualification requires at least two logical CPUs")
		if (darwin): archs.push(c"arm64_darwin")
		else: archs.push(c"arm64")
		evidence = c"native runtime stress (process-crash, not power-loss evidence)"
		if (strcmp(suite_name, c"atomic") == 0): evidence = c"native concurrent ordering stress"
	char* compiler = argparse_get(args, c"compiler")
	if (compiler == 0):
		compiler = c"bin/wv2"
		if (darwin): compiler = c"bin/wv2_darwin"
	compiler = ht_resolve(compiler)
	qn_output = argparse_get(args, c"output")
	if (qn_output == 0): qn_output = strjoin(strjoin(strjoin(c"bin/qualification_", archs[0]), strjoin(c"_", suite_name)), c".json")
	ht_mkdir(path_dirname(qn_output))
	qn_report = json_parse(c"{\"iterations_per_litmus\":100000,\"runs\":[],\"passed\":false}")
	ht_on_cleanup = qn_cleanup
	vj_s(qn_report, c"evidence", evidence)
	vj_s(qn_report, c"utc", vm_command(c"date -u +%Y-%m-%dT%H:%M:%SZ"))
	json_object_set(qn_report, c"uname", vj_strings(ht_argv(system, vm_command(c"uname -n"), vm_command(c"uname -r"), vm_command(c"uname -v"), machine, c"")))
	vj_i(qn_report, c"cpu_count", cpus)
	vj_s(qn_report, c"compiler", compiler)
	vj_s(qn_report, c"compiler_sha256", vsi_digest(compiler))
	vj_s(qn_report, c"driver_sha256", vsi_digest(c"tools/qualify_native.w"))
	vj_s(qn_report, c"suite", suite_name)
	vj_i(qn_report, c"rounds", rounds)
	vj_s(qn_report, c"revision", vm_command(c"git rev-parse HEAD"))
	process_result* diff = ht_checked(ht_command(c"git diff HEAD"))
	vj_s(qn_report, c"worktree_diff_sha256", ht_digest(diff.stdout_text, diff.stdout_length))
	vj_s(qn_report, c"w_source_tree_sha256", qn_tree_digest())
	if (strcmp(system, c"Linux") == 0 && path_exists(c"/proc/cpuinfo")): vj_s(qn_report, c"cpuinfo", ht_read(c"/proc/cpuinfo").data)
	if (darwin):
		vj_s(qn_report, c"hardware", qn_run(ht_command(c"sysctl hw.model machdep.cpu.brand_string hw.physicalcpu hw.logicalcpu hw.cachelinesize kern.hv_vmm_present")))
		vj_s(qn_report, c"os_version", qn_run(ht_command(c"sw_vers")))
	char* build = ht_resolve(c"bin/native_qualification")
	if (emulated): build = path_join(build, c"emulated")
	if (qn_serial != 0):
		build = path_join(build, c"adb")
		json_value* info = qn_device()
		json_value* host = json_object()
		for char* key in ht_command(c"uname cpu_count cpuinfo hardware os_version"):
			if (json_object_has(qn_report, key)):
				json_object_set(host, key, ht_field(qn_report, key))
				qn_report.object_values.remove(key)
		json_object_set(qn_report, c"build_host", host)
		json_object_set(qn_report, c"execution_host", info)
		vj_s(qn_report, c"execution_transport", c"adb shell; direct static Linux arm64 ELF, no translation")
		vj_s(qn_report, c"remote_directory", qn_remote)
	ht_mkdir(build)
	list[char*] fixtures = ht_command(c"atomic_native durability_native")
	if (strcmp(suite_name, c"all") != 0): fixtures = ht_argv(strjoin(suite_name, c"_native"))
	list[char*] modes = ht_command(c"streaming retained optimized")
	for char* arch in archs:
		for char* mode in modes:
			for char* fixture in fixtures:
				char* source = ht_resolve(strjoin(strjoin(c"tests/", fixture), c"_fixture.w"))
				char* binary = path_join(build, strjoin(strjoin(fixture, c"_"), strjoin(arch, strjoin(c"_", mode))))
				char* staging = tempfile_mkdtemp_in(build, c"build-", c"")
				ht_require(staging != 0, c"cannot create compile staging directory")
				if (ht_scratch == 0): ht_scratch = new list[char*]
				ht_scratch.push(staging)
				char* staged = path_join(staging, path_basename(binary))
				list[char*] command = ht_argv(compiler, arch)
				if (strcmp(mode, c"streaming") == 0): command.push(c"--streaming")
				else:
					command.push(c"--ast-required")
					command.push(c"--ast-retain")
					if (strcmp(mode, c"optimized") == 0): command.push(c"--ast-opt")
				if (argparse_get(args, c"pac") != 0): command.push(strjoin(c"--pac=", argparse_get(args, c"pac")))
				for char* arg in ht_argv(source, c"-o", staged): command.push(arg)
				println(strjoin(c"compile ", path_basename(binary)))
				qn_run(command, 0, timeout * 1000)
				ht_require(rename(staged, binary) == 0, c"cannot publish fresh executable inode")
				json_value* record = vj_one(c"arch", arch)
				vj_s(record, c"mode", mode)
				vj_s(record, c"fixture", fixture)
				json_object_set(record, c"command", vj_strings(command))
				vj_s(record, c"source_sha256", vsi_digest(source))
				vj_s(record, c"binary", binary)
				vj_s(record, c"binary_sha256", vsi_digest(binary))
				vj_i(record, c"completed_rounds", 0)
				json_array_push(ht_field(qn_report, c"runs"), record)
				if (cross): continue
				char* remote = 0
				if (qn_serial != 0):
					remote = qn_stage(binary)
					vj_s(record, c"remote_binary", remote)
					json_object_set(record, c"device_binary_sha256", ht_field(record, c"binary_sha256"))
					json_object_set(record, c"trials", json_array())
				for trial in range(rounds):
					if (remote != 0): json_array_push(ht_field(record, c"trials"), qn_trial(remote, timeout))
					else:
						char* scratch = tempfile_mkdtemp_in(scratch_parent, c"w-native-", c"")
						ht_require(scratch != 0, c"cannot create qualification scratch directory")
						if (ht_scratch == 0): ht_scratch = new list[char*]
						ht_scratch.push(scratch)
						if (!json_object_has(qn_report, c"filesystem")):
							vj_s(qn_report, c"scratch_parent", path_dirname(scratch))
							vj_s(qn_report, c"filesystem", qn_run(ht_argv(c"df", c"-k", scratch)))
						if (runner != 0): qn_run(ht_argv(runner, c"arm64", binary), scratch, timeout * 1000)
						else: qn_run(ht_argv(binary), scratch, timeout * 1000)
						shutil_rmtree(scratch)
					vj_i(record, c"completed_rounds", trial + 1)
				println(strjoin(c"pass ", path_basename(binary)))
	vj_b(qn_report, c"passed", 1)
	ht_cleanup()
	return 0
