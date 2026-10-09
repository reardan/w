# Execution coverage report for --coverage's statement counters. Kept
# separate from wcoverage's default static module-reachability report.
#
# wcoverage lines [options] <binary.wprofmap> <dump>... [<map> <dump>...]
#
# A dump is a W_PROFILE_OUT file, or a directory whose files are all
# dumps of the preceding map (compiler/coverage_exec.w writes one per
# process). Options (docs/projects/line_coverage.md):
#   --file <path>        only this source file (repeatable)
#   --prefix <p>         only paths starting with p (repeatable)
#   --uncovered-only     list only missed lines, groups or functions
#   --summary file|dir|function   a table instead of the per-line list
#   --format text|lcov|json       per-line text (default), an lcov
#                        tracefile, or one JSON object per file
#   --diagnostics        error/warning call sites and whether they ran
#   --baseline <file>    exit 1 when a prefix drops below its floor
import lib.lib
import lib.args
import lib.dir
import lib.file
import lib.path
import lib.str
import lib.stream


struct wcov_fn:
	char* path
	char* name
	int line
	int entered
	int total   # selected lines owned, counted by the function summary
	int hits


struct wcov_line:
	char* path
	int line
	int hit
	# The last statement counter on the line (in map order) ran: for
	# 'if (c): error(...)' that is the error call, not the condition.
	int tail_hit
	wcov_fn* fn


struct wcov_counter:
	wcov_line* line
	wcov_fn* fn
	int tail


void wcov_lines_fail(char* detail):
	print2(c"wcoverage lines: ")
	println2(detail)
	exit(2)


# Validate unsigned decimal without overflow. Counts can span the full
# uint64 range even when this tool is built for x86; only hit/miss matters.
int wcov_decimal_nonzero(char* text):
	if (text[0] == 0): wcov_lines_fail(c"empty decimal field")
	int nonzero = 0
	for i in range(strlen(text)):
		if ((text[i] < '0') || (text[i] > '9')): wcov_lines_fail(c"invalid decimal field")
		if (text[i] != '0'): nonzero = 1
	return nonzero


int wcov_small_decimal(char* text):
	wcov_decimal_nonzero(text)
	int value = 0
	for i in range(strlen(text)):
		int digit = text[i] - '0'
		if ((value > 214748364) || ((value == 214748364) && (digit > 7))): wcov_lines_fail(c"index or line number too large")
		value = value * 10 + digit
	return value


char* wcov_line_key(char* path, int line):
	char* digits = itoa(line)
	char* padded = strclone(c"0000000000")
	int n = strlen(digits)
	for i in range(n): padded[10 - n + i] = digits[i]
	char* prefix = strjoin(path, c":")
	char* key = strjoin(prefix, padded)
	free(prefix)
	free(padded)
	free(digits)
	return key


# Every map and dump folds into one of these.
struct wcov_state:
	map[char*, wcov_line*] lines
	map[char*, wcov_fn*] fns
	list[wcov_counter*] counters


# The function a map row belongs to, keyed by file, defhash and name so
# the x86 and x64 builds of one definition merge. line is the f record's
# definition line, or 0 from a statement row.
wcov_fn* wcov_fn_for(wcov_state* st, list[char*] fields, int line):
	char* key = f"{fields[4]}\t{fields[2]}\t{fields[3]}"
	if (key in st.fns):
		wcov_fn* existing = st.fns[key]
		free(key)
		if ((line > 0) && ((existing.line == 0) || (line < existing.line))): existing.line = line
		return existing
	wcov_fn* wf = new wcov_fn()
	wf.path = strclone(fields[4])
	wf.name = strclone(fields[3])
	wf.line = line
	wf.entered = 0
	wf.total = 0
	wf.hits = 0
	st.fns[key] = wf
	return wf


