/*
Declared command-line argument parser.

This is a conservative standard-library layer over raw argv handling: callers
declare accepted flags/options/positionals first, then parsing reports unknown
arguments and missing values through arg_namespace.error.
*/
import lib.lib
import structures.string


struct arg_spec:
	char* name
	char* metavar
	char* help
	int kind
	int required


struct arg_subcommand:
	char* name
	int parser


struct arg_parser:
	char* program
	char* description
	list[arg_spec*] specs
	list[arg_subcommand*] subcommands


struct arg_value:
	char* name
	char* value
	int present


struct arg_namespace:
	list[arg_value*] values
	list[char*] positionals
	char* error
	int help_requested
	char* subcommand
	arg_namespace* subnamespace


int argparse_kind_flag():
	return 1


int argparse_kind_option():
	return 2


int argparse_kind_positional():
	return 3


char* argparse_strip_dashes(char* name):
	if (name == 0):
		return c""
	while (name[0] == '-'):
		name = name + 1
	return name


char* argparse_clone_name(char* name):
	return strclone(argparse_strip_dashes(name))


arg_parser* argparse_new(char* program):
	arg_parser* p = new arg_parser()
	p.program = program
	p.description = c""
	p.specs = new list[arg_spec*]
	p.subcommands = new list[arg_subcommand*]
	return p


void argparse_description(arg_parser* p, char* text):
	p.description = text


void argparse_add_spec(arg_parser* p, char* name, char* metavar, char* help, int kind, int required):
	arg_spec* spec = new arg_spec()
	spec.name = argparse_clone_name(name)
	spec.metavar = metavar
	spec.help = help
	spec.kind = kind
	spec.required = required
	p.specs.push(spec)


void argparse_add_flag(arg_parser* p, char* name, char* help):
	argparse_add_spec(p, name, c"", help, argparse_kind_flag(), 0)


void argparse_add_option(arg_parser* p, char* name, char* metavar, char* help):
	argparse_add_spec(p, name, metavar, help, argparse_kind_option(), 0)


void argparse_add_required_option(arg_parser* p, char* name, char* metavar, char* help):
	argparse_add_spec(p, name, metavar, help, argparse_kind_option(), 1)


void argparse_add_positional(arg_parser* p, char* name, char* help):
	argparse_add_spec(p, name, c"", help, argparse_kind_positional(), 1)


void argparse_add_subcommand(arg_parser* p, char* name, arg_parser* child):
	arg_subcommand* sub = new arg_subcommand()
	sub.name = name
	sub.parser = cast(int, child)
	p.subcommands.push(sub)


arg_namespace* argparse_namespace_new():
	arg_namespace* ns = new arg_namespace()
	ns.values = new list[arg_value*]
	ns.positionals = new list[char*]
	ns.error = 0
	ns.help_requested = 0
	ns.subcommand = 0
	ns.subnamespace = 0
	return ns


int argparse_token_name_equals(char* token_body, char* name):
	int i = 0
	while ((name[i] != 0) & (token_body[i] != 0) & (token_body[i] != '=')):
		if (name[i] != token_body[i]):
			return 0
		i = i + 1
	if (name[i] != 0):
		return 0
	if ((token_body[i] != 0) & (token_body[i] != '=')):
		return 0
	return 1


arg_spec* argparse_find_option(arg_parser* p, char* token):
	char* body = argparse_strip_dashes(token)
	for arg_spec* spec in p.specs:
		if (spec.kind != argparse_kind_positional()):
			if (argparse_token_name_equals(body, spec.name)):
				return spec
	return 0


arg_spec* argparse_positional_spec(arg_parser* p, int index):
	for arg_spec* spec in p.specs:
		if (spec.kind == argparse_kind_positional()):
			if (index == 0):
				return spec
			index = index - 1
	return 0


arg_subcommand* argparse_find_subcommand(arg_parser* p, char* name):
	for arg_subcommand* sub in p.subcommands:
		if (strcmp(sub.name, name) == 0):
			return sub
	return 0


char* argparse_inline_value(char* token):
	int i = 0
	while (token[i] != 0):
		if (token[i] == '='):
			return token + i + 1
		i = i + 1
	return 0


void argparse_set(arg_namespace* ns, char* name, char* value):
	char* key = argparse_strip_dashes(name)
	for arg_value* item in ns.values:
		if (strcmp(item.name, key) == 0):
			item.value = value
			item.present = 1
			return
	arg_value* item = new arg_value()
	item.name = strclone(key)
	item.value = value
	item.present = 1
	ns.values.push(item)


char* argparse_get(arg_namespace* ns, char* name):
	char* key = argparse_strip_dashes(name)
	for arg_value* item in ns.values:
		if (strcmp(item.name, key) == 0):
			return item.value
	return 0


int argparse_has(arg_namespace* ns, char* name):
	return argparse_get(ns, name) != 0


int argparse_positional_count(arg_namespace* ns):
	return ns.positionals.length


