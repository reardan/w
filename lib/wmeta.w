/*
package.wmeta parser and checker (design: docs/package_metadata.txt).

The format is line-oriented so this parser stays trivial: blank lines and
'#' comments are ignored, top-level fields are "key value" pairs, and the
"modules:" / "dependencies:" section headers are followed by indented
entries. wmeta_check_file() loads a package file, validates it, follows
"path" dependencies recursively, and records every problem as a message
in the returned check object; it never touches the compiler.

Validation is tooling-only by design. The compiler's import resolution
(dotted path -> file, resolved by walking up from the current working
directory) is unchanged, so a build can still silently pick up a matching
file from an ancestor W tree unless it runs from an isolated root; this
checker validates the declared tree, it cannot pin what the compiler sees.
*/
import lib.lib
import lib.file
import structures.string


struct wmeta_version:
	int major
	int minor
	int patch


struct wmeta_constraint:
	int kind    # '=' exact, '>' minimum (>=), '^' compatible range
	wmeta_version* version


struct wmeta_dep:
	char* name
	char* constraint
	char* path    # 0 when the dependency has no "path" field


struct wmeta_package:
	char* meta_path     # the package.wmeta path as given to the loader
	char* dir           # directory containing the metadata file
	char* name
	char* version
	char* w_language    # 0 when absent (the field is advisory)
	char* root          # 0 when absent; the first stage requires "."
	list[char*] modules
	list[wmeta_dep*] deps


struct wmeta_check:
	list[wmeta_package*] packages
	list[char*] errors


# Trim leading and trailing whitespace in place; returns the trimmed start.
char* wmeta_trim(char* s):
	while ((s[0] == ' ') | (s[0] == 9) | (s[0] == 13)):
		s = s + 1
	int n = strlen(s)
	while (n > 0):
		char last = s[n - 1]
		if ((last == ' ') | (last == 9) | (last == 13)):
			s[n - 1] = 0
			n = n - 1
		else:
			break
	return s


list[char*] wmeta_split_words(char* line):
	list[char*] words = new list[char*]
	int i = 0
	while (line[i] != 0):
		while ((line[i] == ' ') | (line[i] == 9)):
			i = i + 1
		if (line[i] == 0):
			break
		int start = i
		while ((line[i] != 0) & (line[i] != ' ') & (line[i] != 9)):
			i = i + 1
		int n = i - start
		char* word = malloc(n + 1)
		int j = 0
		while (j < n):
			word[j] = line[start + j]
			j = j + 1
		word[n] = 0
		words.push(word)
	return words


int wmeta_file_exists(char* path):
	int fd = open(path, 0, 0)
	if (fd < 0):
		return 0
	close(fd)
	return 1


# Directory of a file path: "a/b/package.wmeta" -> "a/b", "package.wmeta" -> "."
char* wmeta_dirname(char* path):
	int i = strlen(path) - 1
	while (i >= 0):
		if (path[i] == '/'):
			char* dir = strclone(path)
			dir[i] = 0
			return dir
		i = i - 1
	return strclone(c".")


char* wmeta_join(char* dir, char* rel):
	char* with_sep = strjoin(dir, c"/")
	char* joined = strjoin(with_sep, rel)
	free(with_sep)
	return joined


# Package and module names are lower-case dotted paths: segments of
# [a-z_][a-z0-9_]* separated by single dots.
int wmeta_valid_dotted_name(char* s):
	int i = 0
	int segment_start = 1
	while (s[i] != 0):
		char ch = s[i]
		if (segment_start):
			if ((('a' <= ch) & (ch <= 'z')) | (ch == '_')):
				segment_start = 0
			else:
				return 0
		else if (ch == '.'):
			segment_start = 1
		else if ((('a' <= ch) & (ch <= 'z')) | (('0' <= ch) & (ch <= '9')) | (ch == '_')):
			pass
		else:
			return 0
		i = i + 1
	if (segment_start):
		return 0
	return 1


