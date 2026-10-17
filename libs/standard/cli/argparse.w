# libs.standard.cli.argparse: declared command-line parsing with typed
# options, positionals with arity, subcommands, generated --help text
# and usage errors (Python's argparse, P2.4 of
# docs/projects/stdlib_python_parity.md; plan:
# libs/standard/plans/10_cli_ui_devtools.md).
#
# lib/args.w stays the seed-safe "guess from the shape of argv" helper;
# this module declares every argument up front, so a flag never swallows
# a positional and every mistake becomes a precise error message.
#
# Declaring (each add_* returns the arg_spec* for the setters below):
#   arg_parser* argparse_new(char* prog)
#   void argparse_description(p, text) / argparse_epilog(p, text)
#   void argparse_disable_help(p)       drop the automatic -h/--help
#   argparse_add_flag(p, names, help)             bool, store_true
#   argparse_add_count(p, names, help)            -vvv counts
#   argparse_add_option(p, names, metavar, help)  string value
#   argparse_add_int / argparse_add_float(p, names, metavar, help)
#   argparse_add_list(p, names, metavar, help)    append, repeatable
#   argparse_add_positional(p, name, help)        exactly one value
#   argparse_add_positional_nargs(p, name, nargs, help)
#       nargs: ARGPARSE_ONE, ARGPARSE_OPTIONAL ("?"),
#              ARGPARSE_ZERO_OR_MORE ("*"), ARGPARSE_ONE_OR_MORE ("+")
#   argparse_add_subcommand(p, name, child)       child's description is
#       its help line; p owns child afterwards
#   argparse_subcommand_optional(p)               command may be omitted
#   names is "-v", "--verbose" or both comma separated: "-v, --verbose".
#   The value's name (dest) is the first long name without dashes, with
#   '-' turned into '_' (--dry-run -> dry_run), else the short name.
# Setters: argparse_arg_required(a), argparse_arg_default(a, text),
#   argparse_arg_metavar(a, text), argparse_arg_choices(a, "a,b,c"),
#   argparse_arg_type(a, ARGPARSE_INT / ARGPARSE_FLOAT / ARGPARSE_STRING)
#   (the element type of a list or positional), argparse_arg_dest(a, d).
#   A default is text converted like a command-line value; a list or
#   multi-value positional default is split on commas.
#
# Parsing never exits: it returns an arg_namespace* whose .error is a
# malloc'd message ("argument --count: invalid int value: 'x'") or 0,
# and whose .help is 1 when -h/--help was given (parsing stops there).
#   arg_namespace* argparse_parse(p, argc, argv)   argv[0] is skipped
#   arg_namespace* argparse_parse_list(p, list[char*] args)  no prog name
#   arg_namespace* argparse_parse_args(p)          from lib.args' argv
#   arg_namespace* argparse_parse_or_exit(p, argc, argv)  prints help
#       (exit 0) or usage + "prog: error: ..." to stderr (exit 2)
#   char* argparse_help(p), argparse_usage(p)      malloc'd text
#   char* argparse_error_text(ns)                  usage + error lines
#   char* argparse_help_for(ns)       help of the (sub)parser that ran
# Reading (looks in the subcommand's namespace too, like Python's flat
# namespace; an unknown name is a programming error and exits 1):
#   char* argparse_get(ns, name)        last value, default, or 0
#   int argparse_get_int(ns, name)      ints and counts
#   float argparse_get_float(ns, name)
#   int argparse_get_bool(ns, name)
#   list[char*] argparse_get_list(ns, name)  all values (owned by ns)
#   int argparse_is_set(ns, name)       times given on the command line
#   char* argparse_command(ns)          chosen subcommand or 0
#   arg_namespace* argparse_subnamespace(ns)
#   void argparse_namespace_free(ns), argparse_free(p)
#
# Syntax accepted: -v, --verbose, --name=value, --name value, -nvalue,
# -n=value, combined short flags -abc (a value-taking letter ends the
# group: -vofile), unique long prefixes (--verb for --verbose), and --
# (everything after it is positional). Options and positionals may be
# interleaved; options of a parser must come before its subcommand.
# Tokens that look like negative numbers (-5, -1.5) are values, never
# options. Not supported: help-text wrapping (lines are not reflowed),
# mutually exclusive groups, custom actions.
import lib.lib
import lib.args
import lib.format


enum argparse_type:
	ARGPARSE_STRING
	ARGPARSE_INT
	ARGPARSE_FLOAT
	ARGPARSE_BOOL
	ARGPARSE_LIST
	ARGPARSE_COUNT
	ARGPARSE_HELP


enum argparse_arity:
	ARGPARSE_ONE
	ARGPARSE_OPTIONAL
	ARGPARSE_ZERO_OR_MORE
	ARGPARSE_ONE_OR_MORE


struct arg_spec:
	char* dest
	list[char*] flags    # "-v", "--verbose"; empty for a positional
	int kind             # argparse_type
	int elem             # value type: STRING, INT or FLOAT
	int positional
	int nargs            # argparse_arity (positionals)
	int required
	int disabled         # the -h spec after argparse_disable_help
	char* default_text
	char* metavar
	char* help
	list[char*] choices  # 0 when unrestricted


struct arg_parser:
	char* prog
	char* description
	char* epilog
	list[arg_spec*] args
	list[char*] command_names
	list[arg_parser*] commands
	int command_optional


struct arg_value:
	int count
	list[char*] items


struct arg_namespace:
	arg_parser* parser
	list[arg_value*] values
	char* error
	int help
	arg_parser* report       # parser whose usage/help the error or help is about
	char* command
	arg_namespace* sub


