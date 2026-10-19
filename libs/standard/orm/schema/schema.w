# w-orm schema files (issue #754, unit U1.1): the in-memory model of an
# `.orm` file and its line parser.
#
#	orm_schema* s = orm_schema_parse(text, c"app/models.orm")
#	if (s.errors.length > 0): ...each error is "file:line: message"
#
# The format (docs/projects/orm/u1_1.md has the full reference):
#
#	app library
#	model Book:
#		enum Status: draft, pub
#		string title max_length=300
#		fk author -> Author on_delete=cascade related_name=books
#		m2m tags -> Tag
#		Status status default=draft
#		index title
#		check price >= 0 name=book_price_nonnegative
#		history
#
# Field kinds and flag bits reuse the numbers of libs/standard/orm/contract.w
# (C2) but this module does not import the contract: bin/orm_gen only writes
# text, so it builds for every target without the SQL client.
import lib.lib
import lib.str
import structures.string


const int ORM_SCHEMA_INT = 1
const int ORM_SCHEMA_BIGINT = 2
const int ORM_SCHEMA_BOOL = 3
const int ORM_SCHEMA_TEXT = 4
const int ORM_SCHEMA_DECIMAL = 5
const int ORM_SCHEMA_DATETIME = 6
const int ORM_SCHEMA_DATE = 7
const int ORM_SCHEMA_UUID = 8
const int ORM_SCHEMA_JSON = 9
const int ORM_SCHEMA_FK = 10
const int ORM_SCHEMA_ENUM = 11
const int ORM_SCHEMA_M2M = 12
const int ORM_SCHEMA_REVERSE_FK = 13
const int ORM_SCHEMA_FLOAT = 14

const int ORM_SCHEMA_F_PK = 1
const int ORM_SCHEMA_F_NULL = 2
const int ORM_SCHEMA_F_UNIQUE = 4
const int ORM_SCHEMA_F_INDEXED = 8
const int ORM_SCHEMA_F_AUTO = 16
const int ORM_SCHEMA_F_AUTO_NOW_ADD = 32
const int ORM_SCHEMA_F_AUTO_NOW = 64
const int ORM_SCHEMA_F_DEPRECATED = 128
const int ORM_SCHEMA_F_NO_HISTORY = 256
const int ORM_SCHEMA_F_READ_ONLY = 512

const int ORM_SCHEMA_CASCADE = 1
const int ORM_SCHEMA_PROTECT = 2
const int ORM_SCHEMA_RESTRICT = 3
const int ORM_SCHEMA_SET_NULL = 4
const int ORM_SCHEMA_SET_DEFAULT = 5
const int ORM_SCHEMA_DO_NOTHING = 6


struct orm_schema_enum:
	char* name
	list[char*] values
	int line


struct orm_schema_field:
	char* name           # W field / lookup name
	char* type_name      # as written: "string", "Status", "fk", ...
	int kind             # ORM_SCHEMA_* (same numbers as ORM_* in contract.w)
	int flags            # ORM_SCHEMA_F_*
	int max_length
	int digits
	int places
	char* default_sql    # SQL default expression, or 0
	char* rel_model      # FK/M2M target, REVERSE_FK source model
	int on_delete
	char* related_name
	char* reverse_field  # REVERSE_FK: the FK field on rel_model
	orm_schema_enum* enum_type
	int has_on_delete
	int line


struct orm_schema_index:
	char* name
	list[char*] fields   # field names (FKs by field name)
	int unique
	int line


struct orm_schema_check:
	char* name
	char* sql
	int line


struct orm_schema_model:
	char* name
	char* table
	int history
	int custom_pk        # 1 when a field carries the pk option (no auto id)
	list[orm_schema_field*] fields     # declaration order, id first
	list[orm_schema_field*] reverse    # reverse relations, appended after fields
	list[orm_schema_enum*] enums
	list[orm_schema_index*] indexes
	list[orm_schema_check*] checks
	list[list[char*]] unique_together  # field names
	int line
	int emitted          # dependency sort scratch


struct orm_schema:
	char* app
	char* path
	list[orm_schema_model*] models     # declaration order
	list[orm_schema_model*] ordered    # FK dependency order (ties: declaration order)
	list[char*] errors                 # "file:line: message"


# ---------------------------------------------------------------------------
# Small helpers

void orm_schema_error(orm_schema* s, int line, char* message):
	string_builder* b = string_new()
	string_append(b, s.path)
	string_append_char(b, ':')
	string_append_int(b, line)
	string_append(b, c": ")
	string_append(b, message)
	s.errors.push(b.data)
	free(cast(void*, b))


