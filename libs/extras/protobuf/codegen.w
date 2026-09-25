/*
libs/extras/protobuf/codegen.w: .proto IDL -> W 'message' source
(issue #16 stage 2, docs/projects/protobuf.md §4.3 / §9).

Parses a .proto file with the parser generated from
libs/extras/protobuf/proto.pg (generated_proto_parser.w, committed and
checked against regeneration like the C importer's parser), walks the
AST, and writes ordinary W declarations for the compiler's 'message'
keyword (grammar/protobuf_builtin.w):

- message Foo { ... }   ->  message Foo:  (nested: Outer_Inner)
- enum Color { ... }    ->  enum Color:   (values of a nested enum get
                            the enclosing message's prefix, Outer_VALUE,
                            since W enum values share one namespace)
- map<K, V> f = N       ->  repeated Outer_FEntry f = N, plus the
                            synthetic entry message { K key = 1;
                            V value = 2; } -- the wire format defines a
                            map field as exactly that
- oneof members         ->  ordinary fields (wire-compatible; which
                            member is set is not tracked)
- proto2 required/optional are accepted as input and noted in comments
  (neither is enforced, matching proto3 decode semantics, §5)
- options, reserved ranges, extensions and services are parsed and not
  emitted (services are out of scope, §7)

Messages are emitted in dependency order (a W declaration must precede
its use), enums first. Type references resolve with protobuf's scoping:
innermost enclosing scope outward, a leading '.' is absolute. The
package only scopes name lookup; W names drop it.

Not supported yet (reported as errors naming the line): float, double,
sfixed32 and sfixed64 fields (the runtime has no such kinds), messages
that contain themselves directly or through a cycle (the compiler
rejects recursive messages), negative enum values, and types that come
from an imported .proto file (generate that file too and import it).
*/
import lib.lib
import structures.string
import libs.extras.parser_generator.runtime
import libs.extras.protobuf.generated_proto_parser


int pc_label_none():
	return 0


int pc_label_repeated():
	return 1


int pc_label_optional():
	return 2


int pc_label_required():
	return 3


struct pc_field:
	char* name
	char* type_ref
	int label
	int number
	char* oneof_name
	int line
	char* w_type
	int message_dep


struct pc_message:
	char* full_name
	char* w_name
	list[pc_field*] fields
	int state
	int line
	int is_map_entry


struct pc_enum:
	char* full_name
	char* w_name
	char* value_prefix
	list[char*] value_names
	list[int] value_numbers
	int line


struct pc_codegen:
	char* filename
	char* package
	list[pc_message*] messages
	list[pc_enum*] enums
	map[char*, int] message_index
	map[char*, int] enum_index
	list[char*] imports
	list[char*] notes
	list[char*] errors
	string_builder* out


struct proto_codegen_result:
	char* source
	list[char*] errors


# ---- AST helpers -----------------------------------------------------------

int pc_is_rule(pg_ast_node* node, int kind):
	if (node == 0):
		return 0
	return (node.token == 0) && (node.kind == kind)


int pc_is_token(pg_ast_node* node, int kind):
	if (node == 0):
		return 0
	return (node.token != 0) && (node.kind == kind)


pg_ast_node* pc_child_rule(pg_ast_node* node, int kind):
	int i = 0
	while (i < pg_ast_child_count(node)):
		pg_ast_node* child = pg_ast_child(node, i)
		if (pc_is_rule(child, kind)):
			return child
		i = i + 1
	return 0


int pc_has_token(pg_ast_node* node, int kind):
	if (node == 0):
		return 0
	if (pc_is_token(node, kind)):
		return 1
	int i = 0
	while (i < pg_ast_child_count(node)):
		if (pc_has_token(pg_ast_child(node, i), kind)):
			return 1
		i = i + 1
	return 0


void pc_append_tokens(pg_ast_node* node, string_builder* s):
	if (node.token != 0):
		string_append(s, node.token.text)
		return
	int i = 0
	while (i < pg_ast_child_count(node)):
		pc_append_tokens(pg_ast_child(node, i), s)
		i = i + 1