void wcov_line_map(wcov_state* st, char* path):
	list[char*] lines = file_read_lines(path)
	if ((lines == 0) || (lines.length == 0)): wcov_lines_fail(c"cannot read map")
	list[char*] header = split(lines[0], '\t')
	if (header.length != 3): wcov_lines_fail(c"invalid map header")
	if (strcmp(header[0], c"# wprofmap v1") != 0): wcov_lines_fail(c"expected wprofmap v1")
	int expected = wcov_small_decimal(header[2])
	list[wcov_counter*] counters = new list[wcov_counter*]
	map[char*, int] tails = new map[char*, int]
	int statements = 0
	for i in range(1, lines.length):
		if (lines[i][0] == 0): continue
		list[char*] fields = split(lines[i], '\t')
		if (fields.length != 7): wcov_lines_fail(c"invalid map row")
		if (wcov_small_decimal(fields[0]) != counters.length): wcov_lines_fail(c"map indices must be consecutive")
		wcov_counter* counter = new wcov_counter()
		counter.line = 0
		counter.fn = 0
		counter.tail = 0
		if (strcmp(fields[1], c"s") == 0):
			statements = statements + 1
			int line = wcov_small_decimal(fields[5])
			if (line == 0): wcov_lines_fail(c"source line must be positive")
			char* key = wcov_line_key(fields[4], line)
			wcov_line* entry = 0
			if (key in st.lines): entry = st.lines[key]
			else:
				entry = new wcov_line()
				entry.path = strclone(fields[4])
				entry.line = line
				entry.hit = 0
				entry.tail_hit = 0
				entry.fn = 0
				st.lines[key] = entry
			if (entry.fn == 0): entry.fn = wcov_fn_for(st, fields, 0)
			counter.line = entry
			tails[key] = counters.length
		elif (strcmp(fields[1], c"f") == 0):
			counter.fn = wcov_fn_for(st, fields, wcov_small_decimal(fields[5]))
		elif (strcmp(fields[1], c"l") != 0): wcov_lines_fail(c"unknown counter kind")
		counters.push(counter)
	if (counters.length != expected): wcov_lines_fail(c"map counter count mismatch")
	if (statements == 0): wcov_lines_fail(c"no statement counters; compile with --coverage")
	for char* key in tails: counters[tails[key]].tail = 1
	st.counters = counters


# One dump file, read a line at a time: a suite run writes thousands.
void wcov_line_dump(wcov_state* st, char* path):
	wstream* in = stream_open_read(path)
	if (in == 0): wcov_lines_fail(c"cannot read dump")
	string_builder* row = string_new()
	while (stream_read_line(in, row)):
		char* text = row.data
		if (text[0] == 0): continue
		int space = -1
		for i in range(row.length):
			if ((text[i] == ' ') || (text[i] == '\t')):
				if (space >= 0): wcov_lines_fail(c"invalid dump row")
				space = i
		if ((space <= 0) || (space == row.length - 1)): wcov_lines_fail(c"invalid dump row")
		text[space] = 0
		int index = wcov_small_decimal(text)
		if (index >= st.counters.length): wcov_lines_fail(c"dump index outside map")
		if (wcov_decimal_nonzero(text + space + 1)):
			wcov_counter* counter = st.counters[index]
			if (counter.line != 0):
				counter.line.hit = 1
				if (counter.tail): counter.line.tail_hit = 1
				counter.line.fn.entered = 1
			if (counter.fn != 0): counter.fn.entered = 1
	string_free(row)
	stream_close(in)


# A dump argument: a file, or a directory of dump files.
void wcov_dump_arg(wcov_state* st, char* path):
	list[char*] names = dir_names(path)
	if (names == 0):
		wcov_line_dump(st, path)
		return
	for char* name in names:
		char* child = path_join(path, name)
		wcov_line_dump(st, child)
		free(child)


# "96.2%": hits/total to one decimal, rounded down.
char* wcov_pct(int hits, int total):
	if (total == 0): return strclone(c"-")
	int tenths = hits * 1000 / total
	return f"{tenths / 10}.{tenths % 10}%"


struct wcov_group:
	char* name
	int total
	int hits


wcov_group* wcov_group_for(map[char*, wcov_group*] groups, char* name):
	if (name in groups): return groups[name]
	wcov_group* g = new wcov_group()
	g.name = strclone(name)
	g.total = 0
	g.hits = 0
	groups[g.name] = g
	return g


