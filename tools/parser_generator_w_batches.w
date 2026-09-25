/*
Run bin/parser_generator_w_test over every tracked .w file in batches
of one process each (parser_generator_w_test's last step; this replaced
tools/parser_generator_w_batches.sh, issue #323).

The binary's manifest test retains the AST of every file it parses; one
process over the whole repo blows the 32-bit address-space ceiling once
tracked source passes a few MB, and freeing per file instead crawls the
first-fit allocator quadratically (2026-07-12,
docs/projects/ai_tooling_next_steps.md). Restarting the process per
batch bounds memory at batch size forever, whatever the repo grows to.

Expects bin/parser_generator_w_files.txt (the full git ls-files list)
and the built test binary. Each 40-file slice gets its own list file
(bin/parser_generator_w_batch_N.txt), handed to the binary through
PARSER_GENERATOR_W_FILES, so up to one batch per online CPU runs at
once (2026-09-25: the serial 150-file loop took ~22 s; batch cost is
uneven, so small batches keep the workers balanced). The canonical
full list is never rewritten. Passing batches run with their output
discarded (it is only per-test banners).

On failure it reruns the failing batch alone with its output shown,
prints "batch N (files X..Y of TOTAL) FAILED" with the line range into
the full list, keeps that batch's list in
bin/parser_generator_w_failed_batch.txt, then reruns it one file per
process (in parallel, reported in list order) to name the offending
file(s) directly (2026-07-28: a batch's stack trace used to drown in
the other batches' banners).
*/

import lib.lib
import lib.env
import lib.file
import lib.process
import lib.stream
import structures.string


char* pgb_failed
char* pgb_binary
int pgb_jobs


void pgb_say(char* text):
	wstream* err = stderr_writer()
	stream_write_cstr(err, c"parser_generator_w_batches: ")
	stream_write_line(err, text)
	stream_flush(err)


void pgb_write(char* path, char* text):
	if (file_write_text(path, text) == 0):
		pgb_say(c"cannot write a batch list")
		exit(1)


# Writes lines[start..end) to path, one per line.
void pgb_write_slice(char* path, list[char*] lines, int start, int end):
	string_builder* s = string_new()
	for i in range(start, end):
		string_append(s, lines[i])
		string_append_char(s, '\n')
	pgb_write(path, s.data)
	string_free(s)


# Malloc'd "bin/parser_generator_w_<kind>_<n>.txt".
char* pgb_list_path(char* kind, int n):
	string_builder* s = string_new()
	string_append(s, c"bin/parser_generator_w_")
	string_append(s, kind)
	string_append_char(s, '_')
	string_append_int(s, n)
	string_append(s, c".txt")
	char* path = strclone(s.data)
	string_free(s)
	return path


# Online CPU count from /proc/cpuinfo (tools/wexec.w's
# wexec_default_jobs); 1 when it cannot be read.
int pgb_cpu_count():
	char* text = file_read_text(c"/proc/cpuinfo")
	if (text == 0):
		return 1
	int count = 0
	int line_start = 1
	int i = 0
	while (text[i] != 0):
		if (line_start):
			if (starts_with(text + i, c"processor")):
				count = count + 1
		line_start = text[i] == 10
		i = i + 1
	free(text)
	if (count < 1):
		return 1
	return count


# Starts the test binary over the list at list_path; 0 when it cannot
# be spawned. quiet discards its output.
process* pgb_start(char* list_path, int quiet):
	spawn_options* opts = spawn_options_new()
	if (quiet):
		opts.stdout_mode = process_null()
		opts.stderr_mode = process_null()
	opts.env = env_copy_with(env_current(), c"PARSER_GENERATOR_W_FILES", list_path)
	char** argv = strv_new(1)
	strv_set(argv, 0, pgb_binary)
	process* p = process_spawn(pgb_binary, argv, opts)
	free(cast(void*, argv))
	free(cast(void*, opts.env))
	free(opts)
	if (p == 0):
		pgb_say(c"cannot spawn bin/parser_generator_w_test")
	return p


# Runs the binary once over the list at list_path, output shown; 1
# when it passed.
int pgb_run_one(char* list_path):
	process* p = pgb_start(list_path, 0)
	if (p == 0):
		return 0
	int ok = process_wait(p) == 0
	process_free(p)
	return ok