void orm_schema_error2(orm_schema* s, int line, char* a, char* b, char* c):
	string_builder* sb = string_new()
	string_append(sb, a)
	string_append(sb, b)
	string_append(sb, c)
	orm_schema_error(s, line, sb.data)
	string_free(sb)


int orm_schema_streq(char* a, char* b):
	if (a == 0 || b == 0): return 0
	return strcmp(a, b) == 0


int orm_schema_is_ident(char* s):
	if (s == 0 || s[0] == 0): return 0
	if (!(isalpha(s[0]) || s[0] == '_')): return 0
	int i = 1
	while (s[i] != 0):
		if (!(isalnum(s[i]) || s[i] == '_')): return 0
		i = i + 1
	return 1


# Non-negative decimal integer; -1 when s is not one.
int orm_schema_parse_uint(char* s):
	if (s == 0 || s[0] == 0): return -1
	int v = 0
	int i = 0
	while (s[i] != 0):
		if (!isdigit(s[i])): return -1
		if (v > 100000000): return -1
		v = v * 10 + (s[i] - '0')
		i = i + 1
	return v


# Optional sign, digits, optional fraction.
int orm_schema_is_number(char* s, int allow_fraction):
	int i = 0
	if (s[0] == '-' || s[0] == '+'): i = 1
	int digits = 0
	while (isdigit(s[i])):
		i = i + 1
		digits = digits + 1
	if (s[i] == '.' && allow_fraction):
		i = i + 1
		while (isdigit(s[i])):
			i = i + 1
			digits = digits + 1
	return digits > 0 && s[i] == 0


char* orm_schema_lower(char* s):
	char* out = strclone(s)
	int i = 0
	while (out[i] != 0):
		out[i] = tolower(out[i])
		i = i + 1
	return out


char* orm_schema_concat3(char* a, char* b, char* c):
	string_builder* sb = string_new()
	string_append(sb, a)
	string_append(sb, b)
	string_append(sb, c)
	char* r = sb.data
	free(cast(void*, sb))
	return r


# W keywords and builtin type names that cannot name a struct member.
int orm_schema_is_reserved(char* name):
	char* words = c" if else elif while for in return break continue struct import new cast sizeof int char byte void float double long short bool string list map set fn type const and or not true false null enum union match case default static extern this self "
	string_builder* sb = string_new()
	string_append_char(sb, ' ')
	string_append(sb, name)
	string_append_char(sb, ' ')
	int found = contains(words, sb.data)
	string_free(sb)
	return found


# Splits on whitespace; "double quoted" runs keep their spaces (the quotes
# are dropped, \" and \\ escape).
list[char*] orm_schema_tokens(char* s):
	list[char*] out = new list[char*]
	int i = 0
	while (s[i] != 0):
		while (s[i] == ' ' || s[i] == 9): i = i + 1
		if (s[i] == 0): break
		string_builder* tok = string_new()
		while (s[i] != 0 && s[i] != ' ' && s[i] != 9):
			if (s[i] == '"'):
				i = i + 1
				while (s[i] != 0 && s[i] != '"'):
					if (s[i] == '\\' && s[i + 1] != 0): i = i + 1
					string_append_char(tok, s[i])
					i = i + 1
				if (s[i] == '"'): i = i + 1
			else:
				string_append_char(tok, s[i])
				i = i + 1
		out.push(tok.data)
		free(cast(void*, tok))
	return out


# Removes a '#' comment that is not inside double quotes, then trailing blanks.
char* orm_schema_strip_comment(char* line):
	int i = 0
	int quoted = 0
	int end = strlen(line)
	while (line[i] != 0):
		if (line[i] == '"'): quoted = !quoted
		if (line[i] == '#' && !quoted):
			end = i
			break
		i = i + 1
	while (end > 0 && (line[end - 1] == ' ' || line[end - 1] == 9 || line[end - 1] == 13)): end = end - 1
	return str_copy_range(line, 0, end)


# Splits "key=value"; returns the value (0 when there is no '=') and stores
# the key in *key.
char* orm_schema_option(char* tok, char** key):
	int eq = index_of(tok, c"=")
	if (eq < 0):
		key[0] = tok
		return 0
	key[0] = str_copy_range(tok, 0, eq)
	return substring(tok, eq + 1, strlen(tok))


# ---------------------------------------------------------------------------
# Model lookups

orm_schema_model* orm_schema_find_model(orm_schema* s, char* name):
	for orm_schema_model* m in s.models:
		if (orm_schema_streq(m.name, name)): return m
	return 0


