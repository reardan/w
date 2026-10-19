# wbuild: binary=wvm_darwin_e2e arch=x64 tag=tests
# Required CLI/RPC lifecycle assertions; invoked by the native Mac gate.
import tools.mac.vm_harness

char* ve_out
char* ve_worker
char* ve_daemon
char* ve_guest
json_value* ve_measurements

void ve_record(char* kind, char* mode, int start):
	json_value* row = vj_one(c"kind", kind)
	if (mode != 0): vj_s(row, c"mode", mode)
	vj_f(row, c"milliseconds", cast(float, vm_ns() - start) / 1000000.0)
	json_array_push(ve_measurements, row)

void ve_cli(char* mode, int status, char* text = 0, list[char*] options = 0, list[char*] extra = 0, char* input = 0):
	list[char*] command = ht_argv(ve_worker, c"run")
	if (options != 0):
		for char* option in options: command.push(option)
	command.push(ve_guest)
	command.push(mode)
	if (extra != 0):
		for char* arg in extra: command.push(arg)
	spawn_options* env = spawn_options_new()
	env.env = env_copy_with(env_current(), c"W_VM_HOST_SECRET", c"must-not-leak")
	int start = vm_ns()
	if (input == 0): input = c""
	process_result* result = ht_run(command, env, input, 10000)
	ve_record(c"cli-process-create-and-command", mode, start)
	ht_require(result.status == status, strjoin(c"CLI unexpected status: ", mode))
	if (text != 0): ht_require(contains(result.stdout_text, text), strjoin(c"CLI stdout mismatch: ", mode))
	ht_require(result.stdout_length <= 4194304, c"unbounded CLI output")
	println(strjoin(c"PASS CLI ", mode))

json_value* ve_execute(char* path, char* session, char* mode, int status = 0, char* text = 0, int timeout = 1000, char* input = 0):
	int start = vm_ns()
	json_value* result = vm_execute(path, session, mode, status, text, timeout, input)
	ve_record(c"ready-worker-command", mode, start)
	return result

int ve_child(int parent):
	list[char*] children = split(ht_checked(ht_argv(c"pgrep", c"-P", itoa(parent))).stdout_text)
	ht_require(children.length == 1, c"expected exactly one daemon worker")
	return atoi(children[0])

