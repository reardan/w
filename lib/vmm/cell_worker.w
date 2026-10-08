# Worker side of the daemon cell protocol. Each command acquires the same
# ready template afresh; guest modifications never leak to the next command.
import lib.vmm.scheduler
import lib.vmm.pool


char* vms_cell_hex(char* data, int length):
	char* value = cast(char*, malloc(length * 2 + 1))
	char* digits = c"0123456789abcdef"
	for i in range(length):
		int ch = cast(int, data[i]) & 255
		value[i * 2] = digits[ch >> 4]
		value[i * 2 + 1] = digits[ch & 15]
	value[length * 2] = 0
	return value


void vms_cell_worker(json_value* config):
	cell_pool* pool = cell_pool_new(vms_worker_snapshot, 1)
	json_value* ready = json_object()
	int status = 125
	if (pool != 0): status = 0
	json_object_set(ready, c"status", json_int(status))
	jsonrpc_write_value(1, ready)
	json_free(ready)
	if (pool == 0): return
	frame_reader* reader = frame_reader_new(0)
	while (1):
		json_value* request = jsonrpc_read_message(reader)
		if (request == 0): break
		vm_cell* cell = cell_pool_acquire(pool)
		if (cell == 0):
			json_free(request)
			break
		json_value* args = vms_field(request, c"argv")
		int count = json_array_length(args)
		char** argv = strv_new(count)
		for i in range(count): strv_set(argv, i, json_array_get(args, i).string_value)
		char* input = vms_text(request, c"stdin")
		cell.input = input
		cell.input_length = 0
		if (input != 0): cell.input_length = strlen(input)
		int configured = 1
		if (vms_field(config, c"seed") != 0): configured = cell_deterministic_configure(cell, vms_number(config, c"seed", 0))
		if (vms_worker_region != 0): configured = cell_region_bind(cell, vms_worker_region, vms_number(config, c"region_write", 0))
		if (configured && cell_stack(cell, count, argv)): cell_run(cell, vms_number(request, c"timeout_ms", 30000))
		free(cast(void*, argv))
		status = cell.status
		int limit = vms_number(request, c"output_limit", 65536)
		if (cell.output.length > limit || cell.errors.length > limit): status = 125
		json_value* answer = json_object()
		int output_length = cell.output.length
		int error_length = cell.errors.length
		if (output_length > limit): output_length = limit
		if (error_length > limit): error_length = limit
		char* output = vms_cell_hex(cell.output.data, output_length)
		char* errors = vms_cell_hex(cell.errors.data, error_length)
		json_object_set(answer, c"stdout_hex", json_string(output))
		json_object_set(answer, c"stderr_hex", json_string(errors))
		free(output)
		free(errors)
		if (cell_pool_release(pool, cell) == 0): status = -1
		json_object_set(answer, c"status", json_int(status))
		int sent = jsonrpc_write_value(1, answer)
		json_free(answer)
		json_free(request)
		if (sent < 0 || status < 0): break
	frame_reader_free(reader)
	cell_pool_free(pool)