# The top-level directory of a repo-relative path ("grammar/"), or "./".
char* wcov_top_dir(char* path):
	for i in range(strlen(path)):
		if (path[i] == '/'): return substring(path, 0, i + 1)
	return strclone(c"./")


void wcov_print_total(char* what, int hits, int total):
	print(what)
	print(c": ")
	print(itoa(hits))
	print(c"/")
	print(itoa(total))
	print(c" (")
	print(itoa(hits * 100 / total))
	println(c"%)")


# "  96.2%   1234/1282   name"
void wcov_print_row(int hits, int total, char* name):
	char* pct = wcov_pct(hits, total)
	println(f"{pct:>7}  {hits:>6}/{total:<6}  {name}")
	free(pct)


struct wcov_options:
	set[char*] files
	list[char*] prefixes
	int uncovered_only
	char* summary
	char* format
	int diagnostics
	char* baseline


int wcov_selected(wcov_options* opt, char* path):
	if ((opt.files.length > 0) && ((path in opt.files) == 0)): return 0
	if (opt.prefixes.length == 0): return 1
	for char* prefix in opt.prefixes:
		if (starts_with(path, prefix)): return 1
	return 0


void wcov_json_string(char* text):
	string_builder* out = string_new()
	string_append(out, c"\"")
	for i in range(strlen(text)):
		int c = text[i]
		if ((c == '"') || (c == 92)):
			string_append_char(out, 92)
			string_append_char(out, c)
		elif (c == 9): string_append(out, c"\\t")
		else: string_append_char(out, c)
	string_append(out, c"\"")
	print(out.data)
	string_free(out)


int wcov_fn_less(wcov_fn* a, wcov_fn* b):
	int c = strcmp(a.path, b.path)
	if (c != 0): return c < 0
	if (a.line != b.line): return a.line < b.line
	return strcmp(a.name, b.name) < 0


# The selected functions with a definition line, in file/line order
# (a bottom-up merge sort: a compiler-sized closure has thousands).
list[wcov_fn*] wcov_sorted_fns(wcov_state* st, wcov_options* opt):
	list[wcov_fn*] fns = new list[wcov_fn*]
	for char* key in st.fns:
		wcov_fn* wf = st.fns[key]
		if (wf.line == 0): continue
		if (wcov_selected(opt, wf.path)): fns.push(wf)
	list[wcov_fn*] tmp = new list[wcov_fn*]
	for i in range(fns.length): tmp.push(fns[i])
	int width = 1
	while (width < fns.length):
		int lo = 0
		while (lo < fns.length):
			int mid = lo + width
			int hi = lo + 2 * width
			if (mid > fns.length): mid = fns.length
			if (hi > fns.length): hi = fns.length
			int a = lo
			int b = mid
			int out = lo
			while (out < hi):
				int take_a = 0
				if (b >= hi): take_a = 1
				elif (a < mid):
					if (wcov_fn_less(fns[b], fns[a]) == 0): take_a = 1
				if (take_a):
					tmp[out] = fns[a]
					a = a + 1
				else:
					tmp[out] = fns[b]
					b = b + 1
				out = out + 1
			lo = hi
		for i in range(fns.length): fns[i] = tmp[i]
		width = width * 2
	return fns


