/*
wcoverage changed: the new-code rule (docs/projects/line_coverage.md,
"Compiler coverage"). Checks the executable lines a change adds or
edits against a merged coverage result.

Usage: wcoverage changed [--min <percent>] [--prefix <p>]... <diff> <lcov.info>

<diff> is 'git diff -U0 <base>...HEAD' output; <lcov.info> is the
tracefile 'wcoverage suite' writes. A changed line counts when the
tracefile has a DA record for it (blank lines, comments and headers have
none) and its path starts with a --prefix (default compiler/, grammar/,
code_generator/). Lines inside a function whose definition line carries
'# coverage: exempt <reason>' are skipped. Prints each changed line no
run reached and exits 1 when fewer than --min percent (default 80) of
the changed executable lines ran.
*/
import lib.lib
import lib.args
import lib.file
import lib.str


void wcov_changed_fail(char* detail):
	print2(c"wcoverage changed: ")
	println2(detail)
	exit(2)


int wcov_changed_number(char* text, int* pos):
	int value = 0
	int digits = 0
	while ((text[*pos] >= '0') && (text[*pos] <= '9')):
		value = value * 10 + (text[*pos] - '0')
		*pos = *pos + 1
		digits = digits + 1
	if (digits == 0): wcov_changed_fail(c"malformed hunk header in the diff")
	return value


# "path:line" keys of every line the diff adds or edits on the new side.
set[char*] wcov_changed_lines(char* diff_path, list[char*] files):
	list[char*] lines = file_read_lines(diff_path)
	if (lines == 0): wcov_changed_fail(c"cannot read the diff")
	set[char*] changed = new set[char*]
	char* path = 0
	for char* line in lines:
		if (starts_with(line, c"+++ ")):
			path = 0
			if (starts_with(line, c"+++ b/")):
				path = strclone(line + 6)
				files.push(path)
		elif (starts_with(line, c"@@ ") && (path != 0)):
			# @@ -a[,b] +c[,d] @@: new-side lines c .. c+d-1 (d defaults to 1).
			int plus = index_of(line, c" +")
			if (plus < 0): wcov_changed_fail(c"malformed hunk header in the diff")
			int pos = plus + 2
			int start = wcov_changed_number(line, &pos)
			int count = 1
			if (line[pos] == ','):
				pos = pos + 1
				count = wcov_changed_number(line, &pos)
			for k in range(count): changed.add(f"{path}:{start + k}")
	return changed


int wcov_changed_main():
	int min = 80
	list[char*] prefixes = new list[char*]
	list[char*] positional = new list[char*]
	int i = 2
	while (i < args_count()):
		char* a = args_get(i)
		int has_next = i + 1 < args_count()
		if ((strcmp(a, c"--min") == 0) && has_next):
			i = i + 1
			min = atoi(args_get(i))
		elif ((strcmp(a, c"--prefix") == 0) && has_next):
			i = i + 1
			prefixes.push(args_get(i))
		elif (a[0] == '-'): wcov_changed_fail(c"usage: wcoverage changed [--min <percent>] [--prefix <p>]... <diff> <lcov.info>")
		else: positional.push(a)
		i = i + 1
	if (positional.length != 2): wcov_changed_fail(c"usage: wcoverage changed [--min <percent>] [--prefix <p>]... <diff> <lcov.info>")
	if (prefixes.length == 0):
		prefixes.push(c"compiler/")
		prefixes.push(c"grammar/")
		prefixes.push(c"code_generator/")
	list[char*] files = new list[char*]
	set[char*] changed = wcov_changed_lines(positional[0], files)

	list[char*] trace = file_read_lines(positional[1])
	if (trace == 0): wcov_changed_fail(c"cannot read the lcov tracefile")
	int total = 0
	int hits = 0
	list[char*] missed = new list[char*]
	char* path = 0
	int selected = 0
	list[char*] source = 0
	list[int] fn_lines = new list[int]
	for char* line in trace:
		if (starts_with(line, c"SF:")):
			path = line + 3
			selected = 0
			for char* p in prefixes:
				if (starts_with(path, p)): selected = 1
			source = 0
			fn_lines = new list[int]
			if (selected): source = file_read_lines(path)
		elif (selected && starts_with(line, c"FN:")):
			int pos = 3
			fn_lines.push(wcov_changed_number(line, &pos))
		elif (selected && starts_with(line, c"DA:")):
			int pos = 3
			int number = wcov_changed_number(line, &pos)
			if ((f"{path}:{number}" in changed) == 0): continue
			# The enclosing function: the last definition line before it.
			int header = 0
			for int fn_line in fn_lines:
				if ((fn_line <= number) && (fn_line > header)): header = fn_line
			if ((source != 0) && (header > 0) && (header <= source.length)):
				if (contains(source[header - 1], c"# coverage: exempt")): continue
			total = total + 1
			if (strcmp(line + pos, c",0") == 0): missed.push(f"{path}:{number}")
			else: hits = hits + 1
	if (total == 0):
		println(c"changed executable lines: none in the measured tree")
		return 0
	for char* m in missed: println(f"{m}: changed line not reached by any test")
	int pct = hits * 100 / total
	println(f"changed executable lines reached: {hits}/{total} ({pct}%), minimum {min}%")
	if (pct < min): return 1
	return 0
