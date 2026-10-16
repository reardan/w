# Resolve grammar files before collecting rules. No imported host code executes.
# Only plain imports, tokenVocab, and tokens{} have resolved semantics here;
# all other dependency blocks remain visible to the conservative audit.
import libs.extras.grammars.antlr_to_pg.ast
import libs.extras.grammars.antlr_to_pg.audit_json
import lib.path
import lib.utf8


struct at_dependency_input:
	char* path
	char* key
	char* source
	char* name
	int kind                # 0 combined, 1 lexer, 2 parser
	int state               # 0 unread edges, 1 visiting, 2 complete
	int failed
	int imported
	list[at_dependency_input*] imports
	pg_ast_node* root


list[at_dependency_input*] g_at_inputs
list[pg_token*] g_at_resolved_sites
char* g_at_dependency_cwd
int g_at_dependency_error


int at_dependency_fail(char* path, char* reason):
	at_finding(c"AT_DEPENDENCY", c"dependencies", c"grammar_dependency", c"dependency", path, 1, 1, c"<grammar>", reason)
	println2(cstr(f"antlr_to_pg: dependency error in {path}: {reason}"))
	g_at_dependency_error = g_at_dependency_error + 1
	return 0


int at_dependency_identifier_start(int ch):
	return ((ch >= 'A') && (ch <= 'Z')) || ((ch >= 'a') && (ch <= 'z')) || (ch == '_')


int at_dependency_identifier(char* text):
	if (at_dependency_identifier_start(text[0]) == 0): return 0
	int i = 1
	while (text[i] != 0):
		int ch = text[i]
		if ((at_dependency_identifier_start(ch) == 0) && ((ch < '0') || (ch > '9'))): return 0
		i = i + 1
	return 1


# Split only a retained options/tokens body. Quoted values and comments are
# atomic/skipped, so tokenVocab text inside foreign code is never interpreted.
list[char*] at_dependency_words(char* source):
	list[char*] words = new list[char*]
	int i = 0
	int length = strlen(source)
	while (i < length):
		int ch = source[i]
		if ((ch == ' ') || (ch == 9) || (ch == 10) || (ch == 13)):
			i = i + 1
			continue
		if ((ch == '/') && (i + 1 < length)):
			if (source[i + 1] == '/'):
				i = i + 2
				while ((i < length) && (source[i] != 10)): i = i + 1
				continue
			if (source[i + 1] == '*'):
				i = i + 2
				while (i + 1 < length):
					if ((source[i] == '*') && (source[i + 1] == '/')): break
					i = i + 1
				i = i + 2
				continue
		int begin = i
		i = i + 1
		if (at_dependency_identifier_start(ch)):
			while (i < length):
				int next = source[i]
				if ((at_dependency_identifier_start(next) == 0) && ((next < '0') || (next > '9'))): break
				i = i + 1
		else if ((ch == 39) || (ch == 34)):
			while (i < length):
				if (source[i] == 92):
					i = i + 2
					continue
				if (source[i] == ch):
					i = i + 1
					break
				i = i + 1
		if (i > length): return 0
		words.push(pg_substr(source, begin, i - begin))
	return words


at_dependency_input* at_dependency_load(char* path):
	char* key = path_join(g_at_dependency_cwd, path)
	for at_dependency_input* known in g_at_inputs:
		if (strcmp(known.key, key) == 0): return known
	char* source = file_read_text(path)
	if (source == 0):
		at_dependency_fail(path, c"could not read grammar file")
		return 0
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_ast_node* root = antlr4_parse(source, path, diagnostics)
	if ((root == 0) || (pg_diagnostics_count(diagnostics) != 0)):
		at_dependency_fail(path, c"failed to parse grammar")
		pg_diagnostics_print(diagnostics)
		return 0
	at_dependency_input* input = new at_dependency_input()
	input.path = path
	input.key = key
	input.source = source
	input.root = root
	input.imports = new list[at_dependency_input*]
	int count = pg_ast_child_count(root) - 1
	for i in range(count):
		pg_ast_node* inner = pg_ast_child(pg_ast_child(root, i), 0)
		if (inner.kind == antlr4_ast_grammar_decl):
			if (input.name != 0):
				at_dependency_fail(path, c"multiple grammar declarations")
				return 0
			int n = pg_ast_child_count(inner)
			input.name = strclone(pg_ast_child(inner, n - 2).text)
			if (n == 4):
				char* kind = pg_ast_child(inner, 0).text
				if (strcmp(kind, c"lexer") == 0): input.kind = 1
				else if (strcmp(kind, c"parser") == 0): input.kind = 2
				else:
					at_dependency_fail(path, c"unsupported grammar declaration")
					return 0
				if (strcmp(pg_ast_child(inner, 1).text, c"grammar") != 0):
					at_dependency_fail(path, c"expected grammar keyword")
					return 0
			else if (strcmp(pg_ast_child(inner, 0).text, c"grammar") != 0):
				at_dependency_fail(path, c"expected grammar keyword")
				return 0
	if (input.name == 0):
		at_dependency_fail(path, c"missing grammar declaration")
		return 0
	for at_dependency_input* known in g_at_inputs:
		if (strcmp(known.name, input.name) == 0):
			at_dependency_fail(path, cstr(f"ambiguous grammar {input.name}; already supplied by {known.path}"))
			return 0
	g_at_inputs.push(input)
	return input