# Runs the binary quietly over every list in paths, at most pgb_jobs at
# a time; ok[i] is 1 when paths[i] passed. Returns the failure count.
int pgb_run_all(list[char*] paths, list[int] ok):
	list[process*] kids = new list[process*]
	list[int] owner = new list[int]
	int next = 0
	int running = 0
	int failures = 0
	int i = 0
	while (i < paths.length):
		ok.push(0)
		i = i + 1
	while ((next < paths.length) || (running > 0)):
		while ((next < paths.length) && (running < pgb_jobs)):
			process* p = pgb_start(paths[next], 1)
			if (p == 0):
				failures = failures + 1
			else:
				kids.push(p)
				owner.push(next)
				running = running + 1
			next = next + 1
		if (running > 0):
			int k = process_wait_any(kids, 1)
			if (k < 0):
				pgb_say(c"waiting for a batch failed")
				exit(1)
			running = running - 1
			if (process_decode_status(kids[k].status) == 0):
				ok[owner[k]] = 1
			else:
				failures = failures + 1
	i = 0
	while (i < kids.length):
		process_free(kids[i])
		i = i + 1
	return failures


void pgb_remove_all(list[char*] paths):
	int i = 0
	while (i < paths.length):
		unlink(paths[i])
		i = i + 1


int main(int argc, int argv):
	pgb_failed = c"bin/parser_generator_w_failed_batch.txt"
	pgb_binary = c"bin/parser_generator_w_test"
	pgb_jobs = pgb_cpu_count()
	int batch = 40
	list[char*] lines = file_read_lines(c"bin/parser_generator_w_files.txt")
	if (lines == 0):
		pgb_say(c"cannot read bin/parser_generator_w_files.txt")
		return 1
	# Drop blank lines (a trailing newline, stray empties).
	list[char*] kept = new list[char*]
	int i = 0
	while (i < lines.length):
		if (lines[i][0] != 0):
			kept.push(lines[i])
		i = i + 1
	lines = kept

	int total = lines.length
	list[char*] paths = new list[char*]
	list[int] starts = new list[int]
	int start = 0
	while (start < total):
		int end = start + batch
		if (end > total):
			end = total
		char* path = pgb_list_path(c"batch", paths.length + 1)
		pgb_write_slice(path, lines, start, end)
		paths.push(path)
		starts.push(start)
		start = end
	list[int] ok = new list[int]
	pgb_run_all(paths, ok)
	int status = 0
	int b = 0
	while (b < paths.length):
		if (ok[b] == 0):
			status = 1
			start = starts[b]
			int end = start + batch
			if (end > total):
				end = total
			# Rerun alone, output shown, for the batch's stack trace.
			if (pgb_run_one(paths[b])):
				pgb_say(c"(the failing batch passed when rerun alone)")
			string_builder* s = string_new()
			string_append(s, c"batch ")
			string_append_int(s, b + 1)
			string_append(s, c" (files ")
			string_append_int(s, start + 1)
			string_append(s, c"..")
			string_append_int(s, end)
			string_append(s, c" of ")
			string_append_int(s, total)
			string_append(s, c") FAILED")
			pgb_say(s.data)
			string_free(s)
			char* batch_text = file_read_text(paths[b])
			pgb_write(pgb_failed, batch_text)
			free(batch_text)
			# Isolate the culprit: a parse failure is per-file, so the
			# file that fails alone is the one that failed the batch.
			list[char*] singles = new list[char*]
			int f = start
			while (f < end):
				char* single = pgb_list_path(c"single", f + 1)
				pgb_write_slice(single, lines, f, f + 1)
				singles.push(single)
				f = f + 1
			list[int] single_ok = new list[int]
			int culprits = pgb_run_all(singles, single_ok)
			f = 0
			while (f < singles.length):
				if (single_ok[f] == 0):
					string_builder* c = string_new()
					string_append(c, c"offending file: ")
					string_append(c, lines[start + f])
					pgb_say(c.data)
					string_free(c)
				f = f + 1
			pgb_remove_all(singles)
			if (culprits == 0):
				pgb_say(c"no single file of the batch fails alone (batch list kept in bin/parser_generator_w_failed_batch.txt)")
		b = b + 1
	pgb_remove_all(paths)
	return status
