# Pure shell syntax planner: owns all strings/lists, never executes or opens files.
# Check unsupported BEFORE error and before executing ANY pipeline. Unsupported
# lines belong to the external shell in their entirety. error means status 2.
# Conditions use the last EXECUTED pipeline's status (skips do not change it),
# giving && and || equal, left-associative precedence. Pipelines bind tighter.
# Empty input is a valid empty plan. Redirection-only commands have empty text.
import lib.lib
import structures.string

struct shell_redirect:
	int fd
	int mode # 0 read, 1 truncate, 2 append, 3 duplicate
	char* path # owned, null for duplication
	int source_fd # -1 except for duplication

struct shell_command:
	char* text # owned raw shell spelling, with redirections removed
	list[shell_redirect*] redirects # source order is significant

struct shell_pipeline:
	list[shell_command*] commands
	int condition # 0 always, 1 previous success, 2 previous failure

struct shell_plan:
	list[shell_pipeline*] pipelines
	int unsupported
	int error

# Private lexer tokens: word, pipe, &&, ||, ;, redirect, newline.
struct shell_plan_token:
	int kind
	int start
	int end
	char* value
	int expansion
	int fd
	int mode

int shell_plan_space(char c):
	return (c == ' ') || (c == 9) || (c == 13)

int shell_plan_boundary(char c):
	return (c == 0) || shell_plan_space(c) || (c == 10) || (c == '|') || (c == '&') || (c == ';') || (c == '<') || (c == '>')

char* shell_plan_take(string_builder* b):
	char* s = b.data
	free(b)
	return s

# Read one word, preserving its raw span while separately dequoting its value.
# Expansions in redirect operands require whole-line fallback, whereas ordinary
# command words retain their spelling for per-command external-shell fallback.
void shell_plan_word(char* line, shell_plan_token* t, shell_plan* plan):
	int i = t.start
	int quote = 0
	string_builder* value = string_new()
	while (line[i] != 0):
		char c = line[i]
		if ((quote == 0) && shell_plan_boundary(c)): break
		if ((c == 39) && (quote != 34)):
			quote = quote == 39 ? 0 : 39
			i++
			continue
		if ((c == 34) && (quote != 39)):
			quote = quote == 34 ? 0 : 34
			i++
			continue
		if ((c == 92) && (quote != 39)):
			char next = line[i + 1]
			if (next == 0):
				plan.error = 1
				i++
				break
			if ((quote == 0) || (next == 34) || (next == 92) || (next == '$') || (next == 96) || (next == 10)):
				if (next != 10): string_append_char(value, next)
				i = i + 2
				continue
		if (quote != 39):
			if ((c == 96) || ((c == '$') && ((line[i + 1] == '(') || (line[i + 1] == '{') || (line[i + 1] == 39) || (line[i + 1] == 34)))): plan.unsupported = 1
			if ((c == '$') && ((line[i + 1] == '?') || (line[i + 1] == '!'))): plan.unsupported = 1
			if (c == '$'): t.expansion = 1
			if (quote == 0):
				if ((c == '(') || (c == ')') || (c == '{') || (c == '}')): plan.unsupported = 1
				if ((c == '*') || (c == '?') || (c == '[') || (c == '~')): t.expansion = 1
		string_append_char(value, c)
		i++
	if (quote != 0): plan.error = 1
	t.end = i
	t.value = shell_plan_take(value)