char* argparse_positional(arg_namespace* ns, int index):
	if ((index < 0) | (index >= ns.positionals.length)):
		return 0
	return ns.positionals[index]


void argparse_error2(arg_namespace* ns, char* prefix, char* detail):
	string_builder* s = string_from(prefix)
	string_append(s, detail)
	ns.error = s.data
	free(s)


arg_namespace* argparse_parse_from(arg_parser* p, int argc, int argv, int start):
	arg_namespace* ns = argparse_namespace_new()
	char** words = cast(char**, argv)
	int positional_index = 0
	int after_dashdash = 0
	int i = start
	while (i < argc):
		char* word = words[i]
		if (after_dashdash == 0):
			if ((strcmp(word, c"--help") == 0) | (strcmp(word, c"-h") == 0)):
				ns.help_requested = 1
				argparse_set(ns, c"help", c"1")
				return ns
			if (strcmp(word, c"--") == 0):
				after_dashdash = 1
				i = i + 1
				continue
			if (word[0] != '-'):
				arg_subcommand* sub = argparse_find_subcommand(p, word)
				if (sub != 0):
					ns.subcommand = sub.name
					ns.subnamespace = argparse_parse_from(cast(arg_parser*, sub.parser), argc, argv, i + 1)
					if (ns.subnamespace.error != 0):
						ns.error = ns.subnamespace.error
					return ns
		if ((after_dashdash == 0) & (word[0] == '-')):
			arg_spec* spec = argparse_find_option(p, word)
			if (spec == 0):
				argparse_error2(ns, c"unknown argument: ", word)
				return ns
			if (spec.kind == argparse_kind_flag()):
				if (argparse_inline_value(word) != 0):
					argparse_error2(ns, c"flag does not take a value: ", word)
					return ns
				argparse_set(ns, spec.name, c"1")
			else:
				char* value = argparse_inline_value(word)
				if (value == 0):
					if (i + 1 >= argc):
						argparse_error2(ns, c"missing value for: ", word)
						return ns
					value = words[i + 1]
					i = i + 1
				argparse_set(ns, spec.name, value)
		else:
			arg_spec* spec = argparse_positional_spec(p, positional_index)
			if (spec == 0):
				argparse_error2(ns, c"unexpected positional argument: ", word)
				return ns
			ns.positionals.push(word)
			argparse_set(ns, spec.name, word)
			positional_index = positional_index + 1
		i = i + 1
	for arg_spec* spec in p.specs:
		if (spec.required):
			if (argparse_has(ns, spec.name) == 0):
				argparse_error2(ns, c"missing required argument: ", spec.name)
				return ns
	return ns


arg_namespace* argparse_parse(arg_parser* p, int argc, int argv):
	return argparse_parse_from(p, argc, argv, 1)


void argparse_append_usage(arg_parser* p, string_builder* out):
	string_append(out, c"usage: ")
	string_append(out, p.program)
	for arg_spec* spec in p.specs:
		if (spec.kind == argparse_kind_flag()):
			string_append(out, c" [--")
			string_append(out, spec.name)
			string_append(out, c"]")
		else if (spec.kind == argparse_kind_option()):
			string_append(out, c" [--")
			string_append(out, spec.name)
			string_append(out, c" ")
			string_append(out, spec.metavar)
			string_append(out, c"]")
		else:
			string_append(out, c" <")
			string_append(out, spec.name)
			string_append(out, c">")
	if (p.subcommands.length > 0):
		string_append(out, c" <command>")
	string_append(out, c"\x0a")


char* argparse_help(arg_parser* p):
	string_builder* out = string_new()
	argparse_append_usage(p, out)
	if (strlen(p.description) > 0):
		string_append(out, c"\x0a")
		string_append(out, p.description)
		string_append(out, c"\x0a")
	string_append(out, c"\x0aoptions:\x0a")
	string_append(out, c"  -h, --help")
	string_append(out, c"\x09show this help message\x0a")
	for arg_spec* spec in p.specs:
		if (spec.kind == argparse_kind_flag()):
			string_append(out, c"  --")
			string_append(out, spec.name)
			string_append(out, c"\x09")
			string_append(out, spec.help)
			string_append(out, c"\x0a")
		else if (spec.kind == argparse_kind_option()):
			string_append(out, c"  --")
			string_append(out, spec.name)
			string_append(out, c" ")
			string_append(out, spec.metavar)
			string_append(out, c"\x09")
			string_append(out, spec.help)
			string_append(out, c"\x0a")
		else:
			string_append(out, c"  ")
			string_append(out, spec.name)
			string_append(out, c"\x09")
			string_append(out, spec.help)
			string_append(out, c"\x0a")
	if (p.subcommands.length > 0):
		string_append(out, c"\x0acommands:\x0a")
		for arg_subcommand* sub in p.subcommands:
			string_append(out, c"  ")
			string_append(out, sub.name)
			string_append(out, c"\x0a")
	return out.data
