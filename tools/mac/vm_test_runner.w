# wbuild: binary=darwin_vm_gate arch=x64 tag=tests
# Mandatory signed native Darwin VM acceptance gate; every artifact is a fresh inode.
import tools.mac.vm_harness

char* vg_out
json_value* vg_report

void vg_save():
	if (vg_report == 0): return
	if (strcmp(ht_text(vg_report, c"status"), c"running") == 0):
		vj_s(vg_report, c"status", c"failed")
		vj_s(vg_report, c"error", c"gate failed; see step logs and terminal diagnostics")
	vj_write(path_join(vg_out, c"report.json"), vg_report)

char* vg_run(char* label, list[char*] command, int expected = 0, int timeout = 180000, int native = 0):
	println(strjoin(strjoin(c"[", label), c"]"))
	hm_sample* sample = hm_start(command)
	hm_finish(sample, timeout)
	char* output = strjoin(ht_read(sample.stdout_path).data, ht_read(sample.stderr_path).data)
	char* log = path_join(vg_out, strjoin(label, c".log"))
	ht_write(log, output, strlen(output))
	json_value* step = vj_one(c"name", label)
	json_object_set(step, c"command", vj_strings(command))
	vj_f(step, c"seconds", hm_elapsed(sample))
	vj_i(step, c"status", sample.status)
	json_array_push(ht_field(vg_report, c"steps"), step)
	print(output)
	ht_require(!sample.timed_out && sample.status == expected, strjoin(c"gate step failed: ", label))
	if (native):
		for char* line in ht_split(output, 10): ht_require(!starts_with(strip(line), c"SKIP"), strjoin(c"native execution skipped: ", label))
	return output

void vg_compile(char* compiler, char* source, char* output, char* arch = 0, int strict = 1):
	if (arch == 0): arch = c"arm64_darwin"
	char* name = path_basename(output)
	vg_run(strjoin(name, c"-check"), ht_argv(compiler, c"check", c"--json", arch, source))
	list[char*] command = ht_argv(compiler, arch)
	if (strict): command.push(c"--strict")
	for char* arg in ht_argv(source, c"-o", output): command.push(arg)
	vg_run(strjoin(name, c"-build"), command)

void vg_sign(char* path):
	char* name = path_basename(path)
	vg_run(strjoin(name, c"-sign"), ht_argv(c"codesign", c"--force", c"--sign", c"-", c"--entitlements", c"tools/mac/hypervisor.entitlements", path))
	vg_run(strjoin(name, c"-signature"), ht_argv(c"codesign", c"--verify", c"--strict", path))
	char* entitlements = vg_run(strjoin(name, c"-entitlements"), ht_argv(c"codesign", c"-d", c"--entitlements", c":-", path))
	ht_require(contains(entitlements, c"com.apple.security.hypervisor") && contains(entitlements, c"<true/>"), c"hypervisor entitlement missing")

void vg_pool(char* output, char* guest):
	json_value* records = json_array()
	for char* line in ht_split(output, 10):
		if (line[0] == '{'): json_array_push(records, json_parse(line))
	json_value* summary = json_object()
	for char* phase in ht_command(c"pool-create-two ready-acquire first-command ready-replacement"):
		list[int] samples = new list[int]
		for json_value* row in records.array_values:
			if (strcmp(ht_text(row, c"phase"), phase) == 0): samples.push(ht_number(row, c"elapsed_ns"))
		int expected = 21
		if (strcmp(phase, c"pool-create-two") == 0): expected = 1
		ht_require(samples.length == expected, strjoin(c"incomplete pool measurement: ", phase))
		json_object_set(summary, phase, vm_quantiles(samples, c"ns"))
	json_value* report = json_parse(c"{\"schema\":\"wvm-darwin-ready-pool-v1\",\"units\":\"nanoseconds\",\"capacity\":2,\"guest_ram_bytes\":268435456,\"conditions\":\"single owner thread; fresh private ready RAM cells; warm template backing; no VM/vCPU retained between leases\",\"semantics\":{\"ready-acquire\":\"transfer an already prepared cell; excludes guest run and VM creation\",\"ready-replacement\":\"restore one private ready RAM cell from retained template backing\",\"first-command\":\"allocator/containers/FP guest on acquired cell; includes VM/vCPU creation, execution and destruction\",\"pool-create-two\":\"prepare two ready private RAM cells; excludes template capture\"}}")
	json_object_set(report, c"source_identity", ht_field(vg_report, c"source_identity"))
	file_stat st
	ht_require(file_stat_path(guest, &st) == 0, c"cannot stat guest")
	vj_i(report, c"image_bytes", st.size)
	json_object_set(report, c"runs", records)
	json_object_set(report, c"summary", summary)
	vj_write(path_join(vg_out, c"pool.json"), report)