orm_schema_field* orm_schema_find_field(orm_schema_model* m, char* name):
	for orm_schema_field* f in m.fields:
		if (orm_schema_streq(f.name, name)): return f
	for orm_schema_field* r in m.reverse:
		if (orm_schema_streq(r.name, name)): return r
	return 0


orm_schema_enum* orm_schema_find_enum(orm_schema_model* m, char* name):
	for orm_schema_enum* e in m.enums:
		if (orm_schema_streq(e.name, name)): return e
	return 0


# 1 when the kind stores an int in the row struct (C2).
int orm_schema_int_backed(int kind):
	return kind == ORM_SCHEMA_INT || kind == ORM_SCHEMA_BIGINT || kind == ORM_SCHEMA_BOOL || kind == ORM_SCHEMA_FK


int orm_schema_has_column(orm_schema_field* f):
	return f.kind != ORM_SCHEMA_M2M && f.kind != ORM_SCHEMA_REVERSE_FK


# The SQL column of a field ("author_id" for an FK), or 0 for relations.
char* orm_schema_column(orm_schema_field* f):
	if (!orm_schema_has_column(f)): return 0
	if (f.kind == ORM_SCHEMA_FK): return orm_schema_concat3(f.name, c"_id", c"")
	return f.name


# Kind for a builtin type keyword, or 0.
int orm_schema_builtin_kind(char* t):
	if (orm_schema_streq(t, c"string") || orm_schema_streq(t, c"text")): return ORM_SCHEMA_TEXT
	if (orm_schema_streq(t, c"int")): return ORM_SCHEMA_INT
	if (orm_schema_streq(t, c"bigint")): return ORM_SCHEMA_BIGINT
	if (orm_schema_streq(t, c"bool")): return ORM_SCHEMA_BOOL
	if (orm_schema_streq(t, c"decimal")): return ORM_SCHEMA_DECIMAL
	if (orm_schema_streq(t, c"datetime")): return ORM_SCHEMA_DATETIME
	if (orm_schema_streq(t, c"date")): return ORM_SCHEMA_DATE
	if (orm_schema_streq(t, c"uuid")): return ORM_SCHEMA_UUID
	if (orm_schema_streq(t, c"json")): return ORM_SCHEMA_JSON
	if (orm_schema_streq(t, c"float")): return ORM_SCHEMA_FLOAT
	return 0


orm_schema_field* orm_schema_field_new(char* name, char* type_name, int kind, int line):
	orm_schema_field* f = new orm_schema_field()
	f.name = name
	f.type_name = type_name
	f.kind = kind
	f.line = line
	return f


orm_schema_model* orm_schema_model_new(orm_schema* s, char* name, int line):
	orm_schema_model* m = new orm_schema_model()
	m.name = name
	m.line = line
	m.fields = new list[orm_schema_field*]
	m.reverse = new list[orm_schema_field*]
	m.enums = new list[orm_schema_enum*]
	m.indexes = new list[orm_schema_index*]
	m.checks = new list[orm_schema_check*]
	m.unique_together = new list[list[char*]]
	return m


# ---------------------------------------------------------------------------
# Line parsing

void orm_schema_parse_enum(orm_schema* s, orm_schema_model* m, char* rest, int line):
	# rest is "Name: a, b, c"
	int colon = index_of(rest, c":")
	if (colon < 0):
		orm_schema_error(s, line, c"enum needs 'enum Name: value, ...'")
		return
	char* name = strip(str_copy_range(rest, 0, colon))
	if (!orm_schema_is_ident(name)):
		orm_schema_error2(s, line, c"bad enum name '", name, c"'")
		return
	if (orm_schema_find_enum(m, name) != 0 || orm_schema_builtin_kind(name) != 0):
		orm_schema_error2(s, line, c"duplicate enum '", name, c"'")
		return
	if (orm_schema_streq(name, c"f")):
		orm_schema_error(s, line, c"enum name 'f' clashes with field handles")
		return
	orm_schema_enum* e = new orm_schema_enum()
	e.name = name
	e.line = line
	e.values = new list[char*]
	list[char*] parts = split(substring(rest, colon + 1, strlen(rest)), ',')
	for char* raw in parts:
		char* v = strip(raw)
		if (!orm_schema_is_ident(v)):
			orm_schema_error2(s, line, c"bad enum value '", v, c"'")
			return
		for char* seen in e.values:
			if (orm_schema_streq(seen, v)):
				orm_schema_error2(s, line, c"duplicate enum value '", v, c"'")
				return
		e.values.push(v)
	m.enums.push(e)


