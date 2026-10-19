# w-orm migration linter (issue #754, unit U2.3).
#
# orm_lint_migration checks one orm_migration (contract C7) against the safe
# expand / contract rules of docs/projects/orm/u2_3.md and returns findings
# with stable codes W-ORM-M001 ... W-ORM-M011. An op marked unsafe = 1 (the
# migration author passed force) downgrades its errors to warnings.
#
# This file also holds the small helpers the planner shares with it: op
# kind / phase names, the field_json key reader and writer, and a tokenizer
# for the obvious ALTER / CREATE / DROP shapes of ORM_OP_RAW_SQL text.
import libs.standard.orm.contract
import lib.str
import structures.string


const int ORM_LINT_WARNING = 1
const int ORM_LINT_ERROR = 2


struct orm_lint_finding:
	char* code          # "W-ORM-M001"
	int severity        # ORM_LINT_ERROR / ORM_LINT_WARNING
	char* message
	int op_index        # index into migration.ops, -1 for the migration itself


# ---------------------------------------------------------------------------
# Names

char* orm_op_kind_name(int kind):
	if (kind == ORM_OP_CREATE_TABLE): return c"CREATE_TABLE"
	if (kind == ORM_OP_DROP_TABLE): return c"DROP_TABLE"
	if (kind == ORM_OP_ADD_COLUMN): return c"ADD_COLUMN"
	if (kind == ORM_OP_DROP_COLUMN): return c"DROP_COLUMN"
	if (kind == ORM_OP_ALTER_NULL): return c"ALTER_NULL"
	if (kind == ORM_OP_ADD_INDEX): return c"ADD_INDEX"
	if (kind == ORM_OP_DROP_INDEX): return c"DROP_INDEX"
	if (kind == ORM_OP_ADD_CONSTRAINT): return c"ADD_CONSTRAINT"
	if (kind == ORM_OP_VALIDATE_CONSTRAINT): return c"VALIDATE_CONSTRAINT"
	if (kind == ORM_OP_DROP_CONSTRAINT): return c"DROP_CONSTRAINT"
	if (kind == ORM_OP_COPY_COLUMN): return c"COPY_COLUMN"
	if (kind == ORM_OP_SYNC_TRIGGER): return c"SYNC_TRIGGER"
	if (kind == ORM_OP_DROP_SYNC_TRIGGER): return c"DROP_SYNC_TRIGGER"
	if (kind == ORM_OP_COPY_TABLE): return c"COPY_TABLE"
	if (kind == ORM_OP_SWAP_TABLES): return c"SWAP_TABLES"
	if (kind == ORM_OP_BACKFILL): return c"BACKFILL"
	if (kind == ORM_OP_RAW_SQL): return c"RAW_SQL"
	if (kind == ORM_OP_RENAME_TABLE): return c"RENAME_TABLE"
	if (kind == ORM_OP_CREATE_HISTORY): return c"CREATE_HISTORY"
	if (kind == ORM_OP_DROP_HISTORY): return c"DROP_HISTORY"
	return c"UNKNOWN"


char* orm_phase_name(int phase):
	if (phase == ORM_PHASE_EXPAND): return c"expand"
	if (phase == ORM_PHASE_MIGRATE): return c"migrate"
	if (phase == ORM_PHASE_CONTRACT): return c"contract"
	return c"unknown"


# ---------------------------------------------------------------------------
# field_json helpers: top-level keys of a JSON object, values kept as their
# literal text ("true", "\"x\"", "[1, 2]").

int orm_mjson_ws(char* s, int i):
	while (s[i] == ' ' || s[i] == 9 || s[i] == 10 || s[i] == 13): i = i + 1
	return i


int orm_mjson_skip_string(char* s, int i):
	# s[i] is the opening quote; returns the index after the closing one.
	i = i + 1
	while (s[i] != 0 && s[i] != '"'):
		if (s[i] == 92 && s[i + 1] != 0): i = i + 2
		else: i = i + 1
	if (s[i] == '"'): i = i + 1
	return i


