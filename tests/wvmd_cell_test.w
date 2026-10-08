# wbuild: target=wvmd_cell_test tag=tests dep=wv2 dep=wvmd_cell_fixture
# wbuild: step="bin/wv2 x64 tests/wvmd_cell_test.w -o bin/wvmd_cell_test"
# wbuild: step="bin/wvmd_cell_test" timeout=30000
import lib.testing
import lib.vmm.control
import lib.vmm.cell_worker
import lib.ci_skip


void cell_test_worker(json_value* config):
	vms_cell_worker(config)


void test_backing_rejects_extra_descriptors_without_leaks():
	int[2] sockets
	assert_equal(0, socket_pair(&sockets[0]))
	int available = sys_fcntl(sockets[0], 0, 0) # F_DUPFD probes lowest free fd.
	asserts(c"fd probe", available >= 0)
	close(available)
	char[56] message
	char[16] iov
	char[24] control
	char marker = '!'
	mem_fill[char](&message[0], 0, 56)
	mem_fill[char](&control[0], 0, 24)
	save_int64(&iov[0], cast(int, &marker))
	save_int64(&iov[8], 1)
	save_int64(&control[0], 24)
	save_int32(&control[8], 1)
	save_int32(&control[12], 1)
	save_int32(&control[16], sockets[0])
	save_int32(&control[20], sockets[1])
	save_int64(&message[16], cast(int, &iov[0]))
	save_int64(&message[24], 1)
	save_int64(&message[32], cast(int, &control[0]))
	save_int64(&message[40], 24)
	assert_equal(1, syscall(46, sockets[0], cast(int, &message[0]), 16384))
	assert_equal(-1, vm_backing_receive(sockets[1]))
	int probe = sys_fcntl(sockets[0], 0, 0)
	assert_equal(available, probe)
	close(probe)
	close(sockets[0])
	close(sockets[1])


int cell_test_template(vm_scheduler* scheduler):
	json_value* params = json_object()
	json_object_set(params, c"image", json_string(c"bin/wvmd_cell_fixture"))
	json_value* answer = vms_template_create(scheduler, params)
	int id = vms_number(answer, c"template", 0)
	json_free(answer)
	json_free(params)
	return id


vms_session* cell_test_spawn(vm_scheduler* scheduler, int template, int region, int writable):
	json_value* params = json_object()
	json_object_set(params, c"backend", json_string(c"cell"))
	json_object_set(params, c"template", json_int(template))
	if (region > 0):
		json_object_set(params, c"region", json_int(region))
		json_object_set(params, c"region_write", json_int(writable))
	json_value* answer = vms_submit(scheduler, params)
	int id = vms_number(answer, c"session", 0)
	json_free(answer)
	json_free(params)
	return vms_find(scheduler, id)


void cell_test_ready(vm_scheduler* scheduler, vms_session* session):
	int deadline = time_monotonic_ms() + 5000
	while (session.state != vms_ready && time_monotonic_ms() < deadline):
		vms_tick(scheduler)
		asserts(c"cell worker remains healthy", session.state != vms_failed)
		process_sleep_ms(1)
	assert_equal(vms_ready, session.state)


void cell_test_exec(vm_scheduler* scheduler, vms_session* session, char* mode, char* expected, int status):
	json_value* params = json_object()
	json_value* args = json_array()
	json_array_push(args, json_string(c"/fixture"))
	json_array_push(args, json_string(mode))
	json_object_set(params, c"argv", args)
	json_value* answer = vms_exec(scheduler, session, params)
	asserts(c"command accepted", vms_field(answer, c"error") == 0)
	json_free(answer)
	json_free(params)
	cell_test_ready(scheduler, session)
	assert_equal(status, session.status)
	assert_strings_equal(expected, vms_text(session.result, c"stdout_hex"))


void test_cell_template_lifetime_and_bounds():
	vm_scheduler* scheduler = vms_new(1, 1, 1, 512, cell_test_worker)
	int template = cell_test_template(scheduler)
	asserts(c"template created without KVM", template > 0)
	assert_equal(256, scheduler.template_memory_mb)
	vms_session* session = cell_test_spawn(scheduler, template, 0, 0)
	asserts(c"queued session retains template", session != 0)
	json_value* answer = vms_template_destroy(scheduler, template)
	json_free(answer)
	assert_equal(256, scheduler.template_memory_mb)
	asserts(c"removed template cannot be admitted", cell_test_spawn(scheduler, template, 0, 0) == 0)
	vms_destroy(scheduler, session)
	assert_equal(0, scheduler.template_memory_mb)
	scheduler.max_memory_mb = 255
	assert_equal(0, cell_test_template(scheduler))
	vms_free(scheduler)