# Field names must be W identifiers usable as struct members and lookup
# path segments.
int orm_schema_check_name(orm_schema* s, char* name, int line):
	if (!orm_schema_is_ident(name)):
		orm_schema_error2(s, line, c"bad field name '", name, c"'")
		return 0
	if (contains(name, c"__")):
		orm_schema_error2(s, line, c"field name '", name, c"' may not contain '__'")
		return 0
	if (orm_schema_is_reserved(name)):
		orm_schema_error2(s, line, c"field name '", name, c"' is reserved")
		return 0
	return 1


# Struct member names a field occupies besides its own name.
int orm_schema_member_taken(orm_schema_model* m, char* name):
	for orm_schema_field* f in m.fields:
		if (orm_schema_streq(f.name, name)): return 1
		if (f.kind == ORM_SCHEMA_FK && orm_schema_streq(orm_schema_column(f), name)): return 1
	return 0


void orm_schema_add_field(orm_schema* s, orm_schema_model* m, orm_schema_field* f):
	int clash = orm_schema_member_taken(m, f.name)
	if (f.kind == ORM_SCHEMA_FK && orm_schema_member_taken(m, orm_schema_column(f))): clash = 1
	if (clash):
		orm_schema_error2(s, f.line, c"duplicate field '", f.name, c"'")
		return
	m.fields.push(f)


int orm_schema_on_delete(char* v):
	if (orm_schema_streq(v, c"cascade")): return ORM_SCHEMA_CASCADE
	if (orm_schema_streq(v, c"protect")): return ORM_SCHEMA_PROTECT
	if (orm_schema_streq(v, c"restrict")): return ORM_SCHEMA_RESTRICT
	if (orm_schema_streq(v, c"set_null")): return ORM_SCHEMA_SET_NULL
	if (orm_schema_streq(v, c"set_default")): return ORM_SCHEMA_SET_DEFAULT
	if (orm_schema_streq(v, c"do_nothing")): return ORM_SCHEMA_DO_NOTHING
	return 0


char* orm_schema_sql_quote(char* v):
	string_builder* b = string_new()
	string_append_char(b, 39)
	int i = 0
	while (v[i] != 0):
		if (v[i] == 39): string_append_char(b, 39)
		string_append_char(b, v[i])
		i = i + 1
	string_append_char(b, 39)
	char* r = b.data
	free(cast(void*, b))
	return r


# The SQL default expression for `default=<v>` on field f, or 0 (error
# reported) when v does not fit the kind.
char* orm_schema_default_sql(orm_schema* s, orm_schema_field* f, char* v):
	int k = f.kind
	if (orm_schema_streq(v, c"null")):
		if ((f.flags & ORM_SCHEMA_F_NULL) == 0):
			orm_schema_error2(s, f.line, c"default=null needs 'null' on field '", f.name, c"'")
			return 0
		return c"NULL"
	if (k == ORM_SCHEMA_INT || k == ORM_SCHEMA_BIGINT || k == ORM_SCHEMA_FK):
		if (!orm_schema_is_number(v, 0)):
			orm_schema_error2(s, f.line, c"bad default '", v, c"' for an integer field")
			return 0
		return v
	if (k == ORM_SCHEMA_FLOAT || k == ORM_SCHEMA_DECIMAL):
		if (!orm_schema_is_number(v, 1)):
			orm_schema_error2(s, f.line, c"bad default '", v, c"' for a number field")
			return 0
		return v
	if (k == ORM_SCHEMA_BOOL):
		if (orm_schema_streq(v, c"true") || orm_schema_streq(v, c"1")): return c"TRUE"
		if (orm_schema_streq(v, c"false") || orm_schema_streq(v, c"0")): return c"FALSE"
		orm_schema_error2(s, f.line, c"bad default '", v, c"' for a bool field")
		return 0
	if (k == ORM_SCHEMA_DATETIME && orm_schema_streq(v, c"now")): return c"CURRENT_TIMESTAMP"
	if (k == ORM_SCHEMA_DATE && orm_schema_streq(v, c"now")): return c"CURRENT_DATE"
	if (k == ORM_SCHEMA_ENUM):
		int found = 0
		for char* ev in f.enum_type.values:
			if (orm_schema_streq(ev, v)): found = 1
		if (!found):
			orm_schema_error2(s, f.line, c"default '", v, c"' is not a value of the enum")
			return 0
	return orm_schema_sql_quote(v)