# ---------------------------------------------------------------- text

struct ap_buf:
	char* data
	int len
	int cap


ap_buf* ap_buf_new():
	ap_buf* b = new ap_buf(cap: 64)
	b.data = cast(char*, malloc(64))
	b.data[0] = 0
	return b


void ap_buf_addn(ap_buf* b, char* s, int n):
	if (b.len + n + 1 > b.cap):
		int cap = b.cap * 2
		while (b.len + n + 1 > cap): cap = cap * 2
		b.data = realloc(b.data, b.cap, cap)
		b.cap = cap
	int i = 0
	while (i < n):
		b.data[b.len + i] = s[i]
		i = i + 1
	b.len = b.len + n
	b.data[b.len] = 0


void ap_buf_add(ap_buf* b, char* s):
	ap_buf_addn(b, s, strlen(s))


void ap_buf_addc(ap_buf* b, int c):
	char[2] one
	one[0] = cast(char, c)
	ap_buf_addn(b, &one[0], 1)


void ap_buf_spaces(ap_buf* b, int n):
	while (n > 0):
		ap_buf_addc(b, ' ')
		n = n - 1


# Releases the buffer struct and hands back its malloc'd text.
char* ap_buf_take(ap_buf* b):
	char* s = b.data
	free(b)
	return s


int ap_streq(char* a, char* b):
	return strcmp(a, b) == 0


char* ap_substr(char* s, int start, int end):
	char* r = cast(char*, malloc(end - start + 1))
	int i = 0
	while (start + i < end):
		r[i] = s[start + i]
		i = i + 1
	r[i] = 0
	return r


# Index of the first c in s, or -1.
int ap_find_char(char* s, int c):
	int i = 0
	while (s[i]):
		if (s[i] == c): return i
		i = i + 1
	return -1


void ap_fatal(char* what, char* name):
	char* m = c"argparse: "
	write(2, m, strlen(m))
	write(2, what, strlen(what))
	if (name):
		write(2, c" '", 2)
		write(2, name, strlen(name))
		write(2, c"'", 1)
	write(2, c"\n", 1)
	exit(1)


# Splits s on commas, trimming spaces around each piece; malloc'd items.
list[char*] ap_split_commas(char* s):
	list[char*] out = new list[char*]
	int start = 0
	int i = 0
	while (1):
		if (s[i] == ',' || s[i] == 0):
			int a = start
			int e = i
			while (a < e && s[a] == ' '): a = a + 1
			while (e > a && s[e - 1] == ' '): e = e - 1
			out.push(ap_substr(s, a, e))
			if (s[i] == 0): break
			start = i + 1
		i = i + 1
	return out


void ap_free_strings(list[char*] l):
	if (l == 0): return
	for char* s in l: free(s)
	l.free()


# ---------------------------------------------------------- conversion

# Python int(): optional sign, decimal digits, '_' between digits;
# surrounding spaces allowed. 1 on success with *out set.
int ap_parse_int(char* s, int* out):
	int i = 0
	while (s[i] == ' '): i = i + 1
	int neg = 0
	if (s[i] == '+' || s[i] == '-'):
		neg = s[i] == '-'
		i = i + 1
	int v = 0
	int digits = 0
	int limit = 0
	limit = ~limit
	limit = cast(int, cast(uint, limit) >> 1)
	while (1):
		int c = s[i]
		if (c == '_' && digits > 0 && s[i + 1] >= '0' && s[i + 1] <= '9'):
			i = i + 1
			continue
		if (c < '0' || c > '9'): break
		int d = c - '0'
		if (v > (limit - d) / 10): return 0
		v = v * 10 + d
		digits = digits + 1
		i = i + 1
	while (s[i] == ' '): i = i + 1
	if (digits == 0 || s[i] != 0): return 0
	if (neg): v = -v
	*out = v
	return 1


int ap_parse_float(char* s, float* out):
	int consumed = 0
	float f = parse_float(s, &consumed)
	if (consumed == 0 || consumed != strlen(s)): return 0
	*out = f
	return 1


int ap_truthy(char* s):
	if (s == 0): return 0
	return ap_streq(s, c"1") || ap_streq(s, c"true") || ap_streq(s, c"True") || ap_streq(s, c"yes") || ap_streq(s, c"on")


# "-5", "-1.5", "-.5": negative numbers are values, not options.
int ap_is_negative_number(char* t):
	if (t[0] != '-'): return 0
	int i = 1
	int digits = 0
	while ((t[i] >= '0' && t[i] <= '9') || t[i] == '.' || t[i] == 'e' || t[i] == 'E' || t[i] == '_'):
		if (t[i] >= '0' && t[i] <= '9'): digits = digits + 1
		i = i + 1
	return digits > 0 && t[i] == 0


int ap_looks_optional(char* t):
	if (t[0] != '-' || t[1] == 0): return 0
	return !ap_is_negative_number(t)


# ---------------------------------------------------------- declaring

arg_spec* ap_spec_new(char* help):
	arg_spec* a = new arg_spec()
	a.dest = 0
	a.flags = new list[char*]
	a.kind = ARGPARSE_STRING
	a.elem = ARGPARSE_STRING
	a.positional = 0
	a.nargs = ARGPARSE_ONE
	a.required = 0
	a.disabled = 0
	a.default_text = 0
	a.metavar = 0
	a.help = 0
	if (help): a.help = strclone(help)
	a.choices = 0
	return a


void ap_spec_free(arg_spec* a):
	free(a.dest)
	ap_free_strings(a.flags)
	free(a.default_text)
	free(a.metavar)
	free(a.help)
	ap_free_strings(a.choices)
	free(a)