int at_dependency_channels(at_dependency_input* input, pg_ast_node* node):
	if (input.kind != 1): return at_dependency_fail(input.path, c"channels declaration requires a lexer grammar")
	list[char*] words = at_dependency_words(pg_ast_child(node, 1).text)
	if ((words == 0) || (words.length < 2)): return at_dependency_fail(input.path, c"malformed channels declaration")
	if (g_at_channels == 0): g_at_channels = new list[char*]
	int i = 1
	while (i < words.length - 1):
		char* name = words[i]
		if ((at_dependency_identifier(name) == 0) || (strcmp(name, c"HIDDEN") == 0) || (strcmp(name, c"DEFAULT_TOKEN_CHANNEL") == 0) || at_custom_channel(name)):
			return at_dependency_fail(input.path, c"invalid or repeated channel name")
		g_at_channels.push(strclone(name))
		i = i + 1
		if (i < words.length - 1):
			if (strcmp(words[i], c",") != 0): return at_dependency_fail(input.path, c"malformed channels declaration")
			i = i + 1
	return 1


int at_dependency_resolve(at_dependency_input* input);


int at_dependency_edge(at_dependency_input* input, char* name, int imported):
	if (at_dependency_identifier(name) == 0): return at_dependency_fail(input.path, c"invalid dependency grammar name")
	char* sibling = path_join(path_dirname(input.path), cstr(f"{name}.g4"))
	char* sibling_key = path_join(g_at_dependency_cwd, sibling)
	at_dependency_input* dependency = 0
	for at_dependency_input* known in g_at_inputs:
		if (strcmp(known.name, name) == 0): dependency = known
	if (dependency != 0):
		if ((strcmp(dependency.key, sibling_key) != 0) && path_exists(sibling)):
			return at_dependency_fail(input.path, cstr(f"ambiguous dependency {name}: supplied file and sibling {sibling}"))
	else:
		dependency = at_dependency_load(sibling)
		if (dependency == 0): return 0
		if (strcmp(dependency.name, name) != 0):
			return at_dependency_fail(input.path, cstr(f"dependency {name} declares grammar {dependency.name}"))
	if (imported):
		dependency.imported = 1
		input.imports.push(dependency)
		if ((input.kind != 0) && (input.kind != dependency.kind)):
			return at_dependency_fail(input.path, cstr(f"incompatible imported grammar {name}"))
	else if (dependency.kind != 1):
		# A combined grammar's vocabulary includes implicit parser literals.
		# Importing all its parser rules is not tokenVocab semantics.
		return at_dependency_fail(input.path, cstr(f"tokenVocab {name} requires a lexer grammar; combined/parser vocabularies are not supported"))
	return at_dependency_resolve(dependency)


int at_dependency_options(at_dependency_input* input, pg_ast_node* node):
	list[char*] words = at_dependency_words(pg_ast_child(node, 1).text)
	if ((words == 0) || (words.length < 2)): return 0
	int i = 1
	int complete = 1
	int token_vocab_seen = 0
	while (i < words.length - 1):
		int begin = i
		while ((i < words.length - 1) && (strcmp(words[i], c";") != 0)): i = i + 1
		if (strcmp(words[begin], c"tokenVocab") == 0):
			if (token_vocab_seen || (i - begin != 3) || (i == words.length - 1)):
				return at_dependency_fail(input.path, c"malformed or repeated tokenVocab option")
			token_vocab_seen = 1
			if ((strcmp(words[begin + 1], c"=") != 0) || (at_dependency_identifier(words[begin + 2]) == 0)):
				return at_dependency_fail(input.path, c"malformed tokenVocab option")
			if (at_dependency_edge(input, words[begin + 2], 0) == 0): complete = 0
		else:
			complete = 0
		i = i + 1
	return complete