int orm_mjson_skip_value(char* s, int i):
	if (s[i] == '"'): return orm_mjson_skip_string(s, i)
	if (s[i] == '{' || s[i] == '['):
		int depth = 0
		while (s[i] != 0):
			char c = s[i]
			if (c == '"'):
				i = orm_mjson_skip_string(s, i)
				continue
			if (c == '{' || c == '['): depth = depth + 1
			if (c == '}' || c == ']'): depth = depth - 1
			i = i + 1
			if (depth == 0): return i
		return i
	while (s[i] != 0 && s[i] != ',' && s[i] != '}' && s[i] != ']' && s[i] != ' ' && s[i] != 9 && s[i] != 10 && s[i] != 13):
		i = i + 1
	return i


# Finds key at the top level of the object `json`. Returns 1 and the value's
# [*start, *end) span, or 0.
int orm_mjson_find(char* json, char* key, int* start, int* end):
	if (json == 0): return 0
	int i = orm_mjson_ws(json, 0)
	if (json[i] != '{'): return 0
	i = i + 1
	int klen = strlen(key)
	while (1):
		i = orm_mjson_ws(json, i)
		if (json[i] != '"'): return 0
		int kstart = i + 1
		int kend = orm_mjson_skip_string(json, i) - 1
		i = orm_mjson_ws(json, kend + 1)
		if (json[i] != ':'): return 0
		i = orm_mjson_ws(json, i + 1)
		int vstart = i
		int vend = orm_mjson_skip_value(json, i)
		if (kend - kstart == klen && starts_with_at(json, key, kstart)):
			start[0] = vstart
			end[0] = vend
			return 1
		i = orm_mjson_ws(json, vend)
		if (json[i] != ','): return 0
		i = i + 1
	return 0


# The literal text of key's value (owned by the caller), or 0 when absent.
char* orm_mjson_get(char* json, char* key):
	int start = 0
	int end = 0
	if (orm_mjson_find(json, key, &start, &end) == 0): return 0
	return str_copy_range(json, start, end)


int orm_mjson_literal_is(char* json, char* key, char* literal):
	int start = 0
	int end = 0
	if (orm_mjson_find(json, key, &start, &end) == 0): return 0
	return end - start == strlen(literal) && starts_with_at(json, literal, start)


int orm_mjson_is_true(char* json, char* key):
	return orm_mjson_literal_is(json, key, c"true")


# 1 when key is present with a value other than null.
int orm_mjson_has_value(char* json, char* key):
	int start = 0
	int end = 0
	if (orm_mjson_find(json, key, &start, &end) == 0): return 0
	return orm_mjson_literal_is(json, key, c"null") == 0


# A new string: json with key set to the literal text `value` (replaced in
# place when present, else inserted first). json may be 0.
char* orm_mjson_set(char* json, char* key, char* value):
	string_builder* b = string_new()
	int start = 0
	int end = 0
	if (orm_mjson_find(json, key, &start, &end)):
		string_append_bytes(b, json, start)
		string_append(b, value)
		string_append(b, &json[end])
	else:
		int i = 0
		if (json != 0): i = orm_mjson_ws(json, 0)
		int rest = -1
		if (json != 0 && json[i] == '{'):
			rest = orm_mjson_ws(json, i + 1)
			if (json[rest] == '}'): rest = -1
		string_append(b, c"{\"")
		string_append(b, key)
		string_append(b, c"\": ")
		string_append(b, value)
		if (rest >= 0):
			string_append(b, c", ")
			string_append(b, &json[rest])
		else:
			string_append(b, c"}")
	char* out = b.data
	free(cast(void*, b))
	return out


# A JSON string literal for s (quotes and backslashes escaped).
char* orm_mjson_quote(char* s):
	string_builder* b = string_new()
	string_append_char(b, '"')
	int i = 0
	while (s[i] != 0):
		if (s[i] == '"' || s[i] == 92): string_append_char(b, 92)
		string_append_char(b, s[i])
		i = i + 1
	string_append_char(b, '"')
	char* out = b.data
	free(cast(void*, b))
	return out


# ---------------------------------------------------------------------------
# RAW_SQL tokenizer: statements (split at top-level ';') of upper-cased words
# and single punctuation characters. Quoted identifiers become one word
# (their text, upper-cased); string literals become "'". Comments are
# skipped. Good enough for the ALTER/CREATE/DROP shapes the linter reads.