arg_spec* ap_find_dest(arg_parser* p, char* dest):
	for arg_spec* a in p.args:
		if (!a.disabled && ap_streq(a.dest, dest)): return a
	return 0


arg_spec* ap_find_flag(arg_parser* p, char* flag):
	for arg_spec* a in p.args:
		if (a.disabled): continue
		for char* f in a.flags:
			if (ap_streq(f, flag)): return a
	return 0


int ap_has_flag_named(arg_parser* p, char* flag):
	return ap_find_flag(p, flag) != 0


# Dest from the flags: first long name ('-' -> '_'), else first short.
char* ap_dest_from_flags(list[char*] flags):
	for char* f in flags:
		if (f[1] == '-'):
			char* d = strclone(&f[2])
			int i = 0
			while (d[i]):
				if (d[i] == '-'): d[i] = '_'
				i = i + 1
			return d
	return strclone(&flags[0][1])


arg_spec* ap_add(arg_parser* p, arg_spec* a):
	for arg_spec* b in p.args:
		if (!b.disabled && ap_streq(b.dest, a.dest)): ap_fatal(c"duplicate argument", a.dest)
	for char* f in a.flags:
		if (ap_has_flag_named(p, f)): ap_fatal(c"duplicate option", f)
	p.args.push(a)
	return a


arg_spec* ap_add_option_kind(arg_parser* p, char* names, int kind, char* metavar, char* help):
	arg_spec* a = ap_spec_new(help)
	a.kind = kind
	list[char*] parts = ap_split_commas(names)
	for char* f in parts:
		if (f[0] != '-' || f[1] == 0 || ap_streq(f, c"--") || ap_is_negative_number(f)):
			ap_fatal(c"option names must start with '-':", f)
		a.flags.push(f)
	parts.free()
	a.dest = ap_dest_from_flags(a.flags)
	if (kind == ARGPARSE_INT || kind == ARGPARSE_FLOAT): a.elem = kind
	if (metavar): a.metavar = strclone(metavar)
	return ap_add(p, a)


arg_parser* argparse_new(char* prog):
	arg_parser* p = new arg_parser()
	p.prog = strclone(prog)
	p.description = 0
	p.epilog = 0
	p.args = new list[arg_spec*]
	p.command_names = new list[char*]
	p.commands = new list[arg_parser*]
	p.command_optional = 0
	ap_add_option_kind(p, c"-h, --help", ARGPARSE_HELP, 0, c"show this help message and exit")
	return p


void argparse_free(arg_parser* p):
	if (p == 0): return
	free(p.prog)
	free(p.description)
	free(p.epilog)
	for arg_spec* a in p.args: ap_spec_free(a)
	p.args.free()
	ap_free_strings(p.command_names)
	for arg_parser* c in p.commands: argparse_free(c)
	p.commands.free()
	free(p)


void argparse_description(arg_parser* p, char* text):
	free(p.description)
	p.description = strclone(text)


void argparse_epilog(arg_parser* p, char* text):
	free(p.epilog)
	p.epilog = strclone(text)


void argparse_disable_help(arg_parser* p):
	arg_spec* h = ap_find_dest(p, c"help")
	if (h && h.kind == ARGPARSE_HELP): h.disabled = 1


arg_spec* argparse_add_flag(arg_parser* p, char* names, char* help):
	return ap_add_option_kind(p, names, ARGPARSE_BOOL, 0, help)


arg_spec* argparse_add_count(arg_parser* p, char* names, char* help):
	return ap_add_option_kind(p, names, ARGPARSE_COUNT, 0, help)


arg_spec* argparse_add_option(arg_parser* p, char* names, char* metavar, char* help):
	return ap_add_option_kind(p, names, ARGPARSE_STRING, metavar, help)


arg_spec* argparse_add_int(arg_parser* p, char* names, char* metavar, char* help):
	return ap_add_option_kind(p, names, ARGPARSE_INT, metavar, help)


arg_spec* argparse_add_float(arg_parser* p, char* names, char* metavar, char* help):
	return ap_add_option_kind(p, names, ARGPARSE_FLOAT, metavar, help)


arg_spec* argparse_add_list(arg_parser* p, char* names, char* metavar, char* help):
	return ap_add_option_kind(p, names, ARGPARSE_LIST, metavar, help)


arg_spec* argparse_add_positional_nargs(arg_parser* p, char* name, int nargs, char* help):
	if (name[0] == '-'): ap_fatal(c"positional names must not start with '-':", name)
	if (nargs < ARGPARSE_ONE || nargs > ARGPARSE_ONE_OR_MORE): ap_fatal(c"bad nargs for", name)
	if (p.commands.length > 0 && nargs != ARGPARSE_ONE): ap_fatal(c"a parser with subcommands takes only single positionals:", name)
	arg_spec* a = ap_spec_new(help)
	a.dest = strclone(name)
	a.positional = 1
	a.nargs = nargs
	if (nargs == ARGPARSE_ZERO_OR_MORE || nargs == ARGPARSE_ONE_OR_MORE): a.kind = ARGPARSE_LIST
	a.required = nargs == ARGPARSE_ONE || nargs == ARGPARSE_ONE_OR_MORE
	return ap_add(p, a)


arg_spec* argparse_add_positional(arg_parser* p, char* name, char* help):
	return argparse_add_positional_nargs(p, name, ARGPARSE_ONE, help)


