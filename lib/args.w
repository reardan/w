/*
Command-line argument parsing helpers.

args_init(argc, argv) records the raw argument words; afterwards:
	args_count()             number of raw arguments including the program name
	args_get(i)              raw argument word i as a char*
	args_program()           argv[0]
	args_positional_count()  arguments that are neither flags nor flag values
	args_positional(i)       i-th positional argument (0-based)
	args_has_flag(name)      1 when -name, --name, -name=x or --name=x is present
	args_value(name)         value from -name=x / --name=x, or the token
	                         following a bare -name / --name; 0 when absent
	args_declare_bool(name)  marks name (no dashes) a boolean flag: its bare
	                         form never consumes the next token as a value
	args_has_bool_flag(name) args_declare_bool(name) plus args_has_flag(name)
	                         in one call

A token starting with '-' is a flag; one or two leading dashes parse the
same. A flag written without '=' takes the following token as its value
when that token exists and is not itself a flag, so "-o output" and
"-o=output" are equivalent.

That default is wrong for a flag that only ever means present/absent: a
bare boolean flag directly followed by a positional would swallow it as
its "value" ("stat -f path" would read "path" as -f's value and
args_positional(0) would never see it). Declare such names boolean with
args_declare_bool(name) (or args_has_bool_flag(name), which declares and
tests presence in one call) *before* reading positionals; a declared
name's bare form then leaves the following token alone. Negative numbers
are indistinguishable from flags to this helper.
*/
import lib.lib


list[char*] args_bool_names


int args_argc
int args_argv


void args_init(int argc, int argv):
	args_argc = argc
	args_argv = argv


int args_count():
	return args_argc


char* args_get(int i):
	if ((i < 0) || (i >= args_argc)):
		return 0
	char** argv = cast(char**, args_argv)
	return argv[i]


char* args_program():
	return args_get(0)


# Pointer just past the leading dashes when arg is a flag token, else 0.
char* args_flag_body(char* arg):
	if (arg == 0):
		return 0
	if (arg[0] != '-'):
		return 0
	arg = arg + 1
	if (arg[0] == '-'):
		arg = arg + 1
	return arg


# 1 when the flag body carries an inline =value.
int args_body_has_value(char* body):
	int i = 0
	while (body[i]):
		if (body[i] == '='):
			return 1
		i = i + 1
	return 0


# 1 when the flag body is exactly name, or name followed by '=value'.
int args_name_matches(char* body, char* name):
	int i = 0
	while (name[i]):
		if (body[i] != name[i]):
			return 0
		i = i + 1
	if (body[i] == 0):
		return 1
	if (body[i] == '='):
		return 1
	return 0


int args_has_flag(char* name):
	int i = 1
	while (i < args_argc):
		char* body = args_flag_body(args_get(i))
		if (body != 0):
			if (args_name_matches(body, name)):
				return 1
		i = i + 1
	return 0


# Marks name (bare, no leading dashes, e.g. "f" or "nofollow") a boolean
# flag: args_is_positional/args_value stop treating its bare form as
# consuming the following token. Safe to call more than once for the
# same name; declarations persist across args_init calls.
void args_declare_bool(char* name):
	if (args_bool_names == 0):
		args_bool_names = new list[char*]
	int i = 0
	while (i < args_bool_names.length):
		if (strcmp(args_bool_names[i], name) == 0):
			return
		i = i + 1
	args_bool_names.push(name)


int args_name_is_bool(char* name):
	if (args_bool_names == 0):
		return 0
	int i = 0
	while (i < args_bool_names.length):
		if (strcmp(args_bool_names[i], name) == 0):
			return 1
		i = i + 1
	return 0


# args_declare_bool(name) followed by args_has_flag(name): use this for a
# presence-only flag like -f/--nofollow so it never swallows the
# positional that follows it.
int args_has_bool_flag(char* name):
	args_declare_bool(name)
	return args_has_flag(name)


char* args_value(char* name):
	int i = 1
	while (i < args_argc):
		char* body = args_flag_body(args_get(i))
		if (body != 0):
			if (args_name_matches(body, name)):
				int name_length = strlen(name)
				if (body[name_length] == '='):
					return body + name_length + 1
				if (args_name_is_bool(name)):
					return 0
				# Bare flag: the next token is its value unless it is a flag
				char* next = args_get(i + 1)
				if (next != 0):
					if (args_flag_body(next) == 0):
						return next
				return 0
		i = i + 1
	return 0


int args_is_positional(int i):
	if ((i < 1) || (i >= args_argc)):
		return 0
	if (args_flag_body(args_get(i)) != 0):
		return 0
	# The token after a bare -flag (no inline =value) is that flag's value,
	# unless the flag name was declared boolean (args_declare_bool)
	if (i >= 2):
		char* prev_body = args_flag_body(args_get(i - 1))
		if (prev_body != 0):
			if (args_body_has_value(prev_body) == 0):
				if (args_name_is_bool(prev_body) == 0):
					return 0
	return 1


int args_positional_count():
	int count = 0
	int i = 1
	while (i < args_argc):
		count = count + args_is_positional(i)
		i = i + 1
	return count


char* args_positional(int index):
	int i = 1
	while (i < args_argc):
		if (args_is_positional(i)):
			if (index == 0):
				return args_get(i)
			index = index - 1
		i = i + 1
	return 0
