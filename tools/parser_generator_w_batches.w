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
and the built test binary; reruns the binary once per 150-file slice
with that list swapped for the slice, and restores the full list at the
end so reruns and other tooling see it intact.

On failure it prints "batch N (files X..Y of TOTAL) FAILED" with the
line range into the full list, then reruns that batch one file per
process to name the offending file(s) directly (2026-07-28: a batch's
stack trace used to drown in the other batches' banners).
*/
import lib.lib
import lib.file
import lib.process
import lib.stream
import structures.string


char* pgb_slice
char* pgb_full
char* pgb_failed
char* pgb_binary


void pgb_say(char* text):
	wstream* err = stderr_writer()
	stream_write_cstr(err, c"parser_generator_w_batches: ")
	stream_write_line(err, text)
	stream_flush(err)


void pgb_write(char* path, char* text):
	if (file_write_text(path, text) == 0):
		pgb_say(c"cannot write a batch list")
		exit(1)


# Writes lines[start..end) to the slice list, one per line.
void pgb_write_slice(list[char*] lines, int start, int end):
	string_builder* s = string_new()
	int i = start
	while (i < end):
		string_append(s, lines[i])
		string_append_char(s, '\n')
		i = i + 1
	pgb_write(pgb_slice, s.data)
	string_free(s)


# Runs the test binary over the current slice; 1 when it passed.
# quiet discards its output (the one-file-per-process culprit hunt).
int pgb_run(int quiet):
	spawn_options* opts = spawn_options_new()
	if (quiet):
		opts.stdout_mode = process_null()
		opts.stderr_mode = process_null()
	char** argv = strv_new(1)
	strv_set(argv, 0, pgb_binary)
	process* p = process_spawn(pgb_binary, argv, opts)
	free(cast(void*, argv))
	free(opts)
	if (p == 0):
		pgb_say(c"cannot spawn bin/parser_generator_w_test")
		return 0
	return process_wait(p) == 0


int main(int argc, int argv):
	pgb_slice = c"bin/parser_generator_w_files.txt"
	pgb_full = c"bin/parser_generator_w_full_list.txt"
	pgb_failed = c"bin/parser_generator_w_failed_batch.txt"
	pgb_binary = c"bin/parser_generator_w_test"
	int batch = 150
	char* text = file_read_text(pgb_slice)
	if (text == 0):
		pgb_say(c"cannot read bin/parser_generator_w_files.txt")
		return 1
	# The manifest step wrote the full list to the canonical path; keep
	# a copy aside so slices can take its place.
	pgb_write(pgb_full, text)
	list[char*] lines = new list[char*]
	string_builder* line = string_new()
	int i = 0
	while (text[i] != 0):
		if (text[i] == '\n'):
			if (line.length > 0):
				lines.push(strclone(line.data))
			string_clear(line)
		else:
			string_append_char(line, text[i])
		i = i + 1
	if (line.length > 0):
		lines.push(strclone(line.data))
	string_free(line)

	int total = lines.length
	int start = 0
	int number = 1
	while (start < total):
		int end = start + batch
		if (end > total):
			end = total
		pgb_write_slice(lines, start, end)
		if (pgb_run(0) == 0):
			string_builder* s = string_new()
			string_append(s, c"batch ")
			string_append_int(s, number)
			string_append(s, c" (files ")
			string_append_int(s, start + 1)
			string_append(s, c"..")
			string_append_int(s, end)
			string_append(s, c" of ")
			string_append_int(s, total)
			string_append(s, c") FAILED")
			pgb_say(s.data)
			string_free(s)
			# Isolate the culprit: a parse failure is per-file, so the
			# file that fails alone is the one that failed the batch.
			char* batch_text = file_read_text(pgb_slice)
			pgb_write(pgb_failed, batch_text)
			int culprits = 0
			int f = start
			while (f < end):
				pgb_write_slice(lines, f, f + 1)
				if (pgb_run(1) == 0):
					string_builder* c = string_new()
					string_append(c, c"offending file: ")
					string_append(c, lines[f])
					pgb_say(c.data)
					string_free(c)
					culprits = culprits + 1
				f = f + 1
			if (culprits == 0):
				pgb_say(c"no single file of the batch fails alone (batch list kept in bin/parser_generator_w_failed_batch.txt)")
			pgb_write(pgb_slice, text)
			return 1
		start = end
		number = number + 1
	pgb_write(pgb_slice, text)
	return 0