void argparse_add_subcommand(arg_parser* p, char* name, arg_parser* child):
	for arg_spec* a in p.args:
		if (a.positional && a.nargs != ARGPARSE_ONE): ap_fatal(c"a parser with subcommands takes only single positionals:", a.dest)
	for char* n in p.command_names:
		if (ap_streq(n, name)): ap_fatal(c"duplicate subcommand", name)
	# The child's usage reads "prog name ...".
	ap_buf* b = ap_buf_new()
	ap_buf_add(b, p.prog)
	ap_buf_addc(b, ' ')
	ap_buf_add(b, name)
	free(child.prog)
	child.prog = ap_buf_take(b)
	p.command_names.push(strclone(name))
	p.commands.push(child)


void argparse_subcommand_optional(arg_parser* p):
	p.command_optional = 1


void argparse_arg_required(arg_spec* a):
	if (a.kind == ARGPARSE_HELP): ap_fatal(c"cannot require", a.dest)
	a.required = 1


void argparse_arg_default(arg_spec* a, char* text):
	free(a.default_text)
	a.default_text = strclone(text)
	# A positional with a default may be omitted (Python needs nargs="?").
	if (a.positional && a.nargs == ARGPARSE_ONE): a.nargs = ARGPARSE_OPTIONAL
	if (a.positional): a.required = a.nargs == ARGPARSE_ONE_OR_MORE


void argparse_arg_metavar(arg_spec* a, char* text):
	free(a.metavar)
	a.metavar = strclone(text)


void argparse_arg_choices(arg_spec* a, char* csv):
	ap_free_strings(a.choices)
	a.choices = ap_split_commas(csv)


void argparse_arg_dest(arg_spec* a, char* dest):
	free(a.dest)
	a.dest = strclone(dest)


void argparse_arg_type(arg_spec* a, int t):
	if (t != ARGPARSE_STRING && t != ARGPARSE_INT && t != ARGPARSE_FLOAT): ap_fatal(c"argparse_arg_type takes STRING, INT or FLOAT for", a.dest)
	if (a.kind == ARGPARSE_BOOL || a.kind == ARGPARSE_COUNT || a.kind == ARGPARSE_HELP): ap_fatal(c"flags take no value type:", a.dest)
	a.elem = t
	if (a.kind != ARGPARSE_LIST): a.kind = t


int ap_takes_value(arg_spec* a):
	return a.kind == ARGPARSE_STRING || a.kind == ARGPARSE_INT || a.kind == ARGPARSE_FLOAT || a.kind == ARGPARSE_LIST


# ----------------------------------------------------------- rendering

# "-c/--count" for options, the dest for positionals (error messages).
char* ap_display(arg_spec* a):
	if (a.positional): return strclone(a.dest)
	ap_buf* b = ap_buf_new()
	int first = 1
	for char* f in a.flags:
		if (!first): ap_buf_addc(b, '/')
		ap_buf_add(b, f)
		first = 0
	return ap_buf_take(b)


void ap_add_metavar(ap_buf* b, arg_spec* a):
	if (a.metavar):
		ap_buf_add(b, a.metavar)
		return
	if (a.positional):
		ap_buf_add(b, a.dest)
		return
	int i = 0
	while (a.dest[i]):
		int c = a.dest[i]
		if (c >= 'a' && c <= 'z'): c = c - 32
		ap_buf_addc(b, c)
		i = i + 1


# "{build,test}"
void ap_add_command_choices(ap_buf* b, arg_parser* p):
	ap_buf_addc(b, '{')
	int first = 1
	for char* n in p.command_names:
		if (!first): ap_buf_addc(b, ',')
		ap_buf_add(b, n)
		first = 0
	ap_buf_addc(b, '}')


void ap_add_positional_usage(ap_buf* b, arg_spec* a):
	if (a.nargs == ARGPARSE_ONE):
		ap_add_metavar(b, a)
	elif (a.nargs == ARGPARSE_OPTIONAL):
		ap_buf_addc(b, '[')
		ap_add_metavar(b, a)
		ap_buf_addc(b, ']')
	elif (a.nargs == ARGPARSE_ZERO_OR_MORE):
		ap_buf_addc(b, '[')
		ap_add_metavar(b, a)
		ap_buf_add(b, c" ...]")
	else:
		ap_add_metavar(b, a)
		ap_buf_add(b, c" [")
		ap_add_metavar(b, a)
		ap_buf_add(b, c" ...]")


void ap_add_usage_body(ap_buf* b, arg_parser* p):
	ap_buf_add(b, p.prog)
	for arg_spec* a in p.args:
		if (a.disabled || a.positional): continue
		ap_buf_addc(b, ' ')
		if (!a.required): ap_buf_addc(b, '[')
		ap_buf_add(b, a.flags[0])
		if (ap_takes_value(a)):
			ap_buf_addc(b, ' ')
			ap_add_metavar(b, a)
		if (!a.required): ap_buf_addc(b, ']')
	for arg_spec* a in p.args:
		if (a.disabled || !a.positional): continue
		ap_buf_addc(b, ' ')
		ap_add_positional_usage(b, a)
	if (p.commands.length > 0):
		ap_buf_addc(b, ' ')
		ap_add_command_choices(b, p)
		ap_buf_add(b, c" ...")


# "usage: prog [-h] ...\n"
char* argparse_usage(arg_parser* p):
	ap_buf* b = ap_buf_new()
	ap_buf_add(b, c"usage: ")
	ap_add_usage_body(b, p)
	ap_buf_addc(b, '\n')
	return ap_buf_take(b)