void ve_daemon_tests():
	char* path = path_join(ht_temp(), c"daemon.sock")
	hm_sample* daemon = vm_start(ve_daemon, ve_worker, path, 2, 2)
	file_stat st
	ht_require(file_stat_path(path, &st) == 0 && (st.mode & 511) == 384, c"socket permissions")
	json_value* client = json_parse(ht_checked(ht_argv(ve_daemon, c"call", path, c"capabilities")).stdout_text)
	ht_require(strcmp(ht_text(ht_field(client, c"result"), c"host_backend"), c"hypervisor.framework") == 0, c"daemon client capabilities")
	int start = vm_ns()
	char* template_id = ht_text(vm_ok(path, c"template_create", vm_image(ve_guest)), c"template")
	ve_record(c"template-create", 0, start)
	json_value* config = vm_template(template_id)
	vj_i(config, c"cpus", 1)
	vj_i(config, c"memory_mb", 256)
	char* first = ht_text(vm_ok(path, c"vm_spawn", config), c"session")
	char* second = ht_text(vm_ok(path, c"vm_spawn", config), c"session")
	vm_state(path, first)
	vm_state(path, second)
	char* queued = ht_text(vm_ok(path, c"vm_spawn", config), c"session")
	ht_require(strcmp(ht_text(vm_ok(path, c"vm_status", vj_one(c"session", queued)), c"state"), c"queued") == 0, c"admission queue bypassed")
	vm_ok(path, c"vm_cancel", vj_one(c"session", queued))
	for char* entry in ht_split(c"{\"backend\":\"box\"}|{\"cpus\":2}|{\"network\":false}|{\"host_cpu_percent\":10}|{\"shared_regions\":[]}", '|'):
		json_value* params = vm_template(template_id)
		json_value* overrides = json_parse(entry)
		for char* key in overrides.object_values.keys(): json_object_set(params, key, ht_field(overrides, key))
		ht_require(json_object_has(vm_rpc(path, c"vm_spawn", params), c"error"), c"unsupported option accepted")
	for char* method in ht_command(c"vm_snapshot debug region_create"): ht_require(json_object_has(vm_rpc(path, method, vj_one(c"session", first)), c"error"), c"unsupported method accepted")
	vm_ok(path, c"template_destroy", vj_one(c"template", template_id))
	for i in range(3):
		ve_execute(path, first, c"alloc", 0, c"cell allocator containers FP OK")
		ve_execute(path, second, c"hello", 7, c"hello from an ARM64 cell")
	vm_ok(path, c"vm_restore", vj_one(c"session", first))
	vm_state(path, first)
	ve_execute(path, first, c"alloc", 0, c"cell allocator containers FP OK")
	ve_execute(path, first, c"spin", 124, 0, 30)
	ve_execute(path, first, c"hello", 7, c"hello from an ARM64 cell")
	char* binary_input = c"62696e61727900696e707574"
	json_value* echoed = ve_execute(path, first, c"input", 0, 0, 1000, binary_input)
	ht_require(strcmp(ht_text(echoed, c"stdout_hex"), binary_input) == 0, c"binary input changed")
	ht_require(strcmp(ht_text(ve_execute(path, first, c"input"), c"stdout_hex"), c"") == 0, c"stdin leaked across reset")
	json_value* bad = vj_one(c"session", first)
	json_object_set(bad, c"argv", vj_strings(ht_command(c"cell input")))
	vj_s(bad, c"stdin_hex", c"zz")
	ht_require(json_object_has(vm_rpc(path, c"vm_exec", bad), c"error"), c"invalid stdin hex accepted")
	vm_exec(path, second, c"spin", 600000)
	vm_ok(path, c"vm_cancel", vj_one(c"session", second))
	ht_require(json_object_has(vm_rpc(path, c"vm_status", vj_one(c"session", second)), c"error"), c"canceled session retained")
	char* replacement = ht_text(vm_ok(path, c"vm_spawn", vm_image(ve_guest)), c"session")
	vm_state(path, replacement)
	ve_execute(path, replacement, c"hello", 7, c"hello from an ARM64 cell")
	vm_ok(path, c"vm_destroy", vj_one(c"session", replacement))
	vm_ok(path, c"vm_destroy", vj_one(c"session", first))
	char* leased = ht_text(vm_ok(path, c"vm_spawn", vm_image(ve_guest, 100)), c"session")
	int deadline = process_monotonic_ms() + 3000
	while (!json_object_has(vm_rpc(path, c"vm_status", vj_one(c"session", leased)), c"error")):
		ht_require(process_monotonic_ms() < deadline, c"expired lease retained")
		process_sleep_ms(20)
	char* crash = ht_text(vm_ok(path, c"vm_spawn", vm_image(ve_guest)), c"session")
	vm_state(path, crash)
	ht_require(kill(ve_child(daemon.child.pid), 9) == 0, c"cannot kill worker")
	vm_state(path, crash, c"failed")
	vm_ok(path, c"vm_destroy", vj_one(c"session", crash))
	char* recovered = ht_text(vm_ok(path, c"vm_spawn", vm_image(ve_guest)), c"session")
	vm_state(path, recovered)
	ve_execute(path, recovered, c"hello", 7, c"hello from an ARM64 cell")
	vm_ok(path, c"vm_destroy", vj_one(c"session", recovered))
	json_value* stats = vm_ok(path, c"stats")
	ht_require(ht_number(stats, c"active") == 0 && ht_number(stats, c"queued") == 0, c"admission leaked")
	vm_ok(path, c"stop")
	hm_finish(daemon, 5000)
	ht_require(daemon.status == 0 && !daemon.timed_out && !path_exists(path), c"normal shutdown retained socket or process")
	ht_require(shutil_copyfile(daemon.stdout_path, path_join(ve_out, c"daemon.log")) == 0, c"cannot save daemon log")
	daemon = vm_start(ve_daemon, ve_worker, path, 2, 2)
	char* orphan = ht_text(vm_ok(path, c"vm_spawn", vm_image(ve_guest)), c"session")
	vm_state(path, orphan)
	vm_exec(path, orphan, c"spin", 600000)
	int worker = ve_child(daemon.child.pid)
	process_kill(daemon.child, 9)
	ht_require(process_wait_or_kill(daemon.child, 5000) == 137, c"daemon did not die from SIGKILL")
	deadline = process_monotonic_ms() + 5000
	while (ht_run(ht_argv(c"ps", c"-p", itoa(worker)), 0, 0, 2000).status == 0):
		ht_require(process_monotonic_ms() < deadline, c"orphan guest survived daemon death")
		process_sleep_ms(20)
	println(c"PASS RPC templates, clones, queue, reset, timeout, cancel, replacement, leases, client")