int orm_sql_word_char(char c):
	return isalnum(c) || c == '_' || c == '$'


char* orm_sql_upper_range(char* s, int start, int end):
	char* w = str_copy_range(s, start, end)
	int i = 0
	while (w[i] != 0):
		w[i] = toupper(w[i])
		i = i + 1
	return w


list[list[char*]] orm_sql_statements(char* sql):
	list[list[char*]] out = new list[list[char*]]
	list[char*] cur = new list[char*]
	int i = 0
	if (sql == 0): sql = c""
	while (sql[i] != 0):
		char c = sql[i]
		if (isspace(c)):
			i = i + 1
			continue
		if (c == '-' && sql[i + 1] == '-'):
			while (sql[i] != 0 && sql[i] != 10): i = i + 1
			continue
		if (c == '/' && sql[i + 1] == '*'):
			i = i + 2
			while (sql[i] != 0 && (sql[i] != '*' || sql[i + 1] != '/')): i = i + 1
			if (sql[i] != 0): i = i + 2
			continue
		if (c == ';'):
			if (cur.length > 0):
				out.push(cur)
				cur = new list[char*]
			i = i + 1
			continue
		if (c == 39):
			i = i + 1
			while (sql[i] != 0):
				if (sql[i] == 39 && sql[i + 1] == 39): i = i + 2
				else if (sql[i] == 39): break
				else: i = i + 1
			if (sql[i] != 0): i = i + 1
			cur.push(strclone(c"'"))
			continue
		if (c == '"' || c == '`' || c == '['):
			char close = c
			if (c == '['): close = ']'
			int start = i + 1
			i = i + 1
			while (sql[i] != 0 && sql[i] != close): i = i + 1
			cur.push(orm_sql_upper_range(sql, start, i))
			if (sql[i] != 0): i = i + 1
			continue
		if (orm_sql_word_char(c)):
			int start = i
			while (orm_sql_word_char(sql[i])): i = i + 1
			cur.push(orm_sql_upper_range(sql, start, i))
			continue
		cur.push(str_copy_range(sql, i, i + 1))
		i = i + 1
	if (cur.length > 0): out.push(cur)
	else: cur.free()
	return out


void orm_sql_statements_free(list[list[char*]] stmts):
	for list[char*] s in stmts:
		for char* w in s: free(w)
		s.free()
	stmts.free()


int orm_tok_is(list[char*] t, int i, char* word):
	if (i < 0 || i >= t.length): return 0
	return strcmp(t[i], word) == 0


int orm_tok_find(list[char*] t, int start, int end, char* word):
	for i in range(start, end):
		if (strcmp(t[i], word) == 0): return i
	return -1


# 1 when words a, b appear next to each other in t[start:end].
int orm_tok_pair(list[char*] t, int start, int end, char* a, char* b):
	for i in range(start, end - 1):
		if (strcmp(t[i], a) == 0 && strcmp(t[i + 1], b) == 0): return 1
	return 0


# ---------------------------------------------------------------------------
# Linter

struct orm_lint_ctx:
	orm_migration* m
	int dialect_id
	list[orm_lint_finding*] findings
	int has_expand
	int has_validate_before   # a VALIDATE_CONSTRAINT appeared earlier in the migration


void orm_lint_add(orm_lint_ctx* x, int op_index, char* code, int error, char* text):
	orm_lint_finding* f = new orm_lint_finding()
	f.code = code
	f.op_index = op_index
	f.severity = ORM_LINT_WARNING
	if (error): f.severity = ORM_LINT_ERROR
	if (op_index >= 0 && error):
		orm_op* op = x.m.ops[op_index]
		if (op.unsafe): f.severity = ORM_LINT_WARNING
	string_builder* b = string_new()
	if (x.m.name != 0): string_append(b, x.m.name)
	string_append(b, c": ")
	if (op_index >= 0):
		orm_op* op2 = x.m.ops[op_index]
		string_append(b, c"op ")
		string_append_int(b, op_index)
		string_append(b, c" ")
		string_append(b, orm_op_kind_name(op2.kind))
		if (op2.table != 0):
			string_append(b, c" ")
			string_append(b, op2.table)
			if (op2.column != 0):
				string_append(b, c".")
				string_append(b, op2.column)
		string_append(b, c": ")
	string_append(b, text)
	f.message = b.data
	free(cast(void*, b))
	x.findings.push(f)