# The left column of a help line: "-c, --count N" or "file".
char* ap_invocation(arg_spec* a):
	ap_buf* b = ap_buf_new()
	if (a.positional):
		ap_add_metavar(b, a)
		return ap_buf_take(b)
	int first = 1
	for char* f in a.flags:
		if (!first): ap_buf_add(b, c", ")
		ap_buf_add(b, f)
		first = 0
	if (ap_takes_value(a)):
		ap_buf_addc(b, ' ')
		ap_add_metavar(b, a)
	return ap_buf_take(b)


void ap_help_line(ap_buf* b, int indent, char* inv, char* help, int column):
	ap_buf_spaces(b, indent)
	ap_buf_add(b, inv)
	if (help == 0):
		ap_buf_addc(b, '\n')
		return
	int used = indent + strlen(inv)
	if (used <= column - 2):
		ap_buf_spaces(b, column - used)
	else:
		ap_buf_addc(b, '\n')
		ap_buf_spaces(b, column)
	ap_buf_add(b, help)
	ap_buf_addc(b, '\n')


# The child's help line: its description up to the first newline.
char* ap_command_help(arg_parser* c):
	if (c.description == 0): return 0
	int nl = ap_find_char(c.description, '\n')
	if (nl < 0): return strclone(c.description)
	return ap_substr(c.description, 0, nl)


# Python's HelpFormatter layout without reflowing: help text starts at
# column min(longest invocation + 2 + 2, 24); a longer invocation puts
# its help on the next line.
char* argparse_help(arg_parser* p):
	int widest = 0
	int has_pos = 0
	int has_opt = 0
	for arg_spec* a in p.args:
		if (a.disabled): continue
		char* inv = ap_invocation(a)
		if (strlen(inv) + 2 > widest): widest = strlen(inv) + 2
		free(inv)
		if (a.positional): has_pos = 1
		else: has_opt = 1
	if (p.commands.length > 0):
		has_pos = 1
		ap_buf* cb = ap_buf_new()
		ap_add_command_choices(cb, p)
		if (cb.len + 2 > widest): widest = cb.len + 2
		free(ap_buf_take(cb))
		for char* n in p.command_names:
			if (strlen(n) + 4 > widest): widest = strlen(n) + 4
	int column = widest + 2
	if (column > 24): column = 24

	ap_buf* b = ap_buf_new()
	char* usage = argparse_usage(p)
	ap_buf_add(b, usage)
	free(usage)
	if (p.description):
		ap_buf_addc(b, '\n')
		ap_buf_add(b, p.description)
		ap_buf_addc(b, '\n')
	if (has_pos):
		ap_buf_add(b, c"\npositional arguments:\n")
		for arg_spec* a in p.args:
			if (a.disabled || !a.positional): continue
			char* inv = ap_invocation(a)
			ap_help_line(b, 2, inv, a.help, column)
			free(inv)
		if (p.commands.length > 0):
			ap_buf* cb = ap_buf_new()
			ap_add_command_choices(cb, p)
			char* choices = ap_buf_take(cb)
			ap_help_line(b, 2, choices, 0, column)
			free(choices)
			for int i in range(p.commands.length):
				char* h = ap_command_help(p.commands[i])
				ap_help_line(b, 4, p.command_names[i], h, column)
				free(h)
	if (has_opt):
		ap_buf_add(b, c"\noptions:\n")
		for arg_spec* a in p.args:
			if (a.disabled || a.positional): continue
			char* inv = ap_invocation(a)
			ap_help_line(b, 2, inv, a.help, column)
			free(inv)
	if (p.epilog):
		ap_buf_addc(b, '\n')
		ap_buf_add(b, p.epilog)
		ap_buf_addc(b, '\n')
	return ap_buf_take(b)


# ------------------------------------------------------------- parsing

arg_namespace* ap_namespace_new(arg_parser* p):
	arg_namespace* ns = new arg_namespace()
	ns.parser = p
	ns.values = new list[arg_value*]
	for int i in range(p.args.length):
		arg_value* v = new arg_value()
		v.count = 0
		v.items = new list[char*]
		ns.values.push(v)
	ns.error = 0
	ns.help = 0
	ns.report = p
	ns.command = 0
	ns.sub = 0
	return ns


void argparse_namespace_free(arg_namespace* ns):
	if (ns == 0): return
	for arg_value* v in ns.values:
		ap_free_strings(v.items)
		free(v)
	ns.values.free()
	free(ns.error)
	free(ns.command)
	argparse_namespace_free(ns.sub)
	free(ns)


arg_value* ap_value_of(arg_namespace* ns, arg_spec* a):
	for int i in range(ns.parser.args.length):
		if (ns.parser.args[i] == a): return ns.values[i]
	return 0


# Sets ns.error to "argument <display>: <what> '<value>'<tail>"; returns -1.
int ap_arg_error(arg_namespace* ns, arg_spec* a, char* what, char* value, char* tail):
	ap_buf* b = ap_buf_new()
	ap_buf_add(b, c"argument ")
	char* d = ap_display(a)
	ap_buf_add(b, d)
	free(d)
	ap_buf_add(b, c": ")
	ap_buf_add(b, what)
	if (value):
		ap_buf_add(b, c" '")
		ap_buf_add(b, value)
		ap_buf_addc(b, '\'')
	if (tail): ap_buf_add(b, tail)
	free(ns.error)
	ns.error = ap_buf_take(b)
	return -1


int ap_error(arg_namespace* ns, char* message):
	free(ns.error)
	ns.error = strclone(message)
	return -1