# Reads a decimal number at s[i..]; leaves the index after the digits in
# wmeta_scan_pos. Returns -1 when s[i] is not a digit.
int wmeta_scan_pos
int wmeta_scan_number(char* s, int i):
	if ((s[i] < '0') | (s[i] > '9')):
		return -1
	int value = 0
	while (('0' <= s[i]) & (s[i] <= '9')):
		value = value * 10 + (s[i] - '0')
		i = i + 1
	wmeta_scan_pos = i
	return value


# Parses "major.minor.patch" with exactly three decimal components.
# Returns 0 on any deviation, so tooling stays strict and comparable.
wmeta_version* wmeta_parse_version(char* s):
	int major = wmeta_scan_number(s, 0)
	if (major < 0):
		return 0
	if (s[wmeta_scan_pos] != '.'):
		return 0
	int minor = wmeta_scan_number(s, wmeta_scan_pos + 1)
	if (minor < 0):
		return 0
	if (s[wmeta_scan_pos] != '.'):
		return 0
	int patch = wmeta_scan_number(s, wmeta_scan_pos + 1)
	if (patch < 0):
		return 0
	if (s[wmeta_scan_pos] != 0):
		return 0
	wmeta_version* v = new wmeta_version
	v.major = major
	v.minor = minor
	v.patch = patch
	return v


# Constraint forms from the design doc: =1.2.3, >=1.2.3 and ^1.2.3.
wmeta_constraint* wmeta_parse_constraint(char* s):
	int kind = 0
	char* rest = s
	if (s[0] == '='):
		kind = '='
		rest = s + 1
	else if ((s[0] == '>') & (s[1] == '=')):
		kind = '>'
		rest = s + 2
	else if (s[0] == '^'):
		kind = '^'
		rest = s + 1
	else:
		return 0
	wmeta_version* v = wmeta_parse_version(rest)
	if (v == 0):
		return 0
	wmeta_constraint* c = new wmeta_constraint
	c.kind = kind
	c.version = v
	return c


int wmeta_version_compare(wmeta_version* a, wmeta_version* b):
	if (a.major != b.major):
		return a.major - b.major
	if (a.minor != b.minor):
		return a.minor - b.minor
	return a.patch - b.patch


int wmeta_constraint_satisfied(wmeta_constraint* c, wmeta_version* v):
	int cmp = wmeta_version_compare(v, c.version)
	if (c.kind == '='):
		return cmp == 0
	if (c.kind == '>'):
		return cmp >= 0
	# '^': ^1.2.3 allows <2.0.0, ^0.2.3 allows <0.3.0, ^0.0.3 is exact
	if (c.version.major > 0):
		return (cmp >= 0) & (v.major == c.version.major)
	if (c.version.minor > 0):
		return (cmp >= 0) & (v.major == 0) & (v.minor == c.version.minor)
	return cmp == 0


# Module dotted path -> repository-relative file path (without ".w").
char* wmeta_module_path(char* module):
	char* path = strclone(module)
	str_replace(path, '.', '/')
	return path


# Offset of a whole "__arch__" path segment, or -1. Mirrors the compiler's
# import_resolve_arch (grammar/import_statement.w) segment matching.
int wmeta_arch_segment(char* path):
	int i = 0
	while (path[i] != 0):
		if (starts_with(path + i, c"__arch__")):
			int at_boundary = (i == 0) | (path[i - 1] == '/')
			char after = path[i + 8]
			if (at_boundary & ((after == '/') | (after == 0))):
				return i
		i = i + 1
	return -1


# "lib/__arch__/syscalls" + "x86" -> "lib/__arch__/x86/syscalls"
char* wmeta_insert_arch(char* path, int pos, char* arch):
	string_builder* s = string_new()
	int i = 0
	while (i < pos + 8):
		string_append_char(s, path[i])
		i = i + 1
	string_append_char(s, '/')
	string_append(s, arch)
	string_append(s, path + pos + 8)
	char* out = s.data
	free(s)
	return out


