# Native Darwin daemon entry; the executable never owns a live HV VM.
import tools.wvm_darwin
import lib.vmm.darwin_control
import lib.wvm_client


int dvm_daemon_main(int argc, char** args):
	if (argc >= 4 && strcmp(args[1], c"call") == 0):
		json_value* params = json_object()
		if (argc == 5):
			json_free(params)
			params = json_parse(args[4])
		if (params == 0): return 2
		json_value* response = wvm_client_call(args[2], args[3], params, 15000)
		json_free(params)
		if (response == 0): return 125
		char* text = json_stringify(response)
		println(text)
		free(text)
		json_free(response)
		return 0
	if (argc < 2 || strcmp(args[1], c"serve") != 0):
		println(c"usage: wvmd serve [--socket PATH] [--worker PATH] [--max-active N] [--max-pending N] [--memory-mb N]")
		println(c"       wvmd call SOCKET METHOD [JSON_PARAMS]")
		return 2
	char* path = c"bin/wvmd-darwin.sock"
	char* executable = c"bin/wvm_darwin"
	int active = 4
	int pending = 16
	int memory = 4096
	int at = 2
	while (at + 1 < argc):
		char* option = args[at]
		char* value = args[at + 1]
		at = at + 2
		if (strcmp(option, c"--socket") == 0): path = value
		else if (strcmp(option, c"--worker") == 0): executable = value
		else if (strcmp(option, c"--max-active") == 0): active = dvm_positive(value)
		else if (strcmp(option, c"--max-pending") == 0): pending = dvm_positive(value)
		else if (strcmp(option, c"--memory-mb") == 0): memory = dvm_positive(value)
		else:
			dvm_cli_error(c"unsupported daemon option: Darwin has admission limits, not cgroup quotas")
			return 2
	if (at != argc || active < 1 || active > 32 || pending < 0 || pending > 32 || memory < 256 || memory > 32768): return 2
	dvm_daemon daemon
	mem_fill[char](cast(char*, &daemon), 0, sizeof(dvm_daemon))
	daemon.sessions = new list[dvm_session*]
	daemon.templates = new list[dvm_template*]
	daemon.next_session = 1
	daemon.next_template = 1
	daemon.max_active = active
	daemon.max_pending = pending
	daemon.max_memory_mb = memory
	daemon.executable = executable
	daemon.running = 1
	int status = dvm_serve(&daemon, path)
	for dvm_session* session in daemon.sessions:
		if (session != 0): dvm_destroy(&daemon, session)
	for dvm_template* template in daemon.templates:
		if (template != 0): dvm_template_destroy(&daemon, template)
	list_free[dvm_session*](daemon.sessions)
	list_free[dvm_template*](daemon.templates)
	return status