# lcov tracefile or NDJSON, one record per file, in file/line order.
void wcov_emit_records(wcov_options* opt, list[wcov_line*] rows, list[wcov_fn*] fns):
	int lcov = strcmp(opt.format, c"lcov") == 0
	int start = 0
	int fn_index = 0
	while (start < rows.length):
		char* path = rows[start].path
		int end = start
		int hits = 0
		while ((end < rows.length) && (strcmp(rows[end].path, path) == 0)):
			hits = hits + rows[end].hit
			end = end + 1
		while ((fn_index < fns.length) && (strcmp(fns[fn_index].path, path) < 0)): fn_index = fn_index + 1
		if (lcov):
			println(c"TN:")
			print(c"SF:")
			println(path)
			int k = fn_index
			while ((k < fns.length) && (strcmp(fns[k].path, path) == 0)):
				println(f"FN:{fns[k].line},{fns[k].name}")
				k = k + 1
			int fn_total = 0
			int fn_hits = 0
			k = fn_index
			while ((k < fns.length) && (strcmp(fns[k].path, path) == 0)):
				println(f"FNDA:{fns[k].entered},{fns[k].name}")
				fn_total = fn_total + 1
				fn_hits = fn_hits + fns[k].entered
				k = k + 1
			println(f"FNF:{fn_total}")
			println(f"FNH:{fn_hits}")
			for i in range(start, end): println(f"DA:{rows[i].line},{rows[i].hit}")
			println(f"LF:{end - start}")
			println(f"LH:{hits}")
			println(c"end_of_record")
		else:
			print(c"{\"file\": ")
			wcov_json_string(path)
			print(f", \"lines\": {end - start}, \"hit\": {hits}, \"missed\": [")
			int first = 1
			for i in range(start, end):
				if (rows[i].hit == 0):
					if (first == 0): print(c", ")
					print(itoa(rows[i].line))
					first = 0
			println(c"]}")
		start = end


# Callee names that report a diagnostic: error, warning, type_error,
# warning_at, error_type, value_type_error, warn_type_mismatch, ...
# (print_error and friends excluded)
int wcov_is_diag_name(char* name):
	# print_error writes text; it reports nothing by itself.
	if (starts_with(name, c"print")): return 0
	if ((strcmp(name, c"error") == 0) || (strcmp(name, c"warning") == 0)): return 1
	if (starts_with(name, c"error_") || starts_with(name, c"warning_") || starts_with(name, c"warn_")): return 1
	if (ends_with(name, c"_error") || ends_with(name, c"_warning")): return 1
	if (contains(name, c"_error_") || contains(name, c"_warning_")): return 1
	return 0


# 1 when the source line calls a diagnostic function with a string
# literal first argument outside a comment: 'error(c"...")',
# 'if (x): warning("...")'. Definitions ('void error(char* s):') take no
# literal and never match. A lexical scan, not a regex: identifiers
# inside string literals and after '#' are skipped.
int wcov_line_is_diag(char* text):
	int n = strlen(text)
	int i = 0
	int in_string = 0
	while (i < n):
		int c = text[i]
		if (in_string):
			if (c == 92): i = i + 1
			elif (c == '"'): in_string = 0
			i = i + 1
			continue
		if (c == '#'): return 0
		if (c == '"'):
			in_string = 1
			i = i + 1
			continue
		if (isalpha(c) || (c == '_')):
			int start = i
			while ((i < n) && (isalnum(text[i]) || (text[i] == '_'))): i = i + 1
			if ((i < n) && (text[i] == '(')):
				char* name = substring(text, start, i)
				int diag = wcov_is_diag_name(name)
				free(name)
				if (diag):
					int j = i + 1
					if ((j < n) && ((text[j] == 'c') || (text[j] == 's'))): j = j + 1
					if ((j < n) && (text[j] == '"')): return 1
			continue
		i = i + 1
	return 0


char* wcov_trimmed(char* text):
	int i = 0
	while ((text[i] == ' ') || (text[i] == 9)): i = i + 1
	return text + i