void wmeta_check_error(wmeta_check* check, char* meta_path, char* message):
	string_builder* s = string_new()
	string_append(s, meta_path)
	string_append(s, c": ")
	string_append(s, message)
	char* text = s.data
	free(s)
	check.errors.push(text)


void wmeta_error2(wmeta_check* check, char* meta_path, char* part1, char* part2, char* part3):
	string_builder* s = string_new()
	string_append(s, part1)
	string_append(s, part2)
	string_append(s, part3)
	wmeta_check_error(check, meta_path, s.data)
	string_free(s)


void wmeta_set_field(wmeta_check* check, wmeta_package* pkg, char* key, char* value, list[char*] words):
	if (words.length != 2):
		wmeta_error2(check, pkg.meta_path, c"field '", key, c"' expects exactly one value")
		return
	if (strcmp(key, c"package") == 0):
		pkg.name = value
	else if (strcmp(key, c"version") == 0):
		pkg.version = value
	else if (strcmp(key, c"w_language") == 0):
		pkg.w_language = value
	else if (strcmp(key, c"root") == 0):
		pkg.root = value
	else:
		wmeta_error2(check, pkg.meta_path, c"unknown field '", key, c"'")


void wmeta_parse_dep_entry(wmeta_check* check, wmeta_package* pkg, list[char*] words):
	int valid = (words.length == 2) | (words.length == 4)
	if (words.length == 4):
		if (strcmp(words[2], c"path") != 0):
			valid = 0
	if (valid == 0):
		wmeta_error2(check, pkg.meta_path, c"invalid dependency entry: expected '", c"<package> <constraint> [path <relative-path>]", c"'")
		return
	wmeta_dep* dep = new wmeta_dep
	dep.name = words[0]
	dep.constraint = words[1]
	dep.path = 0
	if (words.length == 4):
		dep.path = words[3]
	pkg.deps.push(dep)


# Parses one package.wmeta file into a package record. Structural problems
# (unknown fields, malformed entries) are recorded on the check object;
# returns 0 only when the file cannot be read.
wmeta_package* wmeta_parse(wmeta_check* check, char* meta_path):
	list[char*] lines = file_read_lines(meta_path)
	if (lines == 0):
		return 0
	wmeta_package* pkg = new wmeta_package
	pkg.meta_path = strclone(meta_path)
	pkg.dir = wmeta_dirname(meta_path)
	pkg.name = 0
	pkg.version = 0
	pkg.w_language = 0
	pkg.root = 0
	pkg.modules = new list[char*]
	pkg.deps = new list[wmeta_dep*]

	int section = 0    # 0 top-level fields, 1 modules, 2 dependencies
	for char* raw in lines:
		int indented = (raw[0] == 9) | (raw[0] == ' ')
		char* line = wmeta_trim(raw)
		if ((line[0] == 0) | (line[0] == '#')):
			pass
		else if (indented == 0):
			section = 0
			if (strcmp(line, c"modules:") == 0):
				section = 1
			else if (strcmp(line, c"dependencies:") == 0):
				section = 2
			else:
				list[char*] words = wmeta_split_words(line)
				char* value = c""
				if (words.length >= 2):
					value = words[1]
				wmeta_set_field(check, pkg, words[0], value, words)
		else if (section == 1):
			pkg.modules.push(strclone(line))
		else if (section == 2):
			wmeta_parse_dep_entry(check, pkg, wmeta_split_words(line))
		else:
			wmeta_error2(check, pkg.meta_path, c"indented entry '", line, c"' outside a section")
	return pkg


void wmeta_require_module_file(wmeta_check* check, wmeta_package* pkg, char* module, char* path):
	char* with_ext = strjoin(path, c".w")
	char* full = wmeta_join(pkg.dir, with_ext)
	if (wmeta_file_exists(full) == 0):
		string_builder* s = string_new()
		string_append(s, c"module '")
		string_append(s, module)
		string_append(s, c"' not found: ")
		string_append(s, full)
		wmeta_check_error(check, pkg.meta_path, s.data)
		string_free(s)
	free(with_ext)
	free(full)


