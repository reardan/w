/*
Checks the NDJSON that `w defhash` wrote for the defhash fixtures, run
by the defhash_test target (tests/defhash_fixture.w.wbuild) after its
own steps have produced:

  bin/defhash_fixture.ndjson                     tests/defhash_fixture.w
  bin/defhash_fixture_reformatted.ndjson         ..._reformatted.w
  bin/defhash_fixture_edited.ndjson              ..._edited.w
  bin/defhash_fixture_closure.ndjson             --closure tests/defhash_fixture.w
  bin/defhash_generic_fixture{,_reformatted,_edited,_renamed}.ndjson

It replaced the target's inline `sh -c` steps (issue #323: no shell),
keeping every assertion: record counts, refs lists, hash stability
under reformatting, hash changes exactly where a definition was edited,
and a rename dropping the old name. Reading files only -- no children.
Prints "defhash e2e OK" on success; each failed check prints a FAIL line
and the program exits 1.
*/
import lib.lib
import lib.file
import lib.str


int FAILED = 0


void out(char* s):
	write(1, s, strlen(s))


void fail(char* what, char* detail):
	out(c"FAIL: ")
	out(what)
	if (detail != 0):
		out(c": ")
		out(detail)
	out(c"\n")
	FAILED = 1


list[char*] load(char* path):
	list[char*] lines = file_read_lines(path)
	if (lines == 0):
		fail(c"cannot read", path)
		return new list[char*]
	return lines


# The '"name": "<name>"' key every record of <name> contains.
char* name_key(char* name):
	return strjoin(strjoin(c"\"name\": \"", name), c"\"")


# Every line containing the name key, newline-joined (grep "$key" file).
char* records(list[char*] lines, char* name):
	char* key = name_key(name)
	char* found = c""
	for char* line in lines:
		if (index_of(line, key) >= 0): found = strjoin(strjoin(found, line), c"\n")
	return found


# The '"hash": "<hex>"' fields of name's records, concatenated
# (grep ... | grep -oE '"hash": "[0-9a-f]+"'); "" when there are none.
char* hashes(list[char*] lines, char* name):
	char* key = name_key(name)
	char* found = c""
	for char* line in lines:
		if (index_of(line, key) >= 0):
			int at = index_of(line, c"\"hash\": \"")
			if (at >= 0):
				int start = at + 9
				int end = start
				while (((line[end] >= '0') && (line[end] <= '9')) || ((line[end] >= 'a') && (line[end] <= 'f'))):
					end = end + 1
				if ((end > start) && (line[end] == '"')):
					found = strjoin(strjoin(found, substring(line, at, end + 1)), c"\n")
	return found


# name's records in lines include one containing needle
# (grep "$key" file | grep -qF needle).
void expect_ref(list[char*] lines, char* name, char* needle):
	if (index_of(records(lines, name), needle) < 0): fail(strjoin(name, c" record lacks"), needle)


void expect_same_hash(list[char*] a, list[char*] b, char* name, char* what):
	char* ha = hashes(a, name)
	if (ha[0] == 0): fail(strjoin(name, c": no hash in base output"), what)
	else if (strcmp(ha, hashes(b, name)) != 0): fail(strjoin(name, c": hash changed"), what)


void expect_new_hash(list[char*] a, list[char*] b, char* name, char* what):
	char* ha = hashes(a, name)
	if (ha[0] == 0): fail(strjoin(name, c": no hash in base output"), what)
	else if (strcmp(ha, hashes(b, name)) == 0): fail(strjoin(name, c": hash did not change"), what)


int has_name(list[char*] lines, char* name):
	return records(lines, name)[0] != 0


# The line with its '"file": "..."' value replaced by F
# (sed -E 's/"file": "[^"]*"/"file": "F"/').
char* normalize_file(char* line):
	int at = index_of(line, c"\"file\": \"")
	if (at < 0):
		return line
	int end = at + 9
	while ((line[end] != 0) && (line[end] != '"')): end = end + 1
	if (line[end] == 0):
		return line
	return strjoin(strjoin(substring(line, 0, at), c"\"file\": \"F\""), substring(line, end + 1, strlen(line)))