# Type and choices check of one value; 0 when fine, -1 with ns.error.
int ap_check_value(arg_namespace* ns, arg_spec* a, char* v):
	if (a.elem == ARGPARSE_INT):
		int n = 0
		if (!ap_parse_int(v, &n)): return ap_arg_error(ns, a, c"invalid int value:", v, 0)
	elif (a.elem == ARGPARSE_FLOAT):
		float f = 0.0
		if (!ap_parse_float(v, &f)): return ap_arg_error(ns, a, c"invalid float value:", v, 0)
	if (a.choices):
		for char* c in a.choices:
			if (ap_streq(c, v)): return 0
		ap_buf* t = ap_buf_new()
		ap_buf_add(t, c" (choose from ")
		int first = 1
		for char* c in a.choices:
			if (!first): ap_buf_add(t, c", ")
			ap_buf_add(t, c)
			first = 0
		ap_buf_addc(t, ')')
		char* tail = ap_buf_take(t)
		ap_arg_error(ns, a, c"invalid choice:", v, tail)
		free(tail)
		return -1
	return 0


# Records one value (a list appends, anything else keeps the last).
int ap_store(arg_namespace* ns, arg_spec* a, char* v):
	if (ap_check_value(ns, a, v) < 0): return -1
	arg_value* val = ap_value_of(ns, a)
	if (a.kind != ARGPARSE_LIST && !a.positional):
		ap_free_strings(val.items)
		val.items = new list[char*]
	val.items.push(strclone(v))
	val.count = val.count + 1
	return 0


# Applies option a. explicit is the inline value (after '=' or glued to a
# short flag) or 0. Returns the next token index, or -1 with ns.error.
int ap_apply(arg_parser* p, arg_namespace* ns, arg_spec* a, char* explicit, list[char*] toks, int next):
	if (a.kind == ARGPARSE_HELP):
		ns.help = 1
		ns.report = p
		return toks.length
	if (!ap_takes_value(a)):
		if (explicit): return ap_arg_error(ns, a, c"ignored explicit argument", explicit, 0)
		arg_value* val = ap_value_of(ns, a)
		val.count = val.count + 1
		return next
	if (explicit):
		if (ap_store(ns, a, explicit) < 0): return -1
		return next
	if (next >= toks.length || ap_looks_optional(toks[next]) || ap_streq(toks[next], c"--")):
		return ap_arg_error(ns, a, c"expected one argument", 0, 0)
	if (ap_store(ns, a, toks[next]) < 0): return -1
	return next + 1


# Long option lookup: exact, else a unique prefix of one long flag.
arg_spec* ap_match_long(arg_parser* p, arg_namespace* ns, char* name, int* ambiguous):
	arg_spec* exact = ap_find_flag(p, name)
	if (exact): return exact
	arg_spec* found = 0
	ap_buf* names = ap_buf_new()
	int matches = 0
	for arg_spec* a in p.args:
		if (a.disabled): continue
		for char* f in a.flags:
			if (f[1] == '-' && starts_with(f, name)):
				if (matches > 0): ap_buf_add(names, c", ")
				ap_buf_add(names, f)
				matches = matches + 1
				found = a
	char* listed = ap_buf_take(names)
	if (matches > 1):
		ap_buf* b = ap_buf_new()
		ap_buf_add(b, c"ambiguous option: ")
		ap_buf_add(b, name)
		ap_buf_add(b, c" could match ")
		ap_buf_add(b, listed)
		free(ns.error)
		ns.error = ap_buf_take(b)
		*ambiguous = 1
		found = 0
	free(listed)
	return found


# Handles the option token toks[i]; unknown options go to extras.
# Returns the next index or -1 with ns.error set.
int ap_take_option(arg_parser* p, arg_namespace* ns, list[char*] toks, int i, list[char*] extras):
	char* t = toks[i]
	int eq = ap_find_char(t, '=')
	if (t[1] == '-'):
		char* name = t
		if (eq >= 0): name = ap_substr(t, 0, eq)
		int ambiguous = 0
		arg_spec* a = ap_match_long(p, ns, name, &ambiguous)
		if (eq >= 0): free(name)
		if (ambiguous): return -1
		if (a == 0):
			extras.push(t)
			return i + 1
		char* explicit = 0
		if (eq >= 0): explicit = &t[eq + 1]
		return ap_apply(p, ns, a, explicit, toks, i + 1)
	arg_spec* whole = ap_find_flag(p, t)
	if (whole): return ap_apply(p, ns, whole, 0, toks, i + 1)
	if (eq >= 0):
		char* name = ap_substr(t, 0, eq)
		arg_spec* a = ap_find_flag(p, name)
		free(name)
		if (a): return ap_apply(p, ns, a, &t[eq + 1], toks, i + 1)
	# Combined short flags: -abc, -vofile.
	char[3] one
	one[0] = '-'
	one[2] = 0
	int j = 1
	arg_spec* prev = 0
	while (t[j]):
		one[1] = t[j]
		arg_spec* a = ap_find_flag(p, &one[0])
		if (a == 0):
			if (j == 1):
				extras.push(t)
				return i + 1
			return ap_arg_error(ns, prev, c"ignored explicit argument", &t[j], 0)
		if (ap_takes_value(a)):
			char* rest = &t[j + 1]
			if (rest[0] == '='): rest = &rest[1]
			if (t[j + 1] == 0): rest = 0
			return ap_apply(p, ns, a, rest, toks, i + 1)
		int r = ap_apply(p, ns, a, 0, toks, i + 1)
		if (r < 0 || ns.help): return r
		prev = a
		j = j + 1
	return i + 1


int ap_min_count(arg_spec* a):
	if (a.nargs == ARGPARSE_ONE || a.nargs == ARGPARSE_ONE_OR_MORE): return 1
	return 0