void wmeta_validate_module(wmeta_check* check, wmeta_package* pkg, char* module, int index):
	if (wmeta_valid_dotted_name(module) == 0):
		wmeta_error2(check, pkg.meta_path, c"invalid module name '", module, c"'")
		return
	int i = 0
	while (i < index):
		if (strcmp(pkg.modules[i], module) == 0):
			wmeta_error2(check, pkg.meta_path, c"duplicate module '", module, c"'")
			return
		i = i + 1
	char* path = wmeta_module_path(module)
	int arch_pos = wmeta_arch_segment(path)
	if (arch_pos >= 0):
		char* x86_path = wmeta_insert_arch(path, arch_pos, c"x86")
		char* x64_path = wmeta_insert_arch(path, arch_pos, c"x64")
		char* arm64_path = wmeta_insert_arch(path, arch_pos, c"arm64")
		char* arm64_darwin_path = wmeta_insert_arch(path, arch_pos, c"arm64_darwin")
		char* wasm_path = wmeta_insert_arch(path, arch_pos, c"wasm")
		wmeta_require_module_file(check, pkg, module, x86_path)
		wmeta_require_module_file(check, pkg, module, x64_path)
		wmeta_require_module_file(check, pkg, module, arm64_path)
		wmeta_require_module_file(check, pkg, module, arm64_darwin_path)
		wmeta_require_module_file(check, pkg, module, wasm_path)
		free(x86_path)
		free(x64_path)
		free(arm64_path)
		free(arm64_darwin_path)
		free(wasm_path)
	else:
		wmeta_require_module_file(check, pkg, module, path)
	free(path)


# Field-level validation for one parsed package.
void wmeta_validate(wmeta_check* check, wmeta_package* pkg):
	if (pkg.name == 0):
		wmeta_check_error(check, pkg.meta_path, c"missing 'package' field")
	else if (wmeta_valid_dotted_name(pkg.name) == 0):
		wmeta_error2(check, pkg.meta_path, c"invalid package name '", pkg.name, c"'")
	if (pkg.version == 0):
		wmeta_check_error(check, pkg.meta_path, c"missing 'version' field")
	else if (wmeta_parse_version(pkg.version) == 0):
		wmeta_error2(check, pkg.meta_path, c"invalid version '", pkg.version, c"': expected three numeric components")
	if (pkg.w_language != 0):
		if (wmeta_parse_constraint(pkg.w_language) == 0):
			wmeta_error2(check, pkg.meta_path, c"invalid w_language constraint '", pkg.w_language, c"'")
	if (pkg.root != 0):
		if (strcmp(pkg.root, c".") != 0):
			wmeta_error2(check, pkg.meta_path, c"root must be '.' (got '", pkg.root, c"')")
	int i = 0
	while (i < pkg.modules.length):
		wmeta_validate_module(check, pkg, pkg.modules[i], i)
		i = i + 1


wmeta_package* wmeta_load(wmeta_check* check, char* meta_path);