# diff -u of the two outputs after normalizing the file field.
void expect_same_records(list[char*] a, list[char*] b, char* what):
	if (a.length != b.length):
		fail(c"record count differs", what)
		return
	int i = 0
	while (i < a.length):
		if (strcmp(normalize_file(a[i]), normalize_file(b[i])) != 0): fail(what, b[i])
		i = i + 1


int main():
	list[char*] base = load(c"bin/defhash_fixture.ndjson")
	list[char*] reformatted = load(c"bin/defhash_fixture_reformatted.ndjson")
	list[char*] edited = load(c"bin/defhash_fixture_edited.ndjson")
	list[char*] closure = load(c"bin/defhash_fixture_closure.ndjson")

	if (base.length != 7): fail(c"bin/defhash_fixture.ndjson", c"expected exactly 7 records")
	expect_ref(base, c"defhash_fixture_helper", c"\"refs\": [\"defhash_fixture_add\", \"defhash_fixture_counter\"]")
	expect_ref(base, c"main", c"\"refs\": [\"defhash_fixture_helper\"]")
	expect_ref(base, c"defhash_fixture_add", c"\"refs\": []")

	# Reformatting (whitespace/comments only) leaves every record intact.
	expect_same_records(base, reformatted, c"reformatted fixture's records differ")

	# Editing defhash_fixture_add's body changes its hash and no other.
	expect_new_hash(base, edited, c"defhash_fixture_add", c"edited fixture")
	list[char*] unchanged = new list[char*]
	unchanged.push(c"defhash_fixture_size")
	unchanged.push(c"defhash_fixture_point")
	unchanged.push(c"defhash_fixture_counter")
	unchanged.push(c"defhash_fixture_helper")
	unchanged.push(c"defhash_fixture_color")
	unchanged.push(c"main")
	for char* name in unchanged: expect_same_hash(base, edited, name, c"edited fixture")

	if (closure.length <= 7):
		fail(c"bin/defhash_fixture_closure.ndjson", c"expected more than 7 records")

	list[char*] generic = load(c"bin/defhash_generic_fixture.ndjson")
	list[char*] greformatted = load(c"bin/defhash_generic_fixture_reformatted.ndjson")
	list[char*] gedited = load(c"bin/defhash_generic_fixture_edited.ndjson")
	list[char*] grenamed = load(c"bin/defhash_generic_fixture_renamed.ndjson")
	char* op = c"operator+(defhash_generic_fixture_point, defhash_generic_fixture_point)"

	expect_ref(generic, c"defhash_generic_fixture_use_max", c"\"refs\": [\"defhash_generic_fixture_max\"]")
	expect_same_hash(generic, greformatted, c"defhash_generic_fixture_max", c"reformatted generic fixture")
	expect_same_hash(generic, greformatted, c"defhash_generic_fixture_pair", c"reformatted generic fixture")
	expect_same_hash(generic, greformatted, op, c"reformatted generic fixture")
	expect_new_hash(generic, gedited, c"defhash_generic_fixture_max", c"edited generic fixture")
	expect_new_hash(generic, gedited, op, c"edited generic fixture")
	expect_same_hash(generic, gedited, c"defhash_generic_fixture_pair", c"edited generic fixture")

	# Renaming max -> maxval: the old name is gone, the new one appears.
	if (has_name(generic, c"defhash_generic_fixture_max") == 0):
		fail(c"generic fixture", c"lacks defhash_generic_fixture_max")
	if (has_name(grenamed, c"defhash_generic_fixture_max")):
		fail(c"renamed generic fixture", c"still has defhash_generic_fixture_max")
	if (has_name(grenamed, c"defhash_generic_fixture_maxval") == 0):
		fail(c"renamed generic fixture", c"lacks defhash_generic_fixture_maxval")
	if (has_name(generic, c"defhash_generic_fixture_maxval")):
		fail(c"generic fixture", c"has defhash_generic_fixture_maxval")

	if (FAILED): return 1
	out(c"defhash e2e OK\n")
	return 0
