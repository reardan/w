/* Package metadata helpers for package.wmeta files. */
import lib.lib
import lib.file
import lib.path
import structures.string


struct package_dep:
	char* name
	char* constraint


struct package_meta:
	char* meta_path
	char* dir
	char* name
	char* version
	char* root
	char* description
	char* authors
	char* license
	list[char*] modules
	list[char*] resources
	list[package_dep*] dependencies
	list[char*] diagnostics


char* pkg_trim(char* s):
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


list[char*] pkg_split_words(char* line):
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


void pkg_diag(package_meta* meta, char* message):
	meta.diagnostics.push(strclone(message))


void pkg_diag3(package_meta* meta, char* a, char* b, char* c):
	string_builder* s = string_new()
	string_append(s, a)
	string_append(s, b)
	string_append(s, c)
	pkg_diag(meta, s.data)
	string_free(s)


char* pkg_normalize_name(char* name):
	char* out = strclone(name)
	int i = 0
	while (out[i] != 0):
		if (('A' <= out[i]) & (out[i] <= 'Z')):
			out[i] = out[i] + 32
		else if (out[i] == '_'):
			out[i] = '-'
		i = i + 1
	return out


int pkg_valid_name(char* name):
	if (name == 0):
		return 0
	if (name[0] == 0):
		return 0
	int i = 0
	while (name[i] != 0):
		char ch = name[i]
		if (('A' <= ch) & (ch <= 'Z')):
			return 0
		if (((('a' <= ch) & (ch <= 'z')) | (('0' <= ch) & (ch <= '9')) | (ch == '-') | (ch == '_')) == 0):
			return 0
		i = i + 1
	return 1


int pkg_valid_version(char* version):
	if (version == 0):
		return 0
	int i = 0
	int saw_digit = 0
	while (version[i] != 0):
		char ch = version[i]
		if (('0' <= ch) & (ch <= '9')):
			saw_digit = 1
		else if ((ch == '.') | (ch == '-') | (ch == '_') | (('a' <= ch) & (ch <= 'z')) | (('A' <= ch) & (ch <= 'Z'))):
			pass
		else:
			return 0
		i = i + 1
	return saw_digit


int pkg_path_safe(char* rel):
	if (rel == 0):
		return 0
	if (rel[0] == 0):
		return 0
	if (rel[0] == '/'):
		return 0
	int i = 0
	int segment_start = 1
	while (rel[i] != 0):
		if (rel[i] == '/'):
			segment_start = 1
		else:
			if (segment_start & (rel[i] == '.')):
				if ((rel[i + 1] == '.') & ((rel[i + 2] == '/') | (rel[i + 2] == 0))):
					return 0
			segment_start = 0
		i = i + 1
	return 1


char* pkg_dotted_to_path(char* dotted):
	char* path = strclone(dotted)
	str_replace(path, '.', '/')
	return path


int pkg_valid_dotted_module(char* s):
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
	return segment_start == 0


package_meta* pkg_meta_new(char* path):
	package_meta* meta = new package_meta
	meta.meta_path = strclone(path)
	meta.dir = path_dirname(path)
	meta.name = 0
	meta.version = 0
	meta.root = 0
	meta.description = 0
	meta.authors = 0
	meta.license = 0
	meta.modules = new list[char*]
	meta.resources = new list[char*]
	meta.dependencies = new list[package_dep*]
	meta.diagnostics = new list[char*]
	return meta


void pkg_set_field(package_meta* meta, list[char*] words):
	if (words.length < 1):
		return
	char* key = words[0]
	if (words.length != 2):
		pkg_diag3(meta, c"field '", key, c"' expects exactly one value")
		return
	char* value = strclone(words[1])
	if (strcmp(key, c"name") == 0):
		meta.name = value
	else if (strcmp(key, c"version") == 0):
		meta.version = value
	else if (strcmp(key, c"root") == 0):
		meta.root = value
	else if (strcmp(key, c"description") == 0):
		meta.description = value
	else if (strcmp(key, c"authors") == 0):
		meta.authors = value
	else if (strcmp(key, c"license") == 0):
		meta.license = value
	else:
		pkg_diag3(meta, c"unknown field '", key, c"'")


void pkg_parse_dependency(package_meta* meta, list[char*] words):
	if (words.length != 2):
		pkg_diag(meta, c"dependency entries require name and constraint")
		return
	package_dep* dep = new package_dep
	dep.name = strclone(words[0])
	dep.constraint = strclone(words[1])
	meta.dependencies.push(dep)


int pkg_validate(package_meta* meta, string_builder* diagnostics);


package_meta* pkg_read_metadata(char* path):
	package_meta* meta = pkg_meta_new(path)
	list[char*] lines = file_read_lines(path)
	if (lines == 0):
		pkg_diag(meta, c"cannot read package.wmeta")
		return meta
	int section = 0
	for char* raw in lines:
		int indented = (raw[0] == 9) | (raw[0] == ' ')
		char* line = pkg_trim(raw)
		if ((line[0] == 0) | (line[0] == '#')):
			pass
		else if (indented == 0):
			section = 0
			if (strcmp(line, c"modules:") == 0):
				section = 1
			else if (strcmp(line, c"resources:") == 0):
				section = 2
			else if (strcmp(line, c"dependencies:") == 0):
				section = 3
			else:
				pkg_set_field(meta, pkg_split_words(line))
		else if (section == 1):
			meta.modules.push(strclone(line))
		else if (section == 2):
			meta.resources.push(strclone(line))
		else if (section == 3):
			pkg_parse_dependency(meta, pkg_split_words(line))
		else:
			pkg_diag3(meta, c"indented entry '", line, c"' outside a section")
	pkg_validate(meta, 0)
	return meta


int pkg_validate(package_meta* meta, string_builder* diagnostics):
	if (meta.name == 0):
		pkg_diag(meta, c"missing 'name' field")
	else if (pkg_valid_name(meta.name) == 0):
		pkg_diag3(meta, c"invalid package name '", meta.name, c"'")
	if (meta.version == 0):
		pkg_diag(meta, c"missing 'version' field")
	else if (pkg_valid_version(meta.version) == 0):
		pkg_diag3(meta, c"invalid version '", meta.version, c"'")
	if (meta.root == 0):
		pkg_diag(meta, c"missing 'root' field")
	else if (pkg_path_safe(meta.root) == 0):
		pkg_diag3(meta, c"invalid root '", meta.root, c"'")
	for char* module in meta.modules:
		if (pkg_valid_dotted_module(module) == 0):
			pkg_diag3(meta, c"invalid module name '", module, c"'")
	for char* resource in meta.resources:
		if (pkg_path_safe(resource) == 0):
			pkg_diag3(meta, c"invalid resource path '", resource, c"'")
	for package_dep* dep in meta.dependencies:
		if (pkg_valid_name(dep.name) == 0):
			pkg_diag3(meta, c"invalid dependency name '", dep.name, c"'")
		if (dep.constraint[0] == 0):
			pkg_diag3(meta, c"empty dependency constraint for '", dep.name, c"'")
	if (diagnostics != 0):
		for char* diag in meta.diagnostics:
			string_append(diagnostics, diag)
			string_append_char(diagnostics, 10)
	return meta.diagnostics.length == 0


char* pkg_version(package_meta* meta):
	return meta.version


list[package_dep*] pkg_dependencies(package_meta* meta):
	return meta.dependencies