int at_dependency_tokens(at_dependency_input* input, pg_ast_node* node):
	list[char*] words = at_dependency_words(pg_ast_child(node, 1).text)
	if ((words == 0) || (words.length < 2)): return at_dependency_fail(input.path, c"malformed tokens declaration")
	int i = 1
	while (i < words.length - 1):
		char* name = words[i]
		if ((at_dependency_identifier(name) == 0) || (name[0] < 'A') || (name[0] > 'Z')):
			return at_dependency_fail(input.path, c"tokens declaration requires uppercase token names")
		if (at_has_token_identity(name) == 0): g_at_token_identities.push(strclone(name))
		i = i + 1
		if (i < words.length - 1):
			if (strcmp(words[i], c",") != 0): return at_dependency_fail(input.path, c"unsupported tokens declaration")
			i = i + 1
	return 1


int at_dependency_resolve(at_dependency_input* input):
	if (input.state == 2): return input.failed == 0
	if (input.state == 1): return at_dependency_fail(input.path, cstr(f"dependency cycle through {input.name}"))
	int errors_before = g_at_dependency_error
	input.state = 1
	int count = pg_ast_child_count(input.root) - 1
	for i in range(count):
		pg_ast_node* inner = pg_ast_child(pg_ast_child(input.root, i), 0)
		int resolved = 0
		if (inner.kind == antlr4_ast_import_decl):
			resolved = at_dependency_edge(input, pg_ast_child(inner, 1).text, 1)
			int n = pg_ast_child_count(inner)
			int j = 2
			while (j < n - 1):
				pg_ast_node* tail = pg_ast_child(inner, j)
				if (at_dependency_edge(input, pg_ast_child(tail, 1).text, 1) == 0): resolved = 0
				j = j + 1
		else if (inner.kind == antlr4_ast_bare_marker):
			char* marker = pg_ast_child(inner, 0).text
			if (strcmp(marker, c"options") == 0): resolved = at_dependency_options(input, inner)
			else if (strcmp(marker, c"tokens") == 0): resolved = at_dependency_tokens(input, inner)
			else if (strcmp(marker, c"channels") == 0): resolved = at_dependency_channels(input, inner)
		if (resolved): g_at_resolved_sites.push(inner.first_token)
	input.state = 2
	input.failed = g_at_dependency_error != errors_before
	return input.failed == 0


# ANTLR merges root rules before depth-first imports, retaining the first
# definition. Explicit dependency arguments locate files; they do not change
# the grammar's declared import precedence. A visited set also handles diamonds.
void at_dependency_collect_order(at_dependency_input* input, map[char*, int] seen, list[at_dependency_input*] ordered):
	if (input.name in seen): return
	seen[input.name] = 1
	ordered.push(input)
	for at_dependency_input* dependency in input.imports:
		at_dependency_collect_order(dependency, seen, ordered)


list[at_rule*] at_load_grammar_inputs(list[char*] paths):
	g_at_inputs = new list[at_dependency_input*]
	g_at_resolved_sites = new list[pg_token*]
	g_at_dependency_error = 0
	g_at_dependency_cwd = cast(char*, malloc(4096))
	if (getcwd(g_at_dependency_cwd, 4096) < 0):
		at_dependency_fail(c"<inputs>", c"could not determine working directory")
		return 0
	for char* path in paths:
		if (at_dependency_load(path) == 0): return 0
	# Preloading roots lets tokenVocab find an explicitly supplied file even
	# when its path/basename differs from its declared grammar name.
	int i = 0
	while (i < g_at_inputs.length):
		at_dependency_resolve(g_at_inputs[i])
		i = i + 1
	list[at_dependency_input*] ordered = new list[at_dependency_input*]
	map[char*, int] seen = new map[char*, int]
	for at_dependency_input* input in g_at_inputs:
		if (input.imported == 0): at_dependency_collect_order(input, seen, ordered)
	# Failed cyclic components still need their retained host declarations
	# audited; resolution has already diagnosed the cycle before this walk.
	for at_dependency_input* input in g_at_inputs:
		at_dependency_collect_order(input, seen, ordered)
	list[at_rule*] all_rules = new list[at_rule*]
	for at_dependency_input* input in ordered:
		g_at_source = input.source
		list[at_rule*] rules = at_collect_rules(input.root)
		for at_rule* rule in rules: all_rules.push(rule)
	for at_site* site in g_at_dependencies:
		for pg_token* first in g_at_resolved_sites:
			if (site.first == first): site.resolved = 1
	return all_rules