# Concatenated token text of a subtree: full_ident / type_name spellings
# ('foo.Bar', '.pkg.Msg') come back without the lexer's whitespace.
char* pc_text(pg_ast_node* node):
	string_builder* s = string_new()
	pc_append_tokens(node, s)
	char* text = strclone(s.data)
	string_free(s)
	return text


# First NUMBER token directly under node (the field/enum number).
pg_ast_node* pc_number_token(pg_ast_node* node):
	int i = 0
	while (i < pg_ast_child_count(node)):
		pg_ast_node* child = pg_ast_child(node, i)
		if (pc_is_token(child, protoidl_token_NUMBER())):
			return child
		i = i + 1
	return 0


int pc_line(pg_ast_node* node):
	pg_token* t = pg_ast_first_token(node)
	if (t == 0):
		return 0
	return t.line


# Integer literal value: decimal, 0x hex or leading-0 octal (the proto
# spec's intLit). Returns -1 for anything else (a float, an overflow).
int pc_parse_int(char* text):
	int base = 10
	int i = 0
	if ((text[0] == '0') && ((text[1] == 'x') || (text[1] == 'X'))):
		base = 16
		i = 2
	else if ((text[0] == '0') && (text[1] != 0)):
		base = 8
		i = 1
	if (text[i] == 0):
		return -1
	int value = 0
	while (text[i] != 0):
		int c = text[i]
		int digit = -1
		if ((c >= '0') && (c <= '9')):
			digit = c - '0'
		else if ((c >= 'a') && (c <= 'f')):
			digit = c - 'a' + 10
		else if ((c >= 'A') && (c <= 'F')):
			digit = c - 'A' + 10
		if ((digit < 0) || (digit >= base)):
			return -1
		if (value > (536870911 - digit) / base):
			return -1
		value = value * base + digit
		i = i + 1
	return value


# ---- diagnostics -------------------------------------------------------------

void pc_error(pc_codegen* g, int line, char* message, char* subject):
	string_builder* s = string_new()
	string_append(s, g.filename)
	string_append(s, c":")
	string_append_int(s, line)
	string_append(s, c": ")
	string_append(s, message)
	if (subject != 0):
		string_append(s, c" '")
		string_append(s, subject)
		string_append(s, c"'")
	g.errors.push(strclone(s.data))
	string_free(s)


# ---- names -------------------------------------------------------------------

char* pc_join(char* scope, char* name):
	if ((scope == 0) || (scope[0] == 0)):
		return strclone(name)
	string_builder* s = string_new()
	string_append(s, scope)
	string_append(s, c".")
	string_append(s, name)
	char* joined = strclone(s.data)
	string_free(s)
	return joined


# W name for a fully qualified proto name: drop the package, dots become
# underscores (Outer.Inner -> Outer_Inner).
char* pc_w_name(pc_codegen* g, char* full_name):
	char* rest = full_name
	int plen = strlen(g.package)
	if (plen > 0):
		if (starts_with(full_name, g.package) && (full_name[plen] == '.')):
			rest = full_name + plen + 1
	char* name = strclone(rest)
	int i = 0
	while (name[i] != 0):
		if (name[i] == '.'):
			name[i] = '_'
		i = i + 1
	return name


# Everything before the last '.', or "" at the outermost scope.
char* pc_parent_scope(char* scope):
	int n = strlen(scope)
	int i = n - 1
	while (i >= 0):
		if (scope[i] == '.'):
			char* parent = strclone(scope)
			parent[i] = 0
			return parent
		i = i - 1
	return c""


# protoc's map entry name: field 'my_map' -> 'MyMapEntry'.
char* pc_map_entry_name(char* field_name):
	string_builder* s = string_new()
	int upper = 1
	int i = 0
	while (field_name[i] != 0):
		int c = field_name[i]
		if (c == '_'):
			upper = 1
		else:
			if (upper && (c >= 'a') && (c <= 'z')):
				c = c - 'a' + 'A'
			string_append_char(s, c)
			upper = 0
		i = i + 1
	string_append(s, c"Entry")
	char* name = strclone(s.data)
	string_free(s)
	return name


# ---- collect pass -------------------------------------------------------------

pc_field* pc_field_new(char* name, char* type_ref, int label, int number, int line):
	pc_field* f = new pc_field()
	f.name = name
	f.type_ref = type_ref
	f.label = label
	f.number = number
	f.oneof_name = 0
	f.line = line
	f.w_type = 0
	f.message_dep = -1
	return f