void orm_lint_destructive(orm_lint_ctx* x, int i, char* what):
	if (x.m.requires_applied == 0):
		string_builder* b = string_new()
		string_append(b, what)
		string_append(b, c" without requires_applied: a destructive step must name the expand migration that has to be applied first")
		orm_lint_add(x, i, c"W-ORM-M006", 1, b.data)
		string_free(b)
	if (x.has_expand):
		string_builder* b2 = string_new()
		string_append(b2, what)
		string_append(b2, c" in the same migration as expand operations: ship it in a later contract migration")
		orm_lint_add(x, i, c"W-ORM-M007", 1, b2.data)
		string_free(b2)


int orm_lint_is_pg(orm_lint_ctx* x):
	return x.dialect_id == ORM_DIALECT_POSTGRES


# One ALTER TABLE clause t[start:end] of a RAW_SQL statement.
void orm_lint_alter_clause(orm_lint_ctx* x, int i, list[char*] t, int start, int end):
	if (start >= end): return
	if (orm_tok_is(t, start, c"RENAME")):
		if (orm_tok_is(t, start + 1, c"TO")):
			orm_lint_add(x, i, c"W-ORM-M001", 1, c"in-place table rename (ALTER TABLE ... RENAME TO): use the table duplication pattern (rename_table change)")
		else if (orm_tok_is(t, start + 1, c"CONSTRAINT") == 0 && orm_tok_is(t, start + 1, c"INDEX") == 0):
			orm_lint_add(x, i, c"W-ORM-M002", 1, c"in-place column rename (ALTER TABLE ... RENAME COLUMN): use the field duplication pattern (rename_column change)")
		return
	if (orm_tok_is(t, start, c"ALTER")):
		int j = start + 1
		if (orm_tok_is(t, j, c"COLUMN")): j = j + 1
		j = j + 1
		if (orm_tok_is(t, j, c"TYPE") || (orm_tok_is(t, j, c"SET") && orm_tok_is(t, j + 1, c"DATA"))):
			orm_lint_add(x, i, c"W-ORM-M003", 1, c"in-place column type change (ALTER COLUMN ... TYPE): use the field duplication pattern (alter_type change)")
		else if (orm_lint_is_pg(x) && orm_tok_is(t, j, c"SET") && orm_tok_is(t, j + 1, c"NOT")):
			orm_lint_add(x, i, c"W-ORM-M011", 0, c"SET NOT NULL scans the table under an exclusive lock: add a CHECK (... IS NOT NULL) NOT VALID and VALIDATE it first")
		return
	if (orm_tok_is(t, start, c"MODIFY") || orm_tok_is(t, start, c"CHANGE")):
		orm_lint_add(x, i, c"W-ORM-M003", 1, c"in-place column type change (MODIFY/CHANGE): use the field duplication pattern (alter_type change)")
		return
	if (orm_tok_is(t, start, c"DROP")):
		orm_lint_destructive(x, i, c"ALTER TABLE ... DROP")
		return
	if (orm_tok_is(t, start, c"ADD")):
		int k = start + 1
		int is_constraint = 0
		if (orm_tok_is(t, k, c"CONSTRAINT") || orm_tok_is(t, k, c"FOREIGN") || orm_tok_is(t, k, c"CHECK") || orm_tok_is(t, k, c"UNIQUE") || orm_tok_is(t, k, c"PRIMARY")):
			is_constraint = 1
		if (is_constraint):
			if (orm_lint_is_pg(x) == 0): return
			int validated = orm_tok_pair(t, start, end, c"NOT", c"VALID") == 0
			if (validated && (orm_tok_find(t, start, end, c"FOREIGN") >= 0 || orm_tok_find(t, start, end, c"CHECK") >= 0)):
				orm_lint_add(x, i, c"W-ORM-M010", 0, c"FOREIGN KEY / CHECK added without NOT VALID scans the table under lock: add it NOT VALID, VALIDATE later")
			if ((orm_tok_find(t, start, end, c"UNIQUE") >= 0 || orm_tok_find(t, start, end, c"PRIMARY") >= 0) && orm_tok_pair(t, start, end, c"USING", c"INDEX") == 0):
				orm_lint_add(x, i, c"W-ORM-M005", 1, c"UNIQUE / PRIMARY KEY constraint builds its index non-concurrently: build it with CREATE UNIQUE INDEX CONCURRENTLY, then ADD CONSTRAINT ... USING INDEX")
			return
		if (orm_tok_pair(t, start, end, c"NOT", c"NULL") && orm_tok_find(t, start, end, c"DEFAULT") < 0):
			orm_lint_add(x, i, c"W-ORM-M004", 1, c"ADD COLUMN ... NOT NULL without a default: add it nullable or with a default, backfill, then tighten")