# Floors from a baseline file: '<prefix> <percent>' per line, '#'
# comments; the prefix 'diagnostics' is the diagnostic-site floor.
int wcov_check_baseline(wcov_options* opt, list[wcov_line*] rows, int diag_hits, int diag_total):
	list[char*] lines = file_read_lines(opt.baseline)
	if (lines == 0): wcov_lines_fail(c"cannot read baseline")
	int failed = 0
	for char* raw in lines:
		char* line = wcov_trimmed(raw)
		if ((line[0] == 0) || (line[0] == '#')): continue
		list[char*] fields = split(line)
		if (fields.length != 2): wcov_lines_fail(c"baseline rows are '<prefix> <percent>'")
		list[char*] parts = split(fields[1], '.')
		if ((parts.length > 2) || ((parts.length == 2) && (strlen(parts[1]) != 1))): wcov_lines_fail(c"baseline floors take at most one decimal")
		int floor = wcov_small_decimal(parts[0]) * 10
		if (parts.length == 2): floor = floor + wcov_small_decimal(parts[1])
		int hits = 0
		int total = 0
		if (strcmp(fields[0], c"diagnostics") == 0):
			hits = diag_hits
			total = diag_total
		else:
			for wcov_line* row in rows:
				if (starts_with(row.path, fields[0])):
					total = total + 1
					hits = hits + row.hit
		char* pct = wcov_pct(hits, total)
		if (total == 0):
			println(f"baseline: FAIL {fields[0]} has no measured lines")
			failed = 1
		elif (hits * 1000 / total < floor):
			println(f"baseline: FAIL {fields[0]} {pct} is below its floor {fields[1]}%")
			failed = 1
		else: println(f"baseline: ok {fields[0]} {pct} (floor {fields[1]}%)")
		free(pct)
	return failed


# The diagnostic call sites among rows: prints them under --diagnostics
# and returns the hit count; *total receives the site count.
int wcov_diagnostic_sites(wcov_options* opt, list[wcov_line*] rows, int* total):
	int hits = 0
	int sites = 0
	char* current = 0
	list[char*] source = 0
	for wcov_line* row in rows:
		if ((current == 0) || (strcmp(current, row.path) != 0)):
			current = row.path
			source = file_read_lines(row.path)
		if (source == 0): continue
		if (row.line > source.length): continue
		char* text = source[row.line - 1]
		if (wcov_line_is_diag(text) == 0): continue
		sites = sites + 1
		hits = hits + row.tail_hit
		if (opt.diagnostics && ((opt.uncovered_only == 0) || (row.tail_hit == 0))):
			char* state = c"miss"
			if (row.tail_hit): state = c"hit"
			println(f"{row.path}:{row.line}: {state}: {wcov_trimmed(text)}")
	*total = sites
	return hits


void wcov_function_summary(wcov_options* opt, list[wcov_line*] rows, list[wcov_fn*] fns):
	for wcov_fn* wf in fns:
		wf.total = 0
		wf.hits = 0
	for wcov_line* row in rows:
		if (row.fn != 0):
			row.fn.total = row.fn.total + 1
			row.fn.hits = row.fn.hits + row.hit
	int entered = 0
	for wcov_fn* wf in fns:
		entered = entered + wf.entered
		if (opt.uncovered_only && wf.entered): continue
		wcov_print_row(wf.hits, wf.total, f"{wf.path}:{wf.line}: {wf.name}")
	if (fns.length > 0): wcov_print_total(c"function coverage", entered, fns.length)


void wcov_group_summary(wcov_options* opt, list[wcov_line*] rows):
	map[char*, wcov_group*] groups = new map[char*, wcov_group*]
	int by_dir = strcmp(opt.summary, c"dir") == 0
	for wcov_line* row in rows:
		char* name = row.path
		if (by_dir): name = wcov_top_dir(row.path)
		wcov_group* g = wcov_group_for(groups, name)
		g.total = g.total + 1
		g.hits = g.hits + row.hit
	list[char*] names = new list[char*]
	for char* name in groups: names.push(name)
	names.sort()
	for char* name in names:
		wcov_group* g = groups[name]
		if (opt.uncovered_only && (g.hits == g.total)): continue
		wcov_print_row(g.hits, g.total, g.name)


wcov_state* wcov_state_new():
	wcov_state* st = new wcov_state()
	st.lines = new map[char*, wcov_line*]
	st.fns = new map[char*, wcov_fn*]
	st.counters = 0
	return st


wcov_options* wcov_options_new():
	wcov_options* opt = new wcov_options()
	opt.files = new set[char*]
	opt.prefixes = new list[char*]
	opt.uncovered_only = 0
	opt.summary = 0
	opt.format = c"text"
	opt.diagnostics = 0
	opt.baseline = 0
	return opt