list[shell_plan_token*] shell_plan_lex(char* line, shell_plan* plan):
	list[shell_plan_token*] tokens = new list[shell_plan_token*]
	int i = 0
	while (line[i] != 0):
		if (shell_plan_space(line[i])):
			i++
			continue
		# A continuation between words is not an empty command word.
		if ((line[i] == 92) && (line[i + 1] == 10)):
			i = i + 2
			continue
		if (line[i] == '#'):
			# Let sh handle comments; operators inside the comment are not parsed.
			plan.unsupported = 1
			break
		shell_plan_token* t = new shell_plan_token()
		t.start = i
		t.kind = 0
		t.value = 0
		t.expansion = 0
		t.fd = -1
		t.mode = 0
		int j = i
		int digits = 0
		while (1):
			if ((line[j] >= '0') && (line[j] <= '9')):
				digits++
				j++
			elif ((digits > 0) && (line[j] == 92) && (line[j + 1] == 10)): j = j + 2
			else: break
		int operand_pending = 0
		if (tokens.length > 0): operand_pending = tokens[tokens.length - 1].kind == 5
		if (((line[j] == '<') || (line[j] == '>')) && ((j == i) || (operand_pending == 0))):
			if (j != i):
				if ((digits != 1) || (line[i] > '2')): plan.unsupported = 1
				t.fd = line[i] - '0'
			i = j
			char op = line[i]
			t.kind = 5
			t.mode = op == '<' ? 0 : 1
			if (t.fd < 0): t.fd = op == '<' ? 0 : 1
			i++
			if (line[i] == op):
				if (op == '<'): plan.unsupported = 1
				t.mode = 2
				i++
			if (line[i] == '&'):
				if ((op != '>') || (t.mode != 1)): plan.unsupported = 1
				t.mode = 3
				i++
			if ((line[i] == '|') || ((op == '<') && (line[i] == '>'))): plan.unsupported = 1
		elif (line[i] == '|'):
			t.kind = 1
			i++
			if (line[i] == '|'):
				t.kind = 3
				i++
			elif (line[i] == '&'): plan.unsupported = 1
		elif (line[i] == '&'):
			t.kind = 2
			i++
			if (line[i] == '&'): i++
			else: plan.unsupported = 1
		elif (line[i] == ';'):
			t.kind = 4
			i++
			if ((line[i] == ';') || (line[i] == '&')): plan.unsupported = 1
		elif (line[i] == 10):
			t.kind = 6
			i++
		else:
			shell_plan_word(line, t, plan)
			i = t.end
		if (t.kind != 0):
			int after = i
			while ((line[after] == 92) && (line[after + 1] == 10)): after = after + 2
			if ((after != i) && ((line[after] == '|') || (line[after] == '&') || (line[after] == '<') || (line[after] == '>'))): plan.unsupported = 1
		t.end = i
		tokens.push(t)
	return tokens

# Reserved syntax must not become independent commands around our operators.
int shell_plan_reserved(char* word):
	# Stateful shell syntax needs one external shell for the whole list.
	int assignment = (word[0] == '_') || ((word[0] >= 'a') && (word[0] <= 'z')) || ((word[0] >= 'A') && (word[0] <= 'Z'))
	int i = 1
	while (assignment && (word[i] != 0)):
		if (word[i] == '='): return 1
		assignment = (word[i] == '_') || ((word[i] >= 'a') && (word[i] <= 'z')) || ((word[i] >= 'A') && (word[i] <= 'Z')) || ((word[i] >= '0') && (word[i] <= '9'))
		i++
	if ((strcmp(word, c"exit") == 0) || (strcmp(word, c"exec") == 0) || (strcmp(word, c"eval") == 0) || (strcmp(word, c"set") == 0) || (strcmp(word, c"unset") == 0) || (strcmp(word, c"read") == 0) || (strcmp(word, c"umask") == 0) || (strcmp(word, c"trap") == 0) || (strcmp(word, c".") == 0) || (strcmp(word, c"alias") == 0) || (strcmp(word, c"unalias") == 0) || (strcmp(word, c"shift") == 0) || (strcmp(word, c"getopts") == 0) || (strcmp(word, c"return") == 0) || (strcmp(word, c"break") == 0) || (strcmp(word, c"continue") == 0)): return 1
	return (strcmp(word, c"if") == 0) || (strcmp(word, c"then") == 0) || (strcmp(word, c"else") == 0) || (strcmp(word, c"elif") == 0) || (strcmp(word, c"fi") == 0) || (strcmp(word, c"for") == 0) || (strcmp(word, c"while") == 0) || (strcmp(word, c"until") == 0) || (strcmp(word, c"do") == 0) || (strcmp(word, c"done") == 0) || (strcmp(word, c"case") == 0) || (strcmp(word, c"esac") == 0) || (strcmp(word, c"in") == 0) || (strcmp(word, c"!") == 0) || (strcmp(word, c"function") == 0) || (strcmp(word, c"[[") == 0) || (strcmp(word, c"time") == 0)