# Applies option tokens [start..] to a scalar or FK field.
void orm_schema_field_options(orm_schema* s, orm_schema_model* m, orm_schema_field* f, list[char*] toks, int start):
	char* default_value = 0
	int i = start
	while (i < toks.length):
		char* key = 0
		char* value = orm_schema_option(toks[i], &key)
		i = i + 1
		int k = f.kind
		int is_text = k == ORM_SCHEMA_TEXT
		if (value == 0):
			if (orm_schema_streq(key, c"null")): f.flags = f.flags | ORM_SCHEMA_F_NULL
			else if (orm_schema_streq(key, c"unique")): f.flags = f.flags | ORM_SCHEMA_F_UNIQUE
			else if (orm_schema_streq(key, c"indexed")): f.flags = f.flags | ORM_SCHEMA_F_INDEXED
			else if (orm_schema_streq(key, c"deprecated")): f.flags = f.flags | ORM_SCHEMA_F_DEPRECATED
			else if (orm_schema_streq(key, c"no_history")): f.flags = f.flags | ORM_SCHEMA_F_NO_HISTORY
			else if (orm_schema_streq(key, c"read_only")): f.flags = f.flags | ORM_SCHEMA_F_READ_ONLY
			else if (orm_schema_streq(key, c"pk") && k != ORM_SCHEMA_FK): f.flags = f.flags | ORM_SCHEMA_F_PK
			else if ((orm_schema_streq(key, c"auto_now") || orm_schema_streq(key, c"auto_now_add")) && (k == ORM_SCHEMA_DATETIME || k == ORM_SCHEMA_DATE)):
				if (orm_schema_streq(key, c"auto_now")): f.flags = f.flags | ORM_SCHEMA_F_AUTO_NOW
				else:
					f.flags = f.flags | ORM_SCHEMA_F_AUTO_NOW_ADD
			else:
				orm_schema_error2(s, f.line, c"bad option '", key, c"'")
			continue
		if (orm_schema_streq(key, c"max_length") && is_text && orm_schema_streq(f.type_name, c"string")):
			f.max_length = orm_schema_parse_uint(value)
			if (f.max_length <= 0):
				orm_schema_error2(s, f.line, c"bad option 'max_length=", value, c"'")
				f.max_length = 0
		else if (orm_schema_streq(key, c"digits") && k == ORM_SCHEMA_DECIMAL):
			f.digits = orm_schema_parse_uint(value)
			if (f.digits <= 0):
				orm_schema_error2(s, f.line, c"bad option 'digits=", value, c"'")
				f.digits = 0
		else if (orm_schema_streq(key, c"places") && k == ORM_SCHEMA_DECIMAL):
			f.places = orm_schema_parse_uint(value)
			if (f.places < 0):
				orm_schema_error2(s, f.line, c"bad option 'places=", value, c"'")
				f.places = 0
		else if (orm_schema_streq(key, c"default")):
			default_value = value
		else if (orm_schema_streq(key, c"on_delete") && k == ORM_SCHEMA_FK):
			f.on_delete = orm_schema_on_delete(value)
			f.has_on_delete = 1
			if (f.on_delete == 0):
				orm_schema_error2(s, f.line, c"bad option 'on_delete=", value, c"'")
		else if (orm_schema_streq(key, c"related_name") && k == ORM_SCHEMA_FK):
			if (!orm_schema_check_name(s, value, f.line)): continue
			f.related_name = value
		else:
			orm_schema_error2(s, f.line, c"bad option '", key, c"'")
	if (f.places > f.digits && f.digits > 0):
		orm_schema_error2(s, f.line, c"places exceeds digits on field '", f.name, c"'")
	if ((f.flags & ORM_SCHEMA_F_PK) != 0 && (f.flags & ORM_SCHEMA_F_NULL) != 0):
		orm_schema_error2(s, f.line, c"primary key '", f.name, c"' cannot be null")
	# Defaults are checked after the flags they depend on (null).
	if (default_value != 0):
		f.default_sql = orm_schema_default_sql(s, f, default_value)
	if (f.kind == ORM_SCHEMA_FK):
		if (!f.has_on_delete): f.on_delete = ORM_SCHEMA_PROTECT
		if (f.on_delete == ORM_SCHEMA_SET_NULL && (f.flags & ORM_SCHEMA_F_NULL) == 0):
			orm_schema_error2(s, f.line, c"on_delete=set_null needs 'null' on field '", f.name, c"'")
		if (f.on_delete == ORM_SCHEMA_SET_DEFAULT && f.default_sql == 0):
			orm_schema_error2(s, f.line, c"on_delete=set_default needs a default on field '", f.name, c"'")