# Python's greedy positional matching: each positional takes as many
# tokens as it can while leaving the minimum the later ones need.
# Tokens left over join extras; returns -1 on a bad value.
int ap_assign_positionals(arg_parser* p, arg_namespace* ns, list[char*] pos, list[char*] extras):
	list[arg_spec*] specs = new list[arg_spec*]
	for arg_spec* a in p.args:
		if (!a.disabled && a.positional): specs.push(a)
	# Like Python, match the longest prefix of positionals whose minimum
	# counts fit; the rest stay unset (and are reported when required).
	int active = 0
	int need = 0
	while (active < specs.length && need + ap_min_count(specs[active]) <= pos.length):
		need = need + ap_min_count(specs[active])
		active = active + 1
	int k = 0
	int result = 0
	for int s in range(active):
		arg_spec* a = specs[s]
		int later = 0
		for int t in range(s + 1, active): later = later + ap_min_count(specs[t])
		int avail = pos.length - k - later
		if (avail < 0): avail = 0
		int take = avail
		if (a.nargs == ARGPARSE_ONE || a.nargs == ARGPARSE_OPTIONAL):
			if (take > 1): take = 1
		if (a.nargs == ARGPARSE_ONE && take == 0): continue
		if (a.nargs == ARGPARSE_ONE_OR_MORE && take == 0): continue
		for int n in range(take):
			if (result == 0 && ap_store(ns, a, pos[k]) < 0): result = -1
			k = k + 1
	while (k < pos.length):
		extras.push(pos[k])
		k = k + 1
	specs.free()
	return result


# Defaults for everything not given, converted like command-line values.
int ap_apply_defaults(arg_parser* p, arg_namespace* ns):
	for int i in range(p.args.length):
		arg_spec* a = p.args[i]
		arg_value* v = ns.values[i]
		if (a.disabled || v.count > 0 || a.default_text == 0): continue
		if (a.kind == ARGPARSE_BOOL || a.kind == ARGPARSE_COUNT):
			v.items.push(strclone(a.default_text))
			continue
		if (a.kind == ARGPARSE_LIST):
			list[char*] parts = ap_split_commas(a.default_text)
			for char* s in parts:
				if (ns.error == 0): ap_check_value(ns, a, s)
				v.items.push(s)
			parts.free()
		else:
			if (ap_check_value(ns, a, a.default_text) < 0): return -1
			v.items.push(strclone(a.default_text))
		if (ns.error): return -1
	return 0


int ap_check_required(arg_parser* p, arg_namespace* ns, int command_missing):
	ap_buf* b = ap_buf_new()
	int missing = 0
	for int i in range(p.args.length):
		arg_spec* a = p.args[i]
		if (a.disabled || !a.required || ns.values[i].count > 0): continue
		if (missing > 0): ap_buf_add(b, c", ")
		char* d = ap_display(a)
		ap_buf_add(b, d)
		free(d)
		missing = missing + 1
	if (command_missing):
		if (missing > 0): ap_buf_add(b, c", ")
		ap_add_command_choices(b, p)
		missing = missing + 1
	char* names = ap_buf_take(b)
	if (missing == 0):
		free(names)
		return 0
	ap_buf* m = ap_buf_new()
	ap_buf_add(m, c"the following arguments are required: ")
	ap_buf_add(m, names)
	free(names)
	free(ns.error)
	ns.error = ap_buf_take(m)
	return -1


int ap_unrecognized(arg_namespace* ns, list[char*] extras):
	ap_buf* b = ap_buf_new()
	ap_buf_add(b, c"unrecognized arguments:")
	for char* e in extras:
		ap_buf_addc(b, ' ')
		ap_buf_add(b, e)
	free(ns.error)
	ns.error = ap_buf_take(b)
	return -1


int ap_parse_into(arg_parser* p, arg_namespace* ns, list[char*] toks, int start);


int ap_dispatch(arg_parser* p, arg_namespace* ns, list[char*] toks, int i):
	char* name = toks[i]
	arg_parser* child = 0
	for int c in range(p.commands.length):
		if (ap_streq(p.command_names[c], name)): child = p.commands[c]
	if (child == 0):
		ap_buf* b = ap_buf_new()
		ap_buf_add(b, c"argument ")
		ap_add_command_choices(b, p)
		ap_buf_add(b, c": invalid choice: '")
		ap_buf_add(b, name)
		ap_buf_add(b, c"' (choose from ")
		int first = 1
		for char* n in p.command_names:
			if (!first): ap_buf_add(b, c", ")
			ap_buf_add(b, n)
			first = 0
		ap_buf_addc(b, ')')
		free(ns.error)
		ns.error = ap_buf_take(b)
		return -1
	ns.command = strclone(name)
	ns.sub = ap_namespace_new(child)
	ap_parse_into(child, ns.sub, toks, i + 1)
	if (ns.sub.help || ns.sub.error):
		ns.help = ns.sub.help
		ns.report = ns.sub.report
		if (ns.sub.error): ns.error = strclone(ns.sub.error)
		return -1
	return 0