pc_message* pc_message_new(pc_codegen* g, char* full_name, int line):
	pc_message* m = new pc_message()
	m.full_name = full_name
	m.w_name = pc_w_name(g, full_name)
	m.fields = new list[pc_field*]
	m.state = 0
	m.line = line
	m.is_map_entry = 0
	g.message_index[full_name] = g.messages.length
	g.messages.push(m)
	return m


int pc_field_number(pc_codegen* g, pg_ast_node* node, char* field_name):
	pg_ast_node* num = pc_number_token(node)
	int number = -1
	if (num != 0):
		number = pc_parse_int(num.text)
	if ((number < 1) || (number > 536870911)):
		pc_error(g, pc_line(node), c"field number must be between 1 and 536870911 for field", field_name)
		return 1
	return number


int pc_label_of(pg_ast_node* label):
	if (label == 0):
		return pc_label_none()
	if (pc_has_token(label, protoidl_token_KW_REPEATED())):
		return pc_label_repeated()
	if (pc_has_token(label, protoidl_token_KW_OPTIONAL())):
		return pc_label_optional()
	if (pc_has_token(label, protoidl_token_KW_REQUIRED())):
		return pc_label_required()
	return pc_label_none()


void pc_collect_enum(pc_codegen* g, pg_ast_node* node, char* scope, char* value_prefix):
	char* name = pc_text(pc_child_rule(node, protoidl_ast_ident_word()))
	pc_enum* e = new pc_enum()
	e.full_name = pc_join(scope, name)
	e.w_name = pc_w_name(g, e.full_name)
	e.value_prefix = value_prefix
	e.value_names = new list[char*]
	e.value_numbers = new list[int]
	e.line = pc_line(node)
	g.enum_index[e.full_name] = g.enums.length
	g.enums.push(e)
	int i = 0
	while (i < pg_ast_child_count(node)):
		pg_ast_node* item = pg_ast_child(node, i)
		pg_ast_node* value = pc_child_rule(item, protoidl_ast_enum_value())
		if (pc_is_rule(item, protoidl_ast_enum_item()) && (value != 0)):
			char* value_name = pc_text(pc_child_rule(value, protoidl_ast_ident_word()))
			pg_ast_node* sign = pc_child_rule(value, protoidl_ast_sign())
			pg_ast_node* num = pc_number_token(value)
			int number = pc_parse_int(num.text)
			if (pc_has_token(sign, protoidl_token_MINUS())):
				pc_error(g, pc_line(value), c"negative enum values are not supported yet:", value_name)
			else if (number < 0):
				pc_error(g, pc_line(value), c"enum value must be an integer literal:", value_name)
			e.value_names.push(value_name)
			e.value_numbers.push(number)
		i = i + 1
	if (e.value_names.length == 0):
		pc_error(g, e.line, c"enum has no values:", name)


void pc_collect_message(pc_codegen* g, pg_ast_node* node, char* scope);


void pc_collect_field(pc_codegen* g, pc_message* m, pg_ast_node* node, int label, char* oneof_name):
	char* field_name = pc_text(pc_child_rule(node, protoidl_ast_ident_word()))
	char* type_ref = pc_text(pc_child_rule(node, protoidl_ast_type_name()))
	pc_field* f = pc_field_new(field_name, type_ref, label, pc_field_number(g, node, field_name), pc_line(node))
	f.oneof_name = oneof_name
	m.fields.push(f)


