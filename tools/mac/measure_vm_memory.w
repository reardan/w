# wbuild: binary=measure_vm_memory arch=x64 tag=tests
# Native HV CoW versus full-copy evidence; process counters are not unique RAM.
import tools.mac.vm_harness
import tools.mac.vm_evidence

float mm_median(list[int] values):
	values.sort()
	int n = values.length
	ht_require(n > 0, c"missing memory samples")
	if (n % 2): return cast(float, values[n / 2])
	return (cast(float, values[n / 2 - 1]) + cast(float, values[n / 2])) / 2.0

int main(int argc, int argv):
	arg_parser* parser = argparse_new(c"measure_vm_memory")
	argparse_add_positional(parser, c"binary", c"signed native memory fixture")
	argparse_arg_default(argparse_add_int(parser, c"--samples", c"N", c"samples per scenario"), c"5")
	argparse_arg_required(argparse_add_option(parser, c"--output", c"FILE", c"evidence JSON"))
	arg_namespace* args = argparse_parse_or_exit(parser, argc, argv)
	int samples = argparse_get_int(args, c"samples")
	ht_require(samples > 0, c"--samples must be positive")
	vm_native()
	char* binary = ht_resolve(argparse_get(args, c"binary"))
	json_value* report = vm_memory_base()
	json_value* host = ht_field(report, c"host")
	vj_s(host, c"os", vm_command(c"sw_vers"))
	vj_s(host, c"machine", vm_command(c"uname -m"))
	vj_s(host, c"model", vm_command(c"sysctl -n hw.model"))
	vj_s(host, c"chip", vm_command(c"sysctl -n machdep.cpu.brand_string"))
	vj_i(host, c"ram_bytes", atoi(vm_command(c"sysctl -n hw.memsize")))
	vj_s(host, c"sdk", vm_command(c"xcrun --show-sdk-version"))
	vj_s(report, c"source_revision", vm_command(c"git rev-parse HEAD"))
	vj_s(report, c"worktree_status", vm_command(c"git status --short"))
	vj_s(report, c"binary_sha256", vsi_digest(binary))
	vj_i(ht_field(report, c"conditions"), c"sample_count_per_scenario", samples)
	json_value* runs = ht_field(report, c"runs")
	for sample in range(samples):
		list[char*] modes = ht_command(c"cow copy")
		if (sample % 2): modes = ht_command(c"copy cow")
		for clones in range(1, 3):
			for char* dirty in ht_command(c"0 256 1024"):
				for char* mode in modes:
					int start = vm_ns()
					process_result* result = ht_run(ht_argv(binary, mode, dirty, itoa(clones)), 0, 0, 20000)
					ht_success(result)
					json_value* records = json_array()
					int owners = 0
					int workers = 0
					int backings = 0
					int owner_rss = 0
					int owner_footprint = 0
					int worker_rss = 0
					int worker_footprint = 0
					int backing = 0
					for char* line in ht_split(result.stdout_text, 10):
						if (line[0] == 0): continue
						json_value* row = json_parse(line)
						char* phase = ht_text(row, c"phase")
						json_array_push(records, row)
						if (strcmp(phase, c"template-owner") == 0):
							owners = owners + 1
							owner_rss = ht_number(row, c"resident_bytes")
							owner_footprint = ht_number(row, c"footprint_bytes")
						if (strcmp(phase, c"after-guest-writes") == 0):
							workers = workers + 1
							worker_rss = worker_rss + ht_number(row, c"resident_bytes")
							worker_footprint = worker_footprint + ht_number(row, c"footprint_bytes")
						if (strcmp(phase, c"backing-file") == 0):
							backings = backings + 1
							backing = ht_number(row, c"allocated_bytes")
					ht_require(owners == 2 && workers == clones && backings == 1, c"Incomplete mandatory memory sample")
					json_value* run = vj_one(c"mode", mode)
					vj_i(run, c"sample", sample)
					vj_i(run, c"clones", clones)
					vj_i(run, c"dirty_pages", atoi(dirty))
					vj_f(run, c"dirty_fraction", cast(float, atoi(dirty)) / 1024.0)
					vj_f(run, c"elapsed_ms", cast(float, vm_ns() - start) / 1000000.0)
					vj_i(run, c"summed_process_rss_bytes", owner_rss + worker_rss)
					vj_i(run, c"summed_process_footprint_bytes", owner_footprint + worker_footprint)
					vj_i(run, c"backing_allocated_bytes", backing)
					json_object_set(run, c"records", records)
					json_array_push(runs, run)
	json_value* summary = ht_field(report, c"summary")
	for clones in range(1, 3):
		for char* dirty in ht_command(c"0 256 1024"):
			for char* mode in ht_command(c"cow copy"):
				list[int] rss = new list[int]
				list[int] footprint = new list[int]
				int backing = 0
				for json_value* row in runs.array_values:
					if (ht_number(row, c"clones") != clones || ht_number(row, c"dirty_pages") != atoi(dirty) || strcmp(ht_text(row, c"mode"), mode) != 0): continue
					if (rss.length == 0): backing = ht_number(row, c"backing_allocated_bytes")
					rss.push(ht_number(row, c"summed_process_rss_bytes"))
					footprint.push(ht_number(row, c"summed_process_footprint_bytes"))
				json_value* row = vj_one(c"mode", mode)
				vj_i(row, c"clones", clones)
				vj_f(row, c"dirty_fraction", cast(float, atoi(dirty)) / 1024.0)
				vj_i(row, c"samples", rss.length)
				vj_f(row, c"median_summed_process_rss_bytes", mm_median(rss))
				vj_f(row, c"median_summed_process_footprint_bytes", mm_median(footprint))
				vj_i(row, c"backing_allocated_bytes", backing)
				json_array_push(summary, row)
	vj_write(argparse_get(args, c"output"), report)
	println(json_stringify(summary))
	println(strjoin(c"Memory evidence: ", argparse_get(args, c"output")))
	return 0