# "fk name -> Model opts" / "m2m name -> Model".
void orm_schema_parse_relation(orm_schema* s, orm_schema_model* m, list[char*] toks, int kind, int line):
	if (toks.length < 4 || !orm_schema_streq(toks[2], c"->")):
		orm_schema_error2(s, line, c"expected '", toks[0], c" <name> -> <Model>'")
		return
	if (!orm_schema_check_name(s, toks[1], line)): return
	if (!orm_schema_is_ident(toks[3])):
		orm_schema_error2(s, line, c"bad model name '", toks[3], c"'")
		return
	orm_schema_field* f = orm_schema_field_new(toks[1], toks[0], kind, line)
	f.rel_model = toks[3]
	if (kind == ORM_SCHEMA_FK):
		f.flags = ORM_SCHEMA_F_INDEXED
		orm_schema_field_options(s, m, f, toks, 4)
	else if (toks.length > 4):
		orm_schema_error2(s, line, c"bad option '", toks[4], c"'")
	orm_schema_add_field(s, m, f)


# Field-name lists for index / unique_together; name= is taken out.
list[char*] orm_schema_name_list(orm_schema* s, list[char*] toks, char** name_out, int line):
	list[char*] names = new list[char*]
	int i = 1
	while (i < toks.length):
		char* key = 0
		char* value = orm_schema_option(toks[i], &key)
		if (value != 0):
			if (orm_schema_streq(key, c"name") && name_out != 0 && orm_schema_is_ident(value)): name_out[0] = value
			else:
				orm_schema_error2(s, line, c"bad option '", toks[i], c"'")
		else:
			names.push(toks[i])
		i = i + 1
	if (names.length == 0):
		orm_schema_error2(s, line, c"'", toks[0], c"' needs at least one field")
	return names


void orm_schema_parse_model_line(orm_schema* s, orm_schema_model* m, char* text, int line):
	list[char*] toks = orm_schema_tokens(text)
	char* head = toks[0]
	if (orm_schema_streq(head, c"enum")):
		orm_schema_parse_enum(s, m, strip(substring(text, 4, strlen(text))), line)
		return
	if (orm_schema_streq(head, c"fk")):
		orm_schema_parse_relation(s, m, toks, ORM_SCHEMA_FK, line)
		return
	if (orm_schema_streq(head, c"m2m")):
		orm_schema_parse_relation(s, m, toks, ORM_SCHEMA_M2M, line)
		return
	if (orm_schema_streq(head, c"history")):
		if (toks.length != 1): orm_schema_error(s, line, c"'history' takes no arguments")
		m.history = 1
		return
	if (starts_with_at(head, c"table=", 0)):
		char* t = substring(head, 6, strlen(head))
		if (toks.length != 1 || !orm_schema_is_ident(t)):
			orm_schema_error2(s, line, c"bad table name '", t, c"'")
			return
		m.table = t
		return
	if (orm_schema_streq(head, c"index")):
		orm_schema_index* idx = new orm_schema_index()
		idx.line = line
		idx.fields = orm_schema_name_list(s, toks, &idx.name, line)
		m.indexes.push(idx)
		return
	if (orm_schema_streq(head, c"unique_together")):
		list[char*] names = orm_schema_name_list(s, toks, 0, line)
		if (names.length < 2):
			orm_schema_error(s, line, c"'unique_together' needs at least two fields")
			return
		m.unique_together.push(names)
		return
	if (orm_schema_streq(head, c"check")):
		orm_schema_check* chk = new orm_schema_check()
		chk.line = line
		char* body = strip(substring(text, 5, strlen(text)))
		char* last = toks[toks.length - 1]
		if (toks.length > 1 && starts_with_at(last, c"name=", 0)):
			chk.name = substring(last, 5, strlen(last))
			int cut = rindex_of(body, c"name=")
			body = strip(substring(body, 0, cut))
			if (!orm_schema_is_ident(chk.name)):
				orm_schema_error2(s, line, c"bad check name '", chk.name, c"'")
				return
		if (body[0] == 0):
			orm_schema_error(s, line, c"'check' needs a SQL condition")
			return
		chk.sql = body
		m.checks.push(chk)
		return
	# "<type> <name> options..."
	if (toks.length < 2):
		orm_schema_error2(s, line, c"expected '<type> <name>' after '", head, c"'")
		return
	int kind = orm_schema_builtin_kind(head)
	orm_schema_enum* e = 0
	if (kind == 0):
		e = orm_schema_find_enum(m, head)
		if (e == 0):
			orm_schema_error2(s, line, c"unknown type '", head, c"'")
			return
		kind = ORM_SCHEMA_ENUM
	if (!orm_schema_check_name(s, toks[1], line)): return
	orm_schema_field* f = orm_schema_field_new(toks[1], head, kind, line)
	f.enum_type = e
	if (e != 0):
		for char* v in e.values:
			if (strlen(v) > f.max_length): f.max_length = strlen(v)
	orm_schema_field_options(s, m, f, toks, 2)
	orm_schema_add_field(s, m, f)


