# wbuild: binary=host_evidence_driver arch=x64
# wbuild: target=host_evidence_test tag=tests dep=host_evidence_driver
# wbuild: step="bin/host_evidence_driver"
# Shared subprocess, framed RPC and source identity contracts run on Linux too.
import tools.mac.vm_harness

void he_metrics():
	hm_sample* sample = hm_start(ht_argv(c"sh", c"-c", c"printf output; printf error >&2; exit 7"))
	hm_finish(sample)
	ht_require(sample.status == 7 && !sample.timed_out && hm_elapsed(sample) > 0.0, c"measured child exit/timing")
	ht_equal_file(sample.stdout_path, c"output")
	ht_equal_file(sample.stderr_path, c"error")
	ht_require(ht_number(hm_metrics(sample), c"peak_rss_kib") >= 0, c"invalid rusage")
	char* work = ht_temp()
	char* marker = path_join(work, c"orphan")
	# A descendant that outlives its coordinator must die at the timeout too.
	char* script = strjoin(strjoin(c"(sleep 1; touch ", ht_quote(marker)), c") & wait")
	sample = hm_start(ht_argv(c"sh", c"-c", script))
	hm_finish(sample, 30)
	ht_require(sample.timed_out && sample.status == 137, c"timeout not classified")
	process_sleep_ms(1100)
	ht_require(!path_exists(marker), c"timeout left a descendant alive")
	hm_sample* slow = hm_start(ht_argv(c"sh", c"-c", c"sleep .1"))
	hm_sample* fast = hm_start(ht_argv(c"sh", c"-c", c"exit 0"))
	while (1):
		int a = hm_poll(slow)
		int b = hm_poll(fast)
		if (a && b): break
		process_sleep_ms(1)
	ht_require(hm_elapsed(fast) < hm_elapsed(slow), c"parallel jobs measured at collection time instead of completion")

void he_rpc(int scenario):
	char* path = path_join(ht_temp(), c"rpc.sock")
	int listener = socket_listen_unix_path(path, 2)
	ht_require(listener >= 0, c"cannot listen for RPC fixture")
	int pid = fork()
	ht_require(pid >= 0, c"cannot fork RPC fixture")
	if (pid == 0):
		ht_scratch = 0
		ht_children = 0
		ht_on_cleanup = 0
		close(listener)
		if (scenario != 0): process_redirect_null(2, 1)
		json_value* result = vm_rpc(path, c"echo", vj_one(c"text", c"spaces and quotes \""))
		ht_require(strcmp(ht_text(result, c"ok"), c"yes") == 0, c"RPC payload changed")
		exit(0)
	int client = socket_accept_connection(listener)
	ht_require(client >= 0, c"cannot accept fixture client")
	wstream* input = stream_reader(client)
	string_builder* request = string_new()
	ht_require(frame_read(input, request), c"malformed request framing")
	json_value* object = json_parse(request.data)
	ht_require(strcmp(ht_text(object, c"method"), c"echo") == 0 && strcmp(ht_text(ht_field(object, c"params"), c"text"), c"spaces and quotes \"") == 0, c"RPC request changed")
	char* body = c"{\"jsonrpc\":\"2.0\",\"id\":31,\"result\":{\"ok\":\"yes\"}}"
	if (scenario == 3): body = c"{\"jsonrpc\":\"2.0\",\"id\":99,\"result\":{\"ok\":\"yes\"}}"
	char* frame = strjoin(strjoin(c"Content-Length: ", itoa(strlen(body))), strjoin(c"\r\n\r\n", body))
	if (scenario == 1): frame = c"Content-Length: 999999\r\n\r\n"
	if (scenario == 2): frame = c"Content-Length: 10\r\n\r\n{"
	vm_send(client, frame, strlen(frame))
	close(client)
	close(listener)
	int status = 0
	ht_require(wait4(pid, &status, 0, 0) == pid, c"cannot reap RPC fixture")
	if (scenario == 0): ht_require(process_decode_status(status) == 0, c"valid RPC rejected")
	else: ht_require(process_decode_status(status) != 0, c"invalid RPC accepted")

void he_identity():
	char* original = ht_resolve(c".")
	char* work = ht_temp()
	ht_checked(ht_argv(c"git", c"init", c"-q", work))
	ht_write(path_join(work, c"a"), c"one", 3)
	ht_write(path_join(work, c"b"), c"two", 3)
	ht_require(chmod(path_join(work, c"b"), 493) == 0 && symlink(c"a", path_join(work, c"c")) == 0, c"cannot create identity fixtures")
	ht_checked(ht_argv(c"git", c"-C", work, c"add", c"a"))
	ht_checked(ht_argv(c"git", c"-C", work, c"-c", c"user.name=Identity Test", c"-c", c"user.email=test@example.invalid", c"commit", c"-qm", c"fixture"))
	ht_require(chdir(work) == 0, c"cannot enter identity fixture")
	json_value* identity = source_identity()
	ht_require(chdir(original) == 0, c"cannot restore repository directory")
	char* bytes = c"a\x00file\x003\x00oneb\x00executable\x003\x00twoc\x00symlink\x001\x00a"
	# Explicit byte count includes internal NULs and excludes the C terminator.
	ht_require(ht_number(identity, c"files") == 3 && strcmp(ht_text(identity, c"tree_sha256"), ht_digest(bytes, 43)) == 0, c"source identity framing differs")
	ht_require(strcmp(ht_text(identity, c"diff_head_binary_sha256"), ht_digest(c"", 0)) == 0, c"clean worktree diff hash changed")

int main():
	he_metrics()
	for i in range(4): he_rpc(i)
	he_identity()
	ht_cleanup()
	println(c"Host evidence checks OK")
	return 0