shell_pipeline* shell_plan_pipeline(shell_plan* plan, int condition):
	shell_pipeline* p = new shell_pipeline()
	p.commands = new list[shell_command*]
	p.condition = condition
	plan.pipelines.push(p)
	return p

shell_command* shell_plan_command(shell_pipeline* pipeline):
	shell_command* c = new shell_command()
	c.text = 0
	c.redirects = new list[shell_redirect*]
	pipeline.commands.push(c)
	return c

shell_plan* shell_plan_parse(char* line):
	shell_plan* plan = new shell_plan()
	plan.pipelines = new list[shell_pipeline*]
	plan.unsupported = 0
	plan.error = 0
	list[shell_plan_token*] tokens = shell_plan_lex(line, plan)
	int i = 0
	int condition = 0
	int need_command = 0
	shell_pipeline* pipeline = 0
	while (i < tokens.length):
		if (tokens[i].kind == 6):
			i++
			continue
		if (pipeline == 0): pipeline = shell_plan_pipeline(plan, condition)
		shell_command* command = shell_plan_command(pipeline)
		string_builder* text = string_new()
		int has_word = 0
		int has_command = 0
		int previous_end = -1
		while (i < tokens.length):
			shell_plan_token* t = tokens[i]
			if ((t.kind != 0) && (t.kind != 5)): break
			has_command = 1
			if (t.kind == 0):
				if ((has_word == 0) && shell_plan_reserved(t.value)): plan.unsupported = 1
				if (has_word):
					if (previous_end >= 0):
						for k in range(previous_end, t.start): string_append_char(text, line[k])
					else: string_append_char(text, ' ')
				for k in range(t.start, t.end): string_append_char(text, line[k])
				has_word = 1
				previous_end = t.end
				i++
				continue
			previous_end = -1
			shell_redirect* r = new shell_redirect()
			r.fd = t.fd
			r.mode = t.mode
			r.source_fd = -1
			r.path = 0
			command.redirects.push(r)
			i++
			if ((i >= tokens.length) || (tokens[i].kind != 0)):
				plan.error = 1
				continue
			shell_plan_token* operand = tokens[i]
			if (operand.expansion): plan.unsupported = 1
			if (r.mode == 3):
				if ((strcmp(operand.value, c"1") == 0) && (r.fd == 2)): r.source_fd = 1
				elif ((strcmp(operand.value, c"2") == 0) && (r.fd == 1)): r.source_fd = 2
				else: plan.unsupported = 1
			else:
				r.path = operand.value
				operand.value = 0
			i++
		command.text = shell_plan_take(text)
		if (has_command == 0): plan.error = 1
		need_command = 0
		if (i >= tokens.length): break
		int kind = tokens[i].kind
		i++
		if (kind == 1): need_command = 1
		else:
			pipeline = 0
			condition = 0
			if ((kind == 2) || (kind == 3)):
				condition = kind == 2 ? 1 : 2
				need_command = 1
	if (need_command): plan.error = 1
	for t in tokens:
		free(t.value)
		free(t)
	__w_list_free(cast(__w_list*, tokens))
	return plan

void shell_plan_free(shell_plan* plan):
	if (plan == 0): return
	for pipeline in plan.pipelines:
		for command in pipeline.commands:
			free(command.text)
			for redirect in command.redirects:
				free(redirect.path)
				free(redirect)
			__w_list_free(cast(__w_list*, command.redirects))
			free(command)
		__w_list_free(cast(__w_list*, pipeline.commands))
		free(pipeline)
	__w_list_free(cast(__w_list*, plan.pipelines))
	free(plan)