# map<K, V> name = N  ->  a synthetic Entry message plus a repeated field.
void pc_collect_map_field(pc_codegen* g, pc_message* m, pg_ast_node* node):
	char* field_name = pc_text(pc_child_rule(node, protoidl_ast_ident_word()))
	char* key_type = 0
	char* value_type = 0
	int i = 0
	while (i < pg_ast_child_count(node)):
		pg_ast_node* child = pg_ast_child(node, i)
		if (pc_is_rule(child, protoidl_ast_type_name())):
			if (key_type == 0):
				key_type = pc_text(child)
			else:
				value_type = pc_text(child)
		i = i + 1
	int line = pc_line(node)
	char* entry_full = pc_join(m.full_name, pc_map_entry_name(field_name))
	pc_message* entry = pc_message_new(g, entry_full, line)
	entry.is_map_entry = 1
	entry.fields.push(pc_field_new(c"key", key_type, pc_label_none(), 1, line))
	entry.fields.push(pc_field_new(c"value", value_type, pc_label_none(), 2, line))
	# Absolute reference: the entry lives in m's scope under this name.
	string_builder* s = string_new()
	string_append(s, c".")
	string_append(s, entry_full)
	m.fields.push(pc_field_new(field_name, strclone(s.data), pc_label_repeated(), pc_field_number(g, node, field_name), line))
	string_free(s)


void pc_collect_message(pc_codegen* g, pg_ast_node* node, char* scope):
	char* name = pc_text(pc_child_rule(node, protoidl_ast_ident_word()))
	pc_message* m = pc_message_new(g, pc_join(scope, name), pc_line(node))
	int i = 0
	while (i < pg_ast_child_count(node)):
		pg_ast_node* item = pg_ast_child(node, i)
		if (pc_is_rule(item, protoidl_ast_message_item()) && (pg_ast_child_count(item) > 0)):
			pg_ast_node* decl = pg_ast_child(item, 0)
			if (pc_is_rule(decl, protoidl_ast_field())):
				pc_collect_field(g, m, decl, pc_label_of(pc_child_rule(decl, protoidl_ast_field_label())), 0)
			else if (pc_is_rule(decl, protoidl_ast_message_decl())):
				pc_collect_message(g, decl, m.full_name)
			else if (pc_is_rule(decl, protoidl_ast_enum_decl())):
				string_builder* p = string_new()
				string_append(p, m.w_name)
				string_append(p, c"_")
				pc_collect_enum(g, decl, m.full_name, strclone(p.data))
				string_free(p)
			else if (pc_is_rule(decl, protoidl_ast_map_field())):
				pc_collect_map_field(g, m, decl)
			else if (pc_is_rule(decl, protoidl_ast_oneof_decl())):
				char* oneof_name = pc_text(pc_child_rule(decl, protoidl_ast_ident_word()))
				int j = 0
				while (j < pg_ast_child_count(decl)):
					pg_ast_node* oitem = pg_ast_child(decl, j)
					pg_ast_node* ofield = pc_child_rule(oitem, protoidl_ast_oneof_field())
					if (pc_is_rule(oitem, protoidl_ast_oneof_item()) && (ofield != 0)):
						pc_collect_field(g, m, ofield, pc_label_none(), oneof_name)
					j = j + 1
			else if (pc_is_rule(decl, protoidl_ast_extend_decl())):
				g.notes.push(c"extend blocks (proto2 extensions) are not generated")
		i = i + 1


void pc_collect(pc_codegen* g, pg_ast_node* root):
	# The package scopes every name, so find it first.
	int i = 0
	while (i < pg_ast_child_count(root)):
		pg_ast_node* item = pg_ast_child(root, i)
		pg_ast_node* pkg = pc_child_rule(item, protoidl_ast_package_decl())
		if (pc_is_rule(item, protoidl_ast_top_item()) && (pkg != 0)):
			g.package = pc_text(pc_child_rule(pkg, protoidl_ast_full_ident()))
		i = i + 1
	i = 0
	while (i < pg_ast_child_count(root)):
		pg_ast_node* item = pg_ast_child(root, i)
		if (pc_is_rule(item, protoidl_ast_top_item()) && (pg_ast_child_count(item) > 0)):
			pg_ast_node* decl = pg_ast_child(item, 0)
			if (pc_is_rule(decl, protoidl_ast_message_decl())):
				pc_collect_message(g, decl, g.package)
			else if (pc_is_rule(decl, protoidl_ast_enum_decl())):
				pc_collect_enum(g, decl, g.package, c"")
			else if (pc_is_rule(decl, protoidl_ast_import_decl())):
				pg_ast_node* path = 0
				int j = 0
				while (j < pg_ast_child_count(decl)):
					pg_ast_node* child = pg_ast_child(decl, j)
					if (pc_is_token(child, protoidl_token_STRING())):
						path = child
					j = j + 1
				g.imports.push(path.text)
			else if (pc_is_rule(decl, protoidl_ast_service_decl())):
				g.notes.push(c"services are not generated (RPC is out of scope)")
			else if (pc_is_rule(decl, protoidl_ast_extend_decl())):
				g.notes.push(c"extend blocks (proto2 extensions) are not generated")
		i = i + 1