int main(int argc, int argv):
	args_init(argc, argv)
	ht_require(argc == 2, c"usage: wvm_darwin_e2e OUTPUT_DIRECTORY")
	vm_native()
	ve_out = ht_resolve(args_get(1))
	ve_worker = path_join(ve_out, c"wvm_darwin")
	ve_daemon = path_join(ve_out, c"wvmd_darwin")
	ve_guest = path_join(ve_out, c"wvm_darwin_fixture")
	ve_measurements = json_array()
	json_value* capabilities = json_parse(ht_checked(ht_argv(ve_worker, c"capabilities")).stdout_text)
	ht_require(strcmp(ht_text(capabilities, c"host_backend"), c"hypervisor.framework") == 0 && strcmp(ht_text(capabilities, c"guest_arch"), c"arm64") == 0, c"wrong native capabilities")
	for char* key in ht_command(c"host_quotas live_checkpoints debugger shared_regions boxes filesystem network"):
		json_value* value = ht_field(capabilities, key)
		ht_require(value.type == json_type_bool() && !value.int_value, c"unsupported capability advertised")
	ve_cli(c"hello", 7, c"hello from an ARM64 cell")
	ve_cli(c"argv", 0, c"cell argv OK", 0, ht_argv(c"payload"))
	ve_cli(c"alloc", 0, c"cell allocator containers FP OK")
	ve_cli(c"deny", 0, c"cell denials OK")
	ve_cli(c"memory", 0, c"cell memory OK")
	ve_cli(c"exit", 37)
	ve_cli(c"spin", 124, 0, ht_command(c"--timeout-ms 30"))
	for char* mode in ht_command(c"monitor readonly unmapped nx hvc"): ve_cli(mode, 139)
	ve_cli(c"output", 125)
	ve_cli(c"input", 0, c"bounded input\n", 0, 0, c"bounded input\n")
	list[char*] options = ht_command(c"--fs-root --net-allow --max-threads")
	list[char*] values = ht_command(c"/tmp 127.0.0.1:1 2")
	for i in range(options.length):
		process_result* result = ht_run(ht_argv(ve_worker, c"run", options[i], values[i], ve_guest, c"hello"), 0, 0, 5000)
		ht_require(result.status != 0 && contains(result.stderr_text, c"unsupported"), c"unsupported CLI option accepted")
	ve_daemon_tests()
	json_value* report = json_parse(c"{\"units\":\"milliseconds\",\"guest_ram_bytes\":268435456,\"conditions\":\"local sequential functional-gate samples; mixed modes, not a throughput benchmark\"}")
	file_stat st
	ht_require(file_stat_path(ve_guest, &st) == 0, c"cannot stat guest")
	vj_i(report, c"image_bytes", st.size)
	json_object_set(report, c"samples", ve_measurements)
	json_value* summaries = json_object()
	for char* kind in ht_command(c"cli-process-create-and-command template-create ready-worker-command"):
		list[int] samples = new list[int]
		for json_value* row in ve_measurements.array_values:
			if (strcmp(ht_text(row, c"kind"), kind) == 0): samples.push(cast(int, ht_field(row, c"milliseconds").float_value * 1000000.0))
		json_value* quantiles = vm_quantiles(samples, c"ms", 0)
		json_value* summary = json_object()
		vj_i(summary, c"samples", samples.length)
		for char* p in ht_command(c"50 95 99"): json_object_set(summary, strjoin(c"p", p), ht_field(quantiles, strjoin(strjoin(c"p", p), c"_ms")))
		json_object_set(summaries, kind, summary)
	json_object_set(report, c"summaries", summaries)
	vj_write(path_join(ve_out, c"lifecycle-measurements.json"), report)
	ht_cleanup()
	println(c"PASS native CLI and daemon lifecycle")
	return 0