# ---------------------------------------------------------------------------
# Whole-file checks after parsing

int orm_schema_validate_field_list(orm_schema* s, orm_schema_model* m, list[char*] names, char* what, int line):
	int ok = 1
	for char* n in names:
		orm_schema_field* f = orm_schema_find_field(m, n)
		if (f == 0):
			orm_schema_error2(s, line, what, c" names unknown field ", n)
			ok = 0
		else if (!orm_schema_has_column(f)):
			orm_schema_error2(s, line, what, c" names relation without a column ", n)
			ok = 0
	return ok


# FK columns store an int (C2), so relation targets need an int-backed pk.
int orm_schema_int_pk(orm_schema_model* m):
	for orm_schema_field* f in m.fields:
		if ((f.flags & ORM_SCHEMA_F_PK) != 0): return f.kind == ORM_SCHEMA_INT || f.kind == ORM_SCHEMA_BIGINT
	return 1


char* orm_schema_api_names():
	return c" desc objects rows new save delete free "


void orm_schema_resolve(orm_schema* s):
	for orm_schema_model* m in s.models:
		if (m.table == 0):
			m.table = orm_schema_concat3(s.app, c"_", orm_schema_lower(m.name))
		int pks = 0
		for orm_schema_field* f in m.fields:
			if ((f.flags & ORM_SCHEMA_F_PK) != 0): pks = pks + 1
		if (pks > 1):
			orm_schema_error2(s, m.line, c"model '", m.name, c"' declares more than one pk")
		if (pks == 0):
			if (orm_schema_member_taken(m, c"id")):
				orm_schema_error2(s, m.line, c"model '", m.name, c"' has a field 'id' but no pk")
			else:
				orm_schema_field* id = orm_schema_field_new(c"id", c"int", ORM_SCHEMA_INT, m.line)
				id.flags = ORM_SCHEMA_F_PK | ORM_SCHEMA_F_AUTO
				m.fields.insert(0, id)
		else:
			m.custom_pk = 1
	for orm_schema_model* m in s.models:
		for orm_schema_field* f in m.fields:
			if (f.kind != ORM_SCHEMA_FK && f.kind != ORM_SCHEMA_M2M): continue
			string_builder* api = string_new()
			string_append_char(api, ' ')
			string_append(api, f.name)
			string_append_char(api, ' ')
			if (contains(orm_schema_api_names(), api.data)):
				orm_schema_error2(s, f.line, c"relation name '", f.name, c"' clashes with a generated function")
			string_free(api)
			orm_schema_model* t = orm_schema_find_model(s, f.rel_model)
			if (t == 0):
				if (f.kind == ORM_SCHEMA_FK): orm_schema_error2(s, f.line, c"unknown FK target '", f.rel_model, c"'")
				else:
					orm_schema_error2(s, f.line, c"unknown M2M target '", f.rel_model, c"'")
				continue
			if (!orm_schema_int_pk(t)):
				orm_schema_error2(s, f.line, c"relation target '", f.rel_model, c"' needs an int pk")
				continue
			if (f.kind == ORM_SCHEMA_FK && f.related_name != 0):
				if (orm_schema_member_taken(t, f.related_name) || orm_schema_find_field(t, f.related_name) != 0):
					orm_schema_error2(s, f.line, c"related_name '", f.related_name, c"' clashes with a field of the target")
					continue
				orm_schema_field* r = orm_schema_field_new(f.related_name, c"reverse", ORM_SCHEMA_REVERSE_FK, f.line)
				r.rel_model = m.name
				r.reverse_field = f.name
				t.reverse.push(r)
	for orm_schema_model* m in s.models:
		for orm_schema_index* idx in m.indexes:
			if (orm_schema_validate_field_list(s, m, idx.fields, c"index", idx.line) && idx.name == 0):
				string_builder* nb = string_new()
				string_append(nb, m.table)
				for char* n in idx.fields:
					string_append_char(nb, '_')
					string_append(nb, orm_schema_column(orm_schema_find_field(m, n)))
				string_append(nb, c"_idx")
				idx.name = nb.data
				free(cast(void*, nb))
		for list[char*] ut in m.unique_together:
			orm_schema_validate_field_list(s, m, ut, c"unique_together", m.line)
		int k = 0
		for orm_schema_check* chk in m.checks:
			k = k + 1
			if (chk.name == 0):
				string_builder* cb = string_new()
				string_append(cb, m.table)
				string_append(cb, c"_check")
				string_append_int(cb, k)
				chk.name = cb.data
				free(cast(void*, cb))