void test_backing_quota_attachment_fails_closed():
	vm_cgroup invalid
	invalid.fd = -1
	invalid.path = 0
	asserts(c"template never falls back outside quota", vm_template_load_charged(&invalid, c"bin/wvmd_cell_fixture") == 0)
	asserts(c"region never falls back outside quota", vm_region_new_charged(&invalid, 4096, 0, c"private") == 0)


void test_registry_leases_reclaim_orphaned_handles():
	vm_scheduler* scheduler = vms_new(1, 1, 1, 512, cell_test_worker)
	int id = cell_test_template(scheduler)
	vm_template* template = vms_template_find(scheduler, id)
	asserts(c"leased template", template != 0)
	template.lease_deadline = time_monotonic_ms() - 1
	json_value* params = json_object()
	json_value* answer = vms_region_create(scheduler, params)
	int region_id = vms_number(answer, c"region", 0)
	json_free(answer)
	json_free(params)
	vm_region* region = vms_region_find(scheduler, region_id)
	asserts(c"leased region", region != 0)
	region.lease_deadline = time_monotonic_ms() - 1
	vms_tick(scheduler)
	asserts(c"orphaned template expires", vms_template_find(scheduler, id) == 0)
	asserts(c"orphaned region expires", vms_region_find(scheduler, region_id) == 0)
	assert_equal(0, scheduler.template_memory_mb)
	assert_equal(0, scheduler.region_bytes)
	vms_free(scheduler)


void test_backing_is_charged_to_delegated_quota():
	char* parent = env_get(c"WVM_TEST_CGROUP")
	if (parent == 0):
		println(c"SKIP: set WVM_TEST_CGROUP for shared backing charge accounting")
		return
	vm_cgroup* quota = vm_cgroup_new(parent, 100, 64, 8)
	asserts(c"delegated backing quota", quota != 0)
	cell_snapshot* snapshot = vm_template_load_charged(quota, c"bin/wvmd_cell_fixture")
	asserts(c"charged template creation", snapshot != 0)
	char* path = strjoin(quota.path, c"/memory.current")
	char* current = file_read_text(path)
	asserts(c"template remains charged after helper exits", current != 0 && atoi(current) >= snapshot.resident_pages * 4096)
	free(current)
	free(path)
	vm_region* region = vm_region_new_charged(quota, 4096, 0, c"shared")
	asserts(c"charged region creation", region != 0)
	vm_region_free(region)
	cell_snapshot_free(snapshot)
	vm_cgroup_free(quota)


void test_cell_workers_private_and_explicit_shared_memory():
	int fd = kvm_open_system()
	if (fd < 0):
		test_skip_kvm(c"SKIP: KVM unavailable for daemon cell workers")
		return
	close(fd)
	vm_scheduler* scheduler = vms_new(2, 2, 2, 1024, cell_test_worker)
	# Create the region before the template to exercise descriptor relocation.
	json_value* params = json_object()
	json_object_set(params, c"writable", json_int(1))
	json_value* answer = vms_region_create(scheduler, params)
	int region = vms_number(answer, c"region", 0)
	json_free(params)
	json_free(answer)
	asserts(c"shared region created", region > 0)
	int template = cell_test_template(scheduler)
	vms_session* first = cell_test_spawn(scheduler, template, region, 1)
	vms_session* second = cell_test_spawn(scheduler, template, region, 0)
	asserts(c"two cell workers admitted", first != 0 && second != 0)
	answer = vms_template_destroy(scheduler, template)
	json_free(answer)
	answer = vms_region_destroy(scheduler, region)
	json_free(answer)
	cell_test_ready(scheduler, first)
	cell_test_ready(scheduler, second)
	cell_test_exec(scheduler, first, c"private", c"707269766174650a", 0)
	cell_test_exec(scheduler, first, c"private", c"707269766174650a", 0)
	cell_test_exec(scheduler, second, c"private", c"707269766174650a", 0)
	cell_test_exec(scheduler, first, c"region-write", c"", 0)
	vms_destroy(scheduler, first)
	cell_test_exec(scheduler, second, c"region-read", c"5a", 0)
	cell_test_exec(scheduler, second, c"region-write", c"", 139)
	cell_test_exec(scheduler, second, c"region-read", c"5a", 0)
	vms_destroy(scheduler, second)
	assert_equal(0, scheduler.template_memory_mb)
	assert_equal(0, scheduler.region_bytes)
	assert_equal(0, scheduler.memory_mb)
	assert_equal(0, scheduler.active)
	vms_free(scheduler)
