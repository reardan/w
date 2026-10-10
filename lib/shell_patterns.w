# Pure validators shared by the native tools and shell translator.
# find -name supports literals, '*' and '?' (including dotfiles).
# Bracket classes and escapes deliberately fall back to external find.
import lib.regex
import structures.string

int shell_glob_valid(char* pattern):
	for i in range(strlen(pattern)):
		if ((pattern[i] == '[') || (pattern[i] == ']') || (pattern[i] == 92)): return 0
	return 1


int shell_glob_match(char* pattern, char* text):
	int p = 0
	int t = 0
	int star = -1
	int retry = 0
	while (text[t] != 0):
		if ((pattern[p] == '?') || ((pattern[p] != '*') && (pattern[p] == text[t]))):
			p++
			t++
		elif (pattern[p] == '*'):
			star = p
			p++
			retry = t
		elif (star >= 0):
			p = star + 1
			retry++
			t = retry
		else: return 0
	while (pattern[p] == '*'): p++
	return pattern[p] == 0


# sed subset: one p, d or s/pattern/replacement/[g] command; '/' is
# the only delimiter. Nonempty BRE pattern: literals, dot, anchors,
# classes and '*'. Reject escapes and +/? rather than giving them
# the regex engine's different meanings. No addresses, groups, script
# lists, backreferences or flags other than g. Replacement supports &
# for the complete match; escapes deliberately fall back.
# Returned fields are owned; null means unsupported syntax.
list[char*] shell_sed_parse(char* script):
	list[char*] parts = new list[char*]
	if ((strcmp(script, c"p") == 0) || (strcmp(script, c"d") == 0)):
		parts.push(strclone(script))
		return parts
	int n = strlen(script)
	for i in range(n):
		if (script[i] == 10):
			__w_list_free(cast(__w_list*, parts))
			return 0
	int slashes = 0
	int first = -1
	int second = -1
	if ((n >= 5) && (script[0] == 's') && (script[1] == '/')):
		for i in range(2, n):
			if (script[i] == '/'):
				slashes++
				if (first < 0): first = i
				elif (second < 0): second = i
				else: second = -2
		if ((slashes == 2) && (first > 2) && (second > first)):
			if ((second == n - 1) || ((second == n - 2) && (script[n - 1] == 'g'))):
				char* pattern = strclone(script + 2)
				pattern[first - 2] = 0
				char* replacement = strclone(script + first + 1)
				replacement[second - first - 1] = 0
				int valid = regex_valid(pattern)
				for j in range(strlen(pattern)):
					char ch = pattern[j]
					if ((ch == 92) || (ch == '+') || (ch == '?')): valid = 0
					# POSIX named/collating/equivalence classes unsupported.
					if ((ch == '[') && ((pattern[j + 1] == ':') || (pattern[j + 1] == '.') || (pattern[j + 1] == '='))): valid = 0
				for j in range(strlen(replacement)):
					if ((replacement[j] == 92) || (replacement[j] == 10)): valid = 0
				if (valid):
					parts.push(pattern)
					parts.push(replacement)
					parts.push(strclone(script + second + 1))
					return parts
				free(pattern)
				free(replacement)
	__w_list_free(cast(__w_list*, parts))
	return 0


void shell_sed_parts_free(list[char*] parts):
	if (parts == 0): return
	for part in parts: free(part)
	__w_list_free(cast(__w_list*, parts))