# ---- resolve pass ---------------------------------------------------------------

int pc_is_scalar(char* t):
	if ((strcmp(t, c"int32") == 0) || (strcmp(t, c"sint32") == 0) || (strcmp(t, c"uint32") == 0) || (strcmp(t, c"fixed32") == 0)):
		return 1
	if ((strcmp(t, c"int64") == 0) || (strcmp(t, c"sint64") == 0) || (strcmp(t, c"uint64") == 0) || (strcmp(t, c"fixed64") == 0)):
		return 1
	if ((strcmp(t, c"bool") == 0) || (strcmp(t, c"string") == 0) || (strcmp(t, c"bytes") == 0)):
		return 1
	return 0


int pc_is_unsupported_scalar(char* t):
	return (strcmp(t, c"float") == 0) || (strcmp(t, c"double") == 0) || (strcmp(t, c"sfixed32") == 0) || (strcmp(t, c"sfixed64") == 0)


# Fully qualified name a type reference names from inside `scope`, or 0.
char* pc_lookup(pc_codegen* g, char* ref, char* scope):
	if (ref[0] == '.'):
		char* absolute = ref + 1
		if ((absolute in g.message_index) || (absolute in g.enum_index)):
			return absolute
		return 0
	char* s = scope
	while (1):
		char* candidate = pc_join(s, ref)
		if ((candidate in g.message_index) || (candidate in g.enum_index)):
			return candidate
		if (s[0] == 0):
			return 0
		s = pc_parent_scope(s)
	return 0


void pc_resolve(pc_codegen* g):
	int i = 0
	while (i < g.messages.length):
		pc_message* m = g.messages[i]
		int j = 0
		while (j < m.fields.length):
			pc_field* f = m.fields[j]
			if (pc_is_scalar(f.type_ref)):
				f.w_type = f.type_ref
			else if (pc_is_unsupported_scalar(f.type_ref)):
				pc_error(g, f.line, c"protobuf type not supported yet:", f.type_ref)
				f.w_type = f.type_ref
			else:
				char* full = pc_lookup(g, f.type_ref, m.full_name)
				if (full == 0):
					if (g.imports.length > 0):
						pc_error(g, f.line, c"unknown type (types from imported .proto files need their own generated module):", f.type_ref)
					else:
						pc_error(g, f.line, c"unknown type", f.type_ref)
					f.w_type = f.type_ref
				else if (full in g.message_index):
					f.message_dep = g.message_index[full]
					f.w_type = g.messages[f.message_dep].w_name
					if (f.message_dep == i):
						pc_error(g, f.line, c"recursive messages are not supported yet:", m.full_name)
				else:
					f.w_type = g.enums[g.enum_index[full]].w_name
			j = j + 1
		i = i + 1


# ---- emit ---------------------------------------------------------------------

void pc_emit_enum(pc_codegen* g, pc_enum* e):
	string_builder* out = g.out
	string_append(out, c"\n\nenum ")
	string_append(out, e.w_name)
	string_append(out, c":\n")
	int i = 0
	while (i < e.value_names.length):
		string_append(out, c"\t")
		string_append(out, e.value_prefix)
		string_append(out, e.value_names[i])
		string_append(out, c" = ")
		string_append_int(out, e.value_numbers[i])
		string_append(out, c"\n")
		i = i + 1