void orm_lint_raw_statement(orm_lint_ctx* x, int i, list[char*] t):
	if (t.length == 0): return
	if (orm_tok_is(t, 0, c"ALTER") && orm_tok_is(t, 1, c"TABLE")):
		int j = 2
		if (orm_tok_is(t, j, c"IF") && orm_tok_is(t, j + 1, c"EXISTS")): j = j + 2
		if (orm_tok_is(t, j, c"ONLY")): j = j + 1
		j = j + 1
		while (orm_tok_is(t, j, c".")): j = j + 2
		# Clauses separated by top-level commas.
		int depth = 0
		int start = j
		for k in range(j, t.length + 1):
			if (k == t.length || (depth == 0 && strcmp(t[k], c",") == 0)):
				orm_lint_alter_clause(x, i, t, start, k)
				start = k + 1
				continue
			if (strcmp(t[k], c"(") == 0): depth = depth + 1
			if (strcmp(t[k], c")") == 0): depth = depth - 1
		return
	if (orm_tok_is(t, 0, c"RENAME") && orm_tok_is(t, 1, c"TABLE")):
		orm_lint_add(x, i, c"W-ORM-M001", 1, c"in-place table rename (RENAME TABLE): use the table duplication pattern (rename_table change)")
		return
	if (orm_tok_is(t, 0, c"CREATE")):
		int j = 1
		if (orm_tok_is(t, j, c"UNIQUE")): j = j + 1
		if (orm_tok_is(t, j, c"INDEX") == 0): return
		if (orm_tok_is(t, j + 1, c"CONCURRENTLY")):
			if (x.m.atomic):
				orm_lint_add(x, i, c"W-ORM-M008", 1, c"CREATE INDEX CONCURRENTLY cannot run inside a transaction: mark the op non_atomic")
		else if (orm_lint_is_pg(x)):
			orm_lint_add(x, i, c"W-ORM-M005", 1, c"CREATE INDEX without CONCURRENTLY locks writes on PostgreSQL: use CREATE INDEX CONCURRENTLY in a non-atomic migration")
		return
	if (orm_tok_is(t, 0, c"DROP") && (orm_tok_is(t, 1, c"TABLE") || orm_tok_is(t, 1, c"COLUMN"))):
		orm_lint_destructive(x, i, c"raw DROP")


int orm_lint_op_destructive(orm_op* op):
	return op.kind == ORM_OP_DROP_COLUMN || op.kind == ORM_OP_DROP_TABLE || op.kind == ORM_OP_DROP_CONSTRAINT || op.kind == ORM_OP_DROP_HISTORY