# Validates one dependency edge: syntax, and for "path" dependencies the
# vendored package's name and version against the declared constraint.
void wmeta_check_dep(wmeta_check* check, wmeta_package* pkg, wmeta_dep* dep, int index):
	if (wmeta_valid_dotted_name(dep.name) == 0):
		wmeta_error2(check, pkg.meta_path, c"invalid dependency name '", dep.name, c"'")
		return
	wmeta_constraint* constraint = wmeta_parse_constraint(dep.constraint)
	if (constraint == 0):
		wmeta_error2(check, pkg.meta_path, c"invalid constraint '", dep.constraint, c"'")
		return
	int i = 0
	while (i < index):
		wmeta_dep* other = pkg.deps[i]
		if (strcmp(other.name, dep.name) == 0):
			wmeta_error2(check, pkg.meta_path, c"duplicate dependency '", dep.name, c"'")
			return
		i = i + 1
	if (dep.path == 0):
		# No path: nothing on disk to verify (a registry is a later stage)
		return
	char* dep_dir = wmeta_join(pkg.dir, dep.path)
	char* dep_meta = wmeta_join(dep_dir, c"package.wmeta")
	if (wmeta_file_exists(dep_meta) == 0):
		string_builder* missing = string_new()
		string_append(missing, c"dependency '")
		string_append(missing, dep.name)
		string_append(missing, c"': package.wmeta not found at ")
		string_append(missing, dep_meta)
		wmeta_check_error(check, pkg.meta_path, missing.data)
		string_free(missing)
		return
	wmeta_package* dep_pkg = wmeta_load(check, dep_meta)
	if (dep_pkg == 0):
		return
	if (dep_pkg.name != 0):
		if (strcmp(dep_pkg.name, dep.name) != 0):
			string_builder* s = string_new()
			string_append(s, c"dependency '")
			string_append(s, dep.name)
			string_append(s, c"' resolves to package '")
			string_append(s, dep_pkg.name)
			string_append(s, c"'")
			wmeta_check_error(check, pkg.meta_path, s.data)
			string_free(s)
	if (dep_pkg.version != 0):
		wmeta_version* found = wmeta_parse_version(dep_pkg.version)
		if (found != 0):
			if (wmeta_constraint_satisfied(constraint, found) == 0):
				string_builder* s = string_new()
				string_append(s, c"dependency '")
				string_append(s, dep.name)
				string_append(s, c"' version ")
				string_append(s, dep_pkg.version)
				string_append(s, c" does not satisfy constraint ")
				string_append(s, dep.constraint)
				wmeta_check_error(check, pkg.meta_path, s.data)
				string_free(s)


# Loads, validates and registers a package plus its path dependencies.
# Re-entry on an already-loaded file returns the loaded record, which also
# terminates dependency cycles.
wmeta_package* wmeta_load(wmeta_check* check, char* meta_path):
	for wmeta_package* seen in check.packages:
		if (strcmp(seen.meta_path, meta_path) == 0):
			return seen
	wmeta_package* pkg = wmeta_parse(check, meta_path)
	if (pkg == 0):
		wmeta_check_error(check, meta_path, c"cannot read package.wmeta")
		return 0
	check.packages.push(pkg)
	wmeta_validate(check, pkg)
	int i = 0
	while (i < pkg.deps.length):
		wmeta_check_dep(check, pkg, pkg.deps[i], i)
		i = i + 1
	return pkg


char* wmeta_module_top(char* module):
	char* top = strclone(module)
	int i = 0
	while (top[i] != 0):
		if (top[i] == '.'):
			top[i] = 0
			return top
		i = i + 1
	return top


# Imports carry only dotted module paths and no package identity, so in an
# assembled tree every top-level module path must be owned by exactly one
# package (docs/package_metadata.txt "Import path implications").
void wmeta_check_module_ownership(wmeta_check* check):
	list[char*] tops = new list[char*]
	list[wmeta_package*] owners = new list[wmeta_package*]
	for wmeta_package* pkg in check.packages:
		for char* module in pkg.modules:
			char* top = wmeta_module_top(module)
			int found = 0
			int i = 0
			while (i < tops.length):
				if (strcmp(tops[i], top) == 0):
					found = 1
					wmeta_package* owner = owners[i]
					if (owner != pkg):
						string_builder* s = string_new()
						string_append(s, c"top-level module path '")
						string_append(s, top)
						string_append(s, c"' claimed by packages '")
						string_append(s, owner.name)
						string_append(s, c"' and '")
						string_append(s, pkg.name)
						string_append(s, c"'")
						wmeta_check_error(check, pkg.meta_path, s.data)
						string_free(s)
					i = tops.length
				i = i + 1
			if (found == 0):
				tops.push(top)
				owners.push(pkg)


# Entry point for tools: load the package graph rooted at meta_path and
# run every validation. The caller inspects check.errors.
wmeta_check* wmeta_check_file(char* meta_path):
	wmeta_check* check = new wmeta_check
	check.packages = new list[wmeta_package*]
	check.errors = new list[char*]
	wmeta_load(check, meta_path)
	wmeta_check_module_ownership(check)
	return check