# Parses toks[start..] into ns; 0 on success, -1 with ns.error or
# ns.help set (ns.report names the parser concerned).
int ap_parse_into(arg_parser* p, arg_namespace* ns, list[char*] toks, int start):
	list[char*] pos = new list[char*]
	list[char*] extras = new list[char*]
	int fixed = 0
	for arg_spec* a in p.args:
		if (!a.disabled && a.positional): fixed = fixed + 1
	int dispatched = 0
	int only_positional = 0
	int result = 0
	int i = start
	while (i < toks.length):
		char* t = toks[i]
		if (!only_positional && ap_streq(t, c"--")):
			only_positional = 1
			i = i + 1
			continue
		if (!only_positional && ap_looks_optional(t)):
			i = ap_take_option(p, ns, toks, i, extras)
			if (i < 0 || ns.help):
				result = -1
				break
			continue
		if (p.commands.length > 0 && pos.length == fixed):
			result = ap_dispatch(p, ns, toks, i)
			dispatched = 1
			break
		pos.push(t)
		i = i + 1
	if (result == 0): result = ap_assign_positionals(p, ns, pos, extras)
	if (result == 0):
		int command_missing = p.commands.length > 0 && !dispatched && !p.command_optional
		result = ap_check_required(p, ns, command_missing)
	if (result == 0 && extras.length > 0): result = ap_unrecognized(ns, extras)
	if (result == 0): result = ap_apply_defaults(p, ns)
	pos.free()
	extras.free()
	return result


arg_namespace* argparse_parse_list(arg_parser* p, list[char*] args):
	arg_namespace* ns = ap_namespace_new(p)
	ap_parse_into(p, ns, args, 0)
	return ns


arg_namespace* argparse_parse(arg_parser* p, int argc, int argv):
	char** words = cast(char**, argv)
	list[char*] args = new list[char*]
	for int i in range(1, argc): args.push(words[i])
	arg_namespace* ns = argparse_parse_list(p, args)
	args.free()
	return ns


# Parses the argv recorded by lib.args' args_init.
arg_namespace* argparse_parse_args(arg_parser* p):
	list[char*] args = new list[char*]
	for int i in range(1, args_count()): args.push(args_get(i))
	arg_namespace* ns = argparse_parse_list(p, args)
	args.free()
	return ns


# "usage: ...\nprog: error: message\n" for a failed parse, else 0.
char* argparse_error_text(arg_namespace* ns):
	if (ns.error == 0): return 0
	ap_buf* b = ap_buf_new()
	char* usage = argparse_usage(ns.report)
	ap_buf_add(b, usage)
	free(usage)
	ap_buf_add(b, ns.report.prog)
	ap_buf_add(b, c": error: ")
	ap_buf_add(b, ns.error)
	ap_buf_addc(b, '\n')
	return ap_buf_take(b)


# Help text of the parser that saw -h (the subcommand's when it was one).
char* argparse_help_for(arg_namespace* ns):
	return argparse_help(ns.report)


arg_namespace* argparse_parse_or_exit(arg_parser* p, int argc, int argv):
	arg_namespace* ns = argparse_parse(p, argc, argv)
	if (ns.help):
		char* h = argparse_help_for(ns)
		write(1, h, strlen(h))
		exit(0)
	if (ns.error):
		char* e = argparse_error_text(ns)
		write(2, e, strlen(e))
		exit(2)
	return ns


# ------------------------------------------------------------- reading

# Finds dest in ns or, failing that, in its subcommand namespaces.
arg_namespace* ap_lookup(arg_namespace* ns, char* name, arg_spec** spec_out):
	arg_namespace* cur = ns
	while (cur):
		arg_spec* a = ap_find_dest(cur.parser, name)
		if (a && a.kind != ARGPARSE_HELP):
			*spec_out = a
			return cur
		cur = cur.sub
	ap_fatal(c"no argument named", name)
	return 0


arg_value* ap_lookup_value(arg_namespace* ns, char* name, arg_spec** spec_out):
	arg_namespace* owner = ap_lookup(ns, name, spec_out)
	return ap_value_of(owner, *spec_out)


int argparse_get_bool(arg_namespace* ns, char* name);


char* argparse_get(arg_namespace* ns, char* name):
	arg_spec* a = 0
	arg_value* v = ap_lookup_value(ns, name, &a)
	if (v.items.length == 0): return 0
	return v.items[v.items.length - 1]


int argparse_get_int(arg_namespace* ns, char* name):
	arg_spec* a = 0
	arg_value* v = ap_lookup_value(ns, name, &a)
	int n = 0
	if (a.kind == ARGPARSE_COUNT):
		if (a.default_text): ap_parse_int(a.default_text, &n)
		return n + v.count
	if (a.kind == ARGPARSE_BOOL): return argparse_get_bool(ns, name)
	if (v.items.length == 0): return 0
	ap_parse_int(v.items[v.items.length - 1], &n)
	return n


float argparse_get_float(arg_namespace* ns, char* name):
	arg_spec* a = 0
	arg_value* v = ap_lookup_value(ns, name, &a)
	float f = 0.0
	if (v.items.length == 0): return f
	ap_parse_float(v.items[v.items.length - 1], &f)
	return f


int argparse_get_bool(arg_namespace* ns, char* name):
	arg_spec* a = 0
	arg_value* v = ap_lookup_value(ns, name, &a)
	if (v.count > 0): return 1
	if (v.items.length == 0): return 0
	return ap_truthy(v.items[v.items.length - 1])


# All values in order (repeated list options, multi-value positionals).
# The list belongs to ns.
list[char*] argparse_get_list(arg_namespace* ns, char* name):
	arg_spec* a = 0
	arg_value* v = ap_lookup_value(ns, name, &a)
	return v.items


int argparse_is_set(arg_namespace* ns, char* name):
	arg_spec* a = 0
	arg_value* v = ap_lookup_value(ns, name, &a)
	return v.count


char* argparse_command(arg_namespace* ns):
	return ns.command


arg_namespace* argparse_subnamespace(arg_namespace* ns):
	return ns.sub
