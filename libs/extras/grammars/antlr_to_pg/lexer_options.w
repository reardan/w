import libs.extras.grammars.antlr_to_pg.dependencies


map[char*, int] g_at_exact_cases
map[char*, int] g_at_exact_case_defaults


# Only fully understood option blocks are resolved. Foreign host options
# sharing the same block remain visible to strict auditing.
int at_exact_case_option(at_site* site, int* value, int allow_vocab):
	list[char*] words = at_dependency_words(site.raw)
	if ((words == 0) || (words.length < 6)):
		if (words != 0): words.free()
		return 0
	int found = 0
	int complete = 1
	int start = 0
	while ((start < words.length) && (strcmp(words[start], c"{") != 0)): start++
	start++
	while (start < words.length - 1):
		int end = start
		while ((end < words.length) && (strcmp(words[end], c";") != 0)): end++
		if ((end - start != 3) || (end >= words.length) || (strcmp(words[start + 1], c"=") != 0)):
			complete = 0
			break
		if (strcmp(words[start], c"caseInsensitive") == 0):
			if (found): complete = 0
			found = 1
			if (strcmp(words[start + 2], c"true") == 0): *value = 1
			else if (strcmp(words[start + 2], c"false") == 0): *value = 0
			else: complete = 0
		else if ((allow_vocab == 0) || (strcmp(words[start], c"tokenVocab") != 0)):
			complete = 0
		start = end + 1
	for char* word in words: free(word)
	words.free()
	if (complete && found): site.resolved = 1
	return found


void at_exact_prepare_cases(list[at_rule*] rules):
	g_at_exact_cases = new map[char*, int]
	g_at_exact_case_defaults = new map[char*, int]
	for at_site* site in g_at_dependencies:
		if ((site.first == 0) || (starts_with(site.raw, c"options") == 0)): continue
		int value = 0
		if (at_exact_case_option(site, &value, 1)): g_at_exact_case_defaults[site.first.filename] = value
	for at_rule* rule in rules:
		int value = 0
		if (rule.first != 0): value = g_at_exact_case_defaults.get(rule.first.filename, 0)
		for at_site* site in rule.options: at_exact_case_option(site, &value, 0)
		g_at_exact_cases[rule.name] = value


int at_exact_case(at_rule* rule):
	if (g_at_exact_lexer == 0): return 0
	# Normalization creates parser helpers after the original rule map.
	# Helpers retain their owner's source location and grammar option scope.
	int fallback = 0
	if (rule.first != 0): fallback = g_at_exact_case_defaults.get(rule.first.filename, 0)
	return g_at_exact_cases.get(rule.name, fallback)