void pc_emit_message(pc_codegen* g, pc_message* m):
	string_builder* out = g.out
	string_append(out, c"\n\n")
	if (m.is_map_entry):
		string_append(out, c"# map entry (key = 1, value = 2)\n")
	string_append(out, c"message ")
	string_append(out, m.w_name)
	string_append(out, c":\n")
	int i = 0
	while (i < m.fields.length):
		pc_field* f = m.fields[i]
		string_append(out, c"\t")
		if (f.label == pc_label_repeated()):
			string_append(out, c"repeated ")
		string_append(out, f.w_type)
		string_append(out, c" ")
		string_append(out, f.name)
		string_append(out, c" = ")
		string_append_int(out, f.number)
		if (f.oneof_name != 0):
			string_append(out, c"  # oneof ")
			string_append(out, f.oneof_name)
		else if (f.label == pc_label_optional()):
			string_append(out, c"  # optional (presence not tracked)")
		else if (f.label == pc_label_required()):
			string_append(out, c"  # required (not enforced)")
		string_append(out, c"\n")
		i = i + 1


# Depth-first so every referenced message is declared before its user.
void pc_visit(pc_codegen* g, int index):
	pc_message* m = g.messages[index]
	if (m.state == 2):
		return
	if (m.state == 1):
		pc_error(g, m.line, c"recursive messages are not supported yet:", m.full_name)
		return
	m.state = 1
	int i = 0
	while (i < m.fields.length):
		pc_field* f = m.fields[i]
		if ((f.message_dep >= 0) && (f.message_dep != index)):
			pc_visit(g, f.message_dep)
		i = i + 1
	m.state = 2
	pc_emit_message(g, m)


void pc_emit(pc_codegen* g):
	string_builder* out = g.out
	string_append(out, c"# Generated from ")
	string_append(out, g.filename)
	string_append(out, c" by tools/proto_to_w.w. Do not edit.\n")
	if (g.package[0] != 0):
		string_append(out, c"# proto package: ")
		string_append(out, g.package)
		string_append(out, c"\n")
	int i = 0
	while (i < g.imports.length):
		string_append(out, c"# proto import (not followed): ")
		string_append(out, g.imports[i])
		string_append(out, c"\n")
		i = i + 1
	i = 0
	while (i < g.notes.length):
		int seen = 0
		int j = 0
		while (j < i):
			if (strcmp(g.notes[j], g.notes[i]) == 0):
				seen = 1
			j = j + 1
		if (seen == 0):
			string_append(out, c"# note: ")
			string_append(out, g.notes[i])
			string_append(out, c"\n")
		i = i + 1
	string_append(out, c"import libs.extras.protobuf.message\n")
	i = 0
	while (i < g.enums.length):
		pc_emit_enum(g, g.enums[i])
		i = i + 1
	i = 0
	while (i < g.messages.length):
		pc_visit(g, i)
		i = i + 1


# ---- entry point -----------------------------------------------------------------

# Translates .proto source text into W source. On success result.source
# is the W module text and result.errors is empty; otherwise
# result.source is 0 and result.errors holds "file:line: message" lines
# (syntax errors included).
proto_codegen_result* proto_to_w(char* input, char* filename):
	proto_codegen_result* result = new proto_codegen_result()
	result.source = 0
	result.errors = new list[char*]
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_ast_node* root = protoidl_parse(input, filename, diagnostics)
	if ((root == 0) || (pg_diagnostics_count(diagnostics) != 0)):
		int i = 0
		while (i < pg_diagnostics_count(diagnostics)):
			pg_diagnostic* d = pg_diagnostics_get(diagnostics, i)
			string_builder* s = string_new()
			string_append(s, filename)
			string_append(s, c":")
			string_append_int(s, d.line)
			string_append(s, c": ")
			string_append(s, d.message)
			if (d.found != 0):
				string_append(s, c" near '")
				string_append(s, d.found)
				string_append(s, c"'")
			result.errors.push(strclone(s.data))
			string_free(s)
			i = i + 1
		if (result.errors.length == 0):
			result.errors.push(c"syntax error")
		return result
	pc_codegen* g = new pc_codegen()
	g.filename = filename
	g.package = c""
	g.messages = new list[pc_message*]
	g.enums = new list[pc_enum*]
	g.message_index = new map[char*, int]
	g.enum_index = new map[char*, int]
	g.imports = new list[char*]
	g.notes = new list[char*]
	g.errors = new list[char*]
	g.out = string_new()
	pc_collect(g, root)
	pc_resolve(g)
	if (g.errors.length == 0):
		pc_emit(g)
	if (g.errors.length != 0):
		result.errors = g.errors
		return result
	result.source = strclone(g.out.data)
	return result
