# wbuild: binary=storage_bench arch=x64 tag=tests
# Repeatable native LSM baseline, with independent process rusage and disk counters.
import tools.host_metrics
import libs.standard.cli.argparse
import libs.standard.fs.glob

char* sb_binary
int sb_count
int sb_each
int sb_darwin

int sb_size(char* prefix):
	int total = 0
	for char* path in glob_glob(strjoin(prefix, c".*")):
		file_stat st
		if (file_stat_path(path, &st) == 0): total = total + st.size
	return total

struct sb_job:
	hm_sample* sample
	char* mode
	char* prefix
	char* label
	int before

sb_job* sb_start(char* mode, char* prefix, char* label):
	sb_job* job = new sb_job
	job.mode = mode
	job.prefix = prefix
	job.label = label
	job.before = sb_size(prefix)
	job.sample = hm_start(ht_argv(sb_binary, mode, prefix, itoa(sb_count), itoa(sb_each)))
	return job

json_value* sb_finish(sb_job* job):
	hm_finish(job.sample, 300000)
	ht_require(job.sample.status == 0 && !job.sample.timed_out, ht_read(job.sample.stderr_path).data)
	json_value* result = hm_metrics(job.sample, sb_darwin)
	list[int] samples = new list[int]
	for char* line in ht_split(ht_read(job.sample.stdout_path).data, 10):
		if (line[0] == 0): continue
		list[char*] fields = split(line)
		ht_require(fields.length == 2, c"invalid storage probe output")
		int value = atoi(fields[1])
		if (strcmp(fields[0], c"latency_us") == 0): samples.push(value)
		else: json_object_set(result, fields[0], json_int(value))
	samples.sort()
	json_object_set(result, c"phase", json_string(job.label))
	json_object_set(result, c"operations", json_int(samples.length))
	json_object_set(result, c"throughput_ops_s", json_float(cast(float, samples.length) / hm_elapsed(job.sample)))
	for char* percentile in ht_command(c"50 95 99"):
		json_value* value = json_null()
		if (samples.length > 0): value = json_int(samples[(samples.length * atoi(percentile) + 99) / 100 - 1])
		json_object_set(result, strjoin(strjoin(c"latency_p", percentile), c"_us"), value)
	int after = sb_size(job.prefix)
	json_object_set(result, c"disk_bytes", json_int(after))
	json_object_set(result, c"disk_growth_bytes", json_int(after - job.before))
	json_value* amplification = json_null()
	if (strcmp(job.mode, c"write") == 0):
		json_value* written = json_object_get(result, c"write_bytes")
		int size = 0
		if (written != 0): size = written.int_value
		amplification = json_float(cast(float, size) / cast(float, sb_count * 32))
	json_object_set(result, c"write_amplification", amplification)
	return result

int main(int argc, int argv):
	arg_parser* parser = argparse_new(c"storage_bench")
	argparse_arg_default(argparse_add_option(parser, c"--binary", c"FILE", c"storage probe"), c"bin/storage_probe")
	argparse_arg_default(argparse_add_int(parser, c"--count", c"N", c"operations"), c"1000")
	arg_spec* durability = argparse_add_option(parser, c"--durability", c"MODE", c"sync frequency")
	argparse_arg_default(durability, c"each")
	argparse_arg_choices(durability, c"each,end")
	argparse_add_option(parser, c"--output", c"FILE", c"JSON report")
	arg_namespace* args = argparse_parse_or_exit(parser, argc, argv)
	sb_count = argparse_get_int(args, c"count")
	ht_require(sb_count >= 1 && sb_count <= 100000, c"count must be 1..100000")
	sb_each = strcmp(argparse_get(args, c"durability"), c"each") == 0
	sb_binary = ht_resolve(argparse_get(args, c"binary"))
	sb_darwin = contains(ht_checked(ht_command(c"uname -s")).stdout_text, c"Darwin")
	char* work = ht_temp()
	char* prefix = path_join(work, c"store")
	json_value* results = json_array()
	json_array_push(results, sb_finish(sb_start(c"write", prefix, c"initial_load")))
	json_array_push(results, sb_finish(sb_start(c"compact", prefix, c"compact")))
	int evicted = !sb_darwin
	if (evicted):
		for char* path in glob_glob(strjoin(prefix, c".*")):
			int fd = open(path, 0, 0)
			# Linux x86-64 fadvise64(fd, 0, 0, POSIX_FADV_DONTNEED).
			if (fd < 0): evicted = 0
			else:
				if (syscall7(221, fd, 0, 0, 4, 0, 0) < 0): evicted = 0
				close(fd)
	list[char*] modes = ht_command(c"read read scan checksum decode write recover")
	list[char*] labels = ht_command(c"cold_requested_read warm_read scan checksum_32k table_index_decode sustained_update recover")
	for i in range(modes.length): json_array_push(results, sb_finish(sb_start(modes[i], prefix, labels[i])))
	char* other = path_join(work, c"other")
	json_array_push(results, sb_finish(sb_start(c"write", other, c"second_store_load")))
	sb_job* reader = sb_start(c"read", prefix, c"concurrent_read")
	sb_job* writer = sb_start(c"write", other, c"concurrent_update")
	int deadline = process_monotonic_ms() + 300000
	while (1):
		int read_done = hm_poll(reader.sample)
		int write_done = hm_poll(writer.sample)
		if (read_done && write_done): break
		ht_require(process_monotonic_ms() < deadline, c"concurrent storage workload timed out")
		process_sleep_ms(1)
	json_array_push(results, sb_finish(reader))
	json_array_push(results, sb_finish(writer))
	json_value* report = json_object()
	json_object_set(report, c"count", json_int(sb_count))
	json_object_set(report, c"durability", json_string(argparse_get(args, c"durability")))
	json_object_set(report, c"cold_cache_eviction_requested", json_bool(evicted))
	json_object_set(report, c"results", results)
	json_value* notes = json_array()
	for char* note in ht_split(c"Latency samples exclude stdout formatting; throughput includes process startup and reporting.|Peak RSS is per child from wait4; allocated_bytes is cumulative, not live heap.|write_amplification counts bytes passed to successful file writes, not physical device writes.|Queue bytes are zero for this synchronous driver; executor tests qualify bounded queues.|Cold means POSIX_FADV_DONTNEED requested, not guaranteed cold hardware.|No page cache, buffer reuse or checksum algorithm optimization is enabled.", '|'): json_array_push(notes, json_string(note))
	json_object_set(report, c"notes", notes)
	char* encoded = json_stringify(report)
	char* output = argparse_get(args, c"output")
	if (output != 0): ht_write(output, encoded, strlen(encoded))
	println(encoded)
	ht_cleanup()
	return 0
