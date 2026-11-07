# Declaration attributes for relocatable objects
# (docs/projects/object_files.md, "Sections and symbol attributes").
#
# One or more attributes precede a function or global declaration, on
# the same line or on lines of their own:
#
#	@section(".init.text")
#	@weak
#	export int setup():
#		...
#
#	@section(".data..percpu") @align(64)
#	int counter
#
#	@weak
#	extern int optional_hook(int x)
#
#	@alias("setup")
#	int setup_alias()
#
# @section, @align and the weak binding take effect in --emit=obj
# objects; elsewhere they are accepted and ignored, like 'export' on a
# native executable. @alias works everywhere: the declared name is a
# second W name for the target's definition. @used is accepted for
# compatibility: W never drops an unreferenced function or global.
#
# This file is compiled by the committed seed: only seed-understood
# syntax here.
import grammar.string_literal

int parse_constant_literal(char* what, char* name);
void object_place_function(int start, int end, char* section, int align);
void object_place_global(int symbol, char* section, int align);
void object_note_weak(char* name);
void object_note_alias(int t, char* name, char* target, int is_function);

# The attributes parsed for the declaration that follows.
int attribute_count
char* attribute_section
int attribute_weak
int attribute_used
int attribute_align
char* attribute_alias


# A "..." (or c"...") argument; returns a fresh copy.
char* attribute_string_argument(char* attribute):
	if ((token[0] != '"') && ((token[0] != 'c') || (token[1] != '"'))):
		error3(c"attribute '@", attribute, c"' expects a \"string\" argument")
	int length = 0
	if (token[0] == 'c'): length = process_prefixed_string_literal()
	else: length = process_string_literal()
	token[length] = 0
	if (length == 0): error3(c"attribute '@", attribute, c"' needs a non-empty name")
	char* value = strclone(token)
	get_token()
	return value


# Parse the attributes at the current token ('@' ...) into the pending
# set; returns the number parsed.
int object_attributes_parse():
	attribute_count = 0
	attribute_section = 0
	attribute_weak = 0
	attribute_used = 0
	attribute_align = 0
	attribute_alias = 0
	while (peek(c"@")):
		get_token()
		char* name = strclone(token)
		get_token()
		attribute_count = attribute_count + 1
		if (strcmp(name, c"section") == 0):
			expect(c"(")
			attribute_section = attribute_string_argument(name)
			expect(c")")
		else if (strcmp(name, c"alias") == 0):
			expect(c"(")
			attribute_alias = attribute_string_argument(name)
			expect(c")")
		else if (strcmp(name, c"align") == 0):
			expect(c"(")
			int align = parse_constant_literal(c"argument of attribute", c"@align")
			if ((align < 1) || ((align & (align - 1)) != 0) || (align > 1048576)):
				error(c"'@align' needs a power of two between 1 and 1048576")
			attribute_align = align
			expect(c")")
		else if (strcmp(name, c"weak") == 0): attribute_weak = 1
		else if (strcmp(name, c"used") == 0): attribute_used = 1
		else: error3(c"unknown attribute '@", name, c"'")
		free(name)
	return attribute_count


# The declaration consumed the attributes.
void object_attributes_done():
	attribute_count = 0


void object_attributes_unconsumed():
	if (attribute_count):
		attribute_count = 0
		error(c"attributes must precede a function, global or extern declaration")


# An extern declaration: only the weak binding applies.
void object_attributes_extern(char* import_name):
	if (attribute_count == 0): return
	if ((attribute_section != 0) || (attribute_align != 0) || (attribute_alias != 0)):
		attribute_count = 0
		error(c"an extern declaration takes no '@section', '@align' or '@alias'")
	if (attribute_weak && elf_object): object_note_weak(import_name)
	object_attributes_done()


# A function definition or prototype named name (symbol t) whose code,
# for a definition, spans the code buffer offsets [start, end).
void object_attributes_function(int t, char* name, int start, int end):
	if (attribute_count == 0): return
	if (attribute_alias != 0):
		if (end > start): error(c"an '@alias' declaration has no body")
		object_note_alias(t, name, attribute_alias, 1)
	if (elf_object):
		if (attribute_weak): object_note_weak(name)
		if ((end > start) && ((attribute_section != 0) || (attribute_align != 0))):
			object_place_function(start, end, attribute_section, attribute_align)
	object_attributes_done()


# A global variable named name (symbol t), before its storage is
# reserved: returns 1 when it is an alias, which reserves none.
int object_attributes_global_alias(int t, char* name, int has_initializer):
	if ((attribute_count == 0) || (attribute_alias == 0)): return 0
	if (has_initializer): error(c"an '@alias' declaration has no initializer")
	object_note_alias(t, name, attribute_alias, 0)
	if (attribute_weak && elf_object): object_note_weak(name)
	object_attributes_done()
	return 1


# A global variable after its storage is reserved.
void object_attributes_global(int t, char* name):
	if (attribute_count == 0): return
	if (elf_object):
		if (attribute_weak): object_note_weak(name)
		if ((attribute_section != 0) || (attribute_align != 0)): object_place_global(t, attribute_section, attribute_align)
	object_attributes_done()