# One report over loaded state, on stdout; the exit status (1 when a
# baseline floor fails).
int wcov_report(wcov_state* st, wcov_options* opt):
	list[char*] keys = new list[char*]
	for char* key in st.lines: keys.push(key)
	keys.sort()
	list[wcov_line*] rows = new list[wcov_line*]
	int total = 0
	int hits = 0
	for char* key in keys:
		wcov_line* entry = st.lines[key]
		if (wcov_selected(opt, entry.path) == 0): continue
		rows.push(entry)
		total = total + 1
		hits = hits + entry.hit
	if (total == 0): wcov_lines_fail(c"no executable lines matched")

	int diag_total = 0
	int diag_hits = 0
	if (opt.diagnostics || (opt.baseline != 0)):
		diag_hits = wcov_diagnostic_sites(opt, rows, &diag_total)
	if (opt.diagnostics):
		if (diag_total == 0): wcov_lines_fail(c"no diagnostic call sites matched")
		wcov_print_total(c"diagnostic coverage", diag_hits, diag_total)
		return 0

	list[wcov_fn*] fns = wcov_sorted_fns(st, opt)
	int text = strcmp(opt.format, c"text") == 0
	if (text == 0): wcov_emit_records(opt, rows, fns)
	elif (opt.summary == 0):
		for wcov_line* row in rows:
			if (opt.uncovered_only && row.hit): continue
			print(row.path)
			print(c":")
			print(itoa(row.line))
			if (row.hit): println(c": hit")
			else: println(c": miss")
	elif (strcmp(opt.summary, c"function") == 0): wcov_function_summary(opt, rows, fns)
	else: wcov_group_summary(opt, rows)
	if (text): wcov_print_total(c"line coverage", hits, total)
	if (opt.baseline != 0):
		if (wcov_check_baseline(opt, rows, diag_hits, diag_total)): return 1
	return 0


int wcov_lines_main():
	wcov_state* st = wcov_state_new()
	wcov_options* opt = wcov_options_new()
	int dumps = 0
	for i in range(2, args_count()):
		char* arg = args_get(i)
		int takes_value = (strcmp(arg, c"--file") == 0) || (strcmp(arg, c"--prefix") == 0) || (strcmp(arg, c"--summary") == 0) || (strcmp(arg, c"--format") == 0) || (strcmp(arg, c"--baseline") == 0)
		if (takes_value):
			i = i + 1
			if (i >= args_count()):
				if (strcmp(arg, c"--file") == 0): wcov_lines_fail(c"--file requires a source path")
				wcov_lines_fail(f"{arg} requires a value")
			char* value = args_get(i)
			if (strcmp(arg, c"--file") == 0): opt.files.add(value)
			elif (strcmp(arg, c"--prefix") == 0): opt.prefixes.push(value)
			elif (strcmp(arg, c"--summary") == 0):
				if ((strcmp(value, c"file") != 0) && (strcmp(value, c"dir") != 0) && (strcmp(value, c"function") != 0)): wcov_lines_fail(c"--summary takes file, dir or function")
				opt.summary = value
			elif (strcmp(arg, c"--format") == 0):
				if ((strcmp(value, c"text") != 0) && (strcmp(value, c"lcov") != 0) && (strcmp(value, c"json") != 0)): wcov_lines_fail(c"--format takes text, lcov or json")
				opt.format = value
			else: opt.baseline = value
		elif (strcmp(arg, c"--uncovered-only") == 0): opt.uncovered_only = 1
		elif (strcmp(arg, c"--diagnostics") == 0): opt.diagnostics = 1
		elif (ends_with(arg, c".wprofmap")):
			if ((st.counters != 0) && (dumps == 0)): wcov_lines_fail(c"each map requires a dump")
			wcov_line_map(st, arg)
			dumps = 0
		else:
			if (st.counters == 0): wcov_lines_fail(c"usage: wcoverage lines [options] <binary.wprofmap> <dump> [<map> <dump> ...]")
			wcov_dump_arg(st, arg)
			dumps = dumps + 1
	if ((st.counters == 0) || (dumps == 0)): wcov_lines_fail(c"each map requires a dump")
	return wcov_report(st, opt)