# 1 when every FK of m targets an already-emitted model (self-FKs ignored).
int orm_schema_ready(orm_schema* s, orm_schema_model* m):
	for orm_schema_field* f in m.fields:
		if (f.kind != ORM_SCHEMA_FK || orm_schema_streq(f.rel_model, m.name)): continue
		orm_schema_model* t = orm_schema_find_model(s, f.rel_model)
		if (t != 0 && !t.emitted): return 0
	return 1


# FK dependency order; ties keep declaration order. A cycle is broken by
# taking the earliest remaining model (its unordered FK slots are void*).
void orm_schema_order(orm_schema* s):
	s.ordered = new list[orm_schema_model*]
	while (s.ordered.length < s.models.length):
		orm_schema_model* pick = 0
		for orm_schema_model* m in s.models:
			if (pick == 0 && !m.emitted && orm_schema_ready(s, m)): pick = m
		if (pick == 0):
			for orm_schema_model* m2 in s.models:
				if (pick == 0 && !m2.emitted): pick = m2
		pick.emitted = 1
		s.ordered.push(pick)


# 1 when model `name` comes before model `before` in s.ordered.
int orm_schema_ordered_before(orm_schema* s, char* name, char* before):
	for orm_schema_model* m in s.ordered:
		if (orm_schema_streq(m.name, before)): return 0
		if (orm_schema_streq(m.name, name)): return 1
	return 0


# ---------------------------------------------------------------------------
# Entry point

orm_schema* orm_schema_parse(char* text, char* path):
	orm_schema* s = new orm_schema()
	s.path = path
	s.models = new list[orm_schema_model*]
	s.ordered = new list[orm_schema_model*]
	s.errors = new list[char*]
	orm_schema_model* current = 0
	int line_no = 0
	int pos = 0
	while (text[pos] != 0):
		int end = pos
		while (text[end] != 0 && text[end] != 10): end = end + 1
		char* raw = str_copy_range(text, pos, end)
		pos = end
		if (text[pos] == 10): pos = pos + 1
		line_no = line_no + 1
		char* line = orm_schema_strip_comment(raw)
		int depth = 0
		while (line[depth] == 9): depth = depth + 1
		if (line[depth] == 0): continue
		if (line[depth] == ' '):
			orm_schema_error(s, line_no, c"indent with tabs, not spaces")
			continue
		char* body = substring(line, depth, strlen(line))
		if (depth == 0):
			list[char*] toks = orm_schema_tokens(body)
			if (orm_schema_streq(toks[0], c"app")):
				if (toks.length != 2 || !orm_schema_is_ident(toks[1])):
					orm_schema_error(s, line_no, c"expected 'app <name>'")
				else if (s.app != 0):
					orm_schema_error(s, line_no, c"duplicate 'app' line")
				else:
					s.app = toks[1]
				current = 0
				continue
			if (orm_schema_streq(toks[0], c"model")):
				current = 0
				char* name = c""
				if (toks.length == 2): name = toks[1]
				int n = strlen(name)
				if (n < 2 || name[n - 1] != ':'):
					orm_schema_error(s, line_no, c"expected 'model <Name>:'")
					continue
				name = str_copy_range(name, 0, n - 1)
				if (!orm_schema_is_ident(name) || contains(name, c"__")):
					orm_schema_error2(s, line_no, c"bad model name '", name, c"'")
					continue
				if (orm_schema_find_model(s, name) != 0):
					orm_schema_error2(s, line_no, c"duplicate model '", name, c"'")
					continue
				current = orm_schema_model_new(s, name, line_no)
				s.models.push(current)
				continue
			orm_schema_error2(s, line_no, c"unknown declaration '", toks[0], c"'")
			current = 0
			continue
		if (depth > 1):
			orm_schema_error(s, line_no, c"unexpected indentation")
			continue
		if (current == 0):
			orm_schema_error(s, line_no, c"indented line outside a model")
			continue
		orm_schema_parse_model_line(s, current, body, line_no)
	if (s.app == 0):
		orm_schema_error(s, 1, c"missing 'app <name>' line")
		s.app = c"app"
	orm_schema_resolve(s)
	orm_schema_order(s)
	return s