void orm_lint_op(orm_lint_ctx* x, int i, orm_op* op):
	int pg = orm_lint_is_pg(x)
	if (x.m.atomic && op.non_atomic):
		orm_lint_add(x, i, c"W-ORM-M008", 1, c"non_atomic op in a migration marked atomic: add ops with orm_migration_add or set atomic = 0")
	if (op.kind == ORM_OP_RENAME_TABLE):
		orm_lint_add(x, i, c"W-ORM-M001", 1, c"in-place table rename: old code still reads the old name; use the table duplication pattern (rename_table change)")
	else if (op.kind == ORM_OP_ADD_COLUMN):
		if (orm_mjson_is_true(op.field_json, c"null") == 0 && orm_mjson_has_value(op.field_json, c"default") == 0):
			orm_lint_add(x, i, c"W-ORM-M004", 1, c"NOT NULL column without a default: add it nullable or with a default, backfill, then tighten")
	else if (op.kind == ORM_OP_ADD_INDEX):
		if (pg && op.non_atomic == 0):
			orm_lint_add(x, i, c"W-ORM-M005", 1, c"non-concurrent index build locks writes on PostgreSQL: set non_atomic = 1 (CREATE INDEX CONCURRENTLY)")
	else if (op.kind == ORM_OP_ALTER_NULL):
		if (pg && orm_mjson_is_true(op.field_json, c"null") == 0 && x.has_validate_before == 0):
			orm_lint_add(x, i, c"W-ORM-M011", 0, c"SET NOT NULL scans the table under an exclusive lock: validate a CHECK (... IS NOT NULL) constraint earlier in this migration")
	else if (op.kind == ORM_OP_SWAP_TABLES):
		if (x.m.atomic == 0):
			orm_lint_add(x, i, c"W-ORM-M009", 1, c"SWAP_TABLES must run in one short transaction: keep it out of non-atomic migrations")
	else if (op.kind == ORM_OP_RAW_SQL):
		list[list[char*]] stmts = orm_sql_statements(op.sql)
		for list[char*] t in stmts: orm_lint_raw_statement(x, i, t)
		orm_sql_statements_free(stmts)
	if (orm_lint_op_destructive(op)):
		orm_lint_destructive(x, i, orm_op_kind_name(op.kind))
	if (op.kind == ORM_OP_VALIDATE_CONSTRAINT): x.has_validate_before = 1


# Findings for one migration, in op order. dialect_id is ORM_DIALECT_SQLITE
# or ORM_DIALECT_POSTGRES (PostgreSQL-only rules are skipped otherwise).
list[orm_lint_finding*] orm_lint_migration(orm_migration* m, int dialect_id):
	orm_lint_ctx* x = new orm_lint_ctx()
	x.m = m
	x.dialect_id = dialect_id
	x.findings = new list[orm_lint_finding*]
	for orm_op* op in m.ops:
		if (op.phase == ORM_PHASE_EXPAND): x.has_expand = 1
	for i in range(m.ops.length): orm_lint_op(x, i, m.ops[i])
	list[orm_lint_finding*] out = x.findings
	free(cast(void*, x))
	return out


# Lints every migration of a plan, concatenating the findings.
list[orm_lint_finding*] orm_lint_plan(list[orm_migration*] plan, int dialect_id):
	list[orm_lint_finding*] out = new list[orm_lint_finding*]
	for orm_migration* m in plan:
		list[orm_lint_finding*] f = orm_lint_migration(m, dialect_id)
		for orm_lint_finding* one in f: out.push(one)
		f.free()
	return out


int orm_lint_count(list[orm_lint_finding*] findings, int severity):
	int n = 0
	for orm_lint_finding* f in findings:
		if (f.severity == severity): n = n + 1
	return n


# 1 when some finding has this code.
int orm_lint_has(list[orm_lint_finding*] findings, char* code):
	for orm_lint_finding* f in findings:
		if (strcmp(f.code, code) == 0): return 1
	return 0


# "error W-ORM-M004 0007_x: op 0 ADD_COLUMN t.c: ..." one finding per line.
char* orm_lint_format(list[orm_lint_finding*] findings):
	string_builder* b = string_new()
	for orm_lint_finding* f in findings:
		if (f.severity == ORM_LINT_ERROR): string_append(b, c"error ")
		else: string_append(b, c"warning ")
		string_append(b, f.code)
		string_append(b, c" ")
		string_append(b, f.message)
		string_append(b, c"\n")
	char* out = b.data
	free(cast(void*, b))
	return out


void orm_lint_free(list[orm_lint_finding*] findings):
	for orm_lint_finding* f in findings:
		free(f.message)
		free(cast(void*, f))
	findings.free()