int main():
	char* stamp = vm_command(c"date +%Y%m%d-%H%M%S")
	ht_mkdir(c"bin/darwin-vm-gate")
	vg_out = ht_resolve(path_join(c"bin/darwin-vm-gate", stamp))
	ht_require(mkdir(vg_out, 493) == 0, c"gate output directory already exists")
	vg_report = json_parse(c"{\"status\":\"running\",\"steps\":[]}")
	vj_s(vg_report, c"output", vg_out)
	ht_on_cleanup = vg_save
	vm_native()
	for char* program in ht_command(c"codesign xcrun sysctl"): ht_require(process_which(program) != 0, strjoin(c"missing native prerequisite: ", program))
	vj_s(vg_report, c"revision", strip(vg_run(c"revision", ht_command(c"git rev-parse HEAD"))))
	vj_s(vg_report, c"worktree", vg_run(c"worktree", ht_command(c"git status --short")))
	json_object_set(vg_report, c"source_identity", source_identity())
	vj_s(vg_report, c"platform", vg_run(c"platform", ht_command(c"sw_vers")))
	vj_s(vg_report, c"hardware", vg_run(c"hardware", ht_command(c"sysctl hw.model machdep.cpu.brand_string hw.memsize hw.pagesize kern.hv_support")))
	vj_s(vg_report, c"sdk", strip(vg_run(c"sdk", ht_command(c"xcrun --show-sdk-version"))))
	char* compiler = env_get(c"W_DARWIN_COMPILER")
	json_value* bootstrap = json_object()
	if (compiler != 0 && compiler[0] != 0):
		compiler = ht_resolve(compiler)
		vj_s(bootstrap, c"override", compiler)
		vj_s(bootstrap, c"sha256", vsi_digest(compiler))
	else:
		list[char*] seed = 0
		for char* line in ht_split(ht_read(c"SEEDS").data, 10):
			if (starts_with(line, c"w_darwin ")): seed = split(line)
		ht_require(seed != 0 && seed.length == 4, c"Darwin SEEDS entry missing")
		compiler = path_join(vg_out, seed[2])
		char* url = strjoin(strjoin(c"https://github.com/reardan/w/releases/download/", seed[1]), strjoin(c"/", seed[2]))
		vg_run(c"seed-download", ht_argv(c"curl", c"--fail", c"--location", c"--silent", c"--show-error", url, c"-o", compiler))
		ht_require(strcmp(vsi_digest(compiler), seed[3]) == 0, c"downloaded Darwin seed does not match SEEDS")
		ht_require(chmod(compiler, 493) == 0, c"cannot chmod seed")
		vj_s(bootstrap, c"tag", seed[1])
		vj_s(bootstrap, c"asset", seed[2])
		vj_s(bootstrap, c"sha256", seed[3])
	json_object_set(vg_report, c"bootstrap", bootstrap)
	for stage in range(2, 5):
		char* target = path_join(vg_out, strjoin(strjoin(c"wv", itoa(stage)), c"_darwin"))
		vg_run(strjoin(c"bootstrap-", itoa(stage)), ht_argv(compiler, c"arm64_darwin", c"--strict", c"w.w", c"-o", target))
		compiler = target
	ht_require(strcmp(vsi_digest(path_join(vg_out, c"wv3_darwin")), vsi_digest(compiler)) == 0, c"native compiler fixpoint failed: wv3 != wv4")
	vj_s(vg_report, c"compiler_fixpoint_sha256", vsi_digest(compiler))
	list[char*] names = ht_command(c"lib hash_table map_set_builtin generator compound_assign limb_builtin dynamic")
	list[char*] sources = ht_command(c"lib/lib_test.w structures/hash_table_test.w tests/map_set_builtin_test.w tests/generator_test.w tests/compound_assign_test.w tests/limb_builtin_test.w tests/dynamic_darwin_test.w")
	for i in range(names.length):
		char* target = path_join(vg_out, strjoin(names[i], c"_darwin"))
		vg_compile(compiler, sources[i], target, 0, 0)
		vg_run(strjoin(names[i], c"-native"), ht_argv(target), 0, 180000, 1)
	char* guest = path_join(vg_out, c"wvm_darwin_fixture")
	vg_compile(compiler, c"tests/wvm_darwin_fixture.w", guest, c"arm64")
	ht_require(shutil_copyfile(guest, c"bin/wvm_darwin_fixture") == 0, c"cannot stage conventional guest path")
	for char* name in ht_command(c"hv_darwin_test wvm_darwin_cell_test wvm_darwin_snapshot_fixture wvm_darwin_cell_snapshot_fixture wvm_darwin_pool_fixture"):
		char* target = path_join(vg_out, name)
		vg_compile(compiler, strjoin(strjoin(c"tests/", name), c".w"), target)
		if (strcmp(name, c"hv_darwin_test") == 0):
			char* output = vg_run(c"missing-entitlement", ht_argv(target), 77, 180000, 1)
			ht_require(contains(output, c"missing-entitlement"), c"unentitled worker did not identify missing entitlement")
			char* fresh = strjoin(target, c"-signed")
			ht_require(shutil_copy(target, fresh) == 0, c"cannot create fresh signing inode")
			target = fresh
		vg_sign(target)
		list[char*] command = ht_argv(target)
		if (strcmp(name, c"wvm_darwin_cell_test") == 0 || strcmp(name, c"wvm_darwin_cell_snapshot_fixture") == 0 || strcmp(name, c"wvm_darwin_pool_fixture") == 0): command.push(guest)
		char* output = vg_run(strjoin(name, c"-native"), command, 0, 120000, 1)
		if (strcmp(name, c"wvm_darwin_pool_fixture") == 0): vg_pool(output, guest)
	for char* name in ht_command(c"wvm wvmd"):
		char* target = path_join(vg_out, strjoin(name, c"_darwin"))
		vg_compile(compiler, strjoin(strjoin(c"tools/", name), c".w"), target)
		vg_sign(target)
	char* worker = path_join(vg_out, c"wvm_darwin")
	char* daemon = path_join(vg_out, c"wvmd_darwin")
	vg_run(c"cli-capabilities", ht_argv(worker, c"capabilities"), 0, 180000, 1)
	vg_run(c"cli-available", ht_argv(worker, c"available"), 0, 180000, 1)
	list[char*] drivers = ht_command(c"wvm_darwin_e2e wvm_darwin_recovery measure_vm_lifecycle measure_vm_memory")
	list[char*] paths = ht_command(c"tests/wvm_darwin_e2e.w tests/wvm_darwin_recovery.w tools/mac/measure_vm_lifecycle.w tools/mac/measure_vm_memory.w")
	for i in range(drivers.length): vg_compile(compiler, paths[i], path_join(vg_out, drivers[i]))
	vg_run(c"lifecycle-e2e", ht_argv(path_join(vg_out, drivers[0]), vg_out), 0, 180000, 1)
	vg_run(c"recovery-security", ht_argv(path_join(vg_out, drivers[1]), c"--worker", worker, c"--daemon", daemon, c"--guest", guest, c"--compiler", compiler), 0, 180000, 1)
	list[char*] command = ht_argv(path_join(vg_out, drivers[2]), c"--worker", worker, c"--daemon", daemon, c"--guest", guest, c"--samples", c"5", c"--output")
	command.push(path_join(vg_out, c"lifecycle.json"))
	vg_run(c"lifecycle-performance", command, 0, 180000, 1)
	char* memory = path_join(vg_out, c"wvm_darwin_memory_fixture")
	vg_compile(compiler, c"tests/wvm_darwin_memory_fixture.w", memory)
	vg_sign(memory)
	char* memory_path = path_join(vg_out, c"memory.json")
	vg_run(c"memory-accounting", ht_argv(path_join(vg_out, drivers[3]), memory, c"--samples", c"5", c"--output", memory_path), 0, 180000, 1)
	json_value* memory_report = ht_json(memory_path)
	json_object_set(memory_report, c"source_identity", ht_field(vg_report, c"source_identity"))
	vj_write(memory_path, memory_report)
	json_object_set(vg_report, c"source_identity_after_gate", source_identity())
	vj_s(vg_report, c"status", c"passed")
	ht_cleanup()
	println(strjoin(c"Native Darwin VM gate passed. Evidence: ", vg_out))
	return 0
