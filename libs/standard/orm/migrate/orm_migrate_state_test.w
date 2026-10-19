# wbuild: arch_only=x64
# U2.2: replaying orm_migration lists into a schema state in the U1.1
# snapshot JSON shape, one case per schema-changing ORM_OP_*
# (docs/projects/orm/u2_2.md).
import libs.standard.orm.migrate.state
import lib.assert


orm_op* op_on(orm_migration* m, int kind, char* table):
	orm_op* op = orm_op_new(kind, ORM_PHASE_EXPAND, table)
	orm_migration_add(m, op)
	return op


char* T_JSON():
	return c"{\"name\":\"T\",\"table\":\"t\",\"fields\":[{\"name\":\"id\",\"column\":\"id\",\"kind\":1,\"pk\":true,\"auto\":true},{\"name\":\"a\",\"column\":\"a\",\"kind\":4,\"max_length\":10}]}"


orm_state* replay(orm_migration* m):
	list[orm_migration*] l = new list[orm_migration*]
	l.push(m)
	orm_state* st = orm_state_from_migrations(c"app", l)
	l.free()
	return st


char* model_text(orm_state* st, char* table):
	return json_stringify(orm_state_model(st, table))


char* field_text(orm_state* st, char* table, char* column):
	return json_stringify(orm_state_field(orm_state_model(st, table), column))


void test_empty_state():
	orm_state* st = orm_state_from_migrations(c"app", 0)
	assert_strings_equal(c"{\"format\":\"w-orm-schema\",\"version\":1,\"app\":\"app\",\"models\":[]}", orm_state_to_json(st))
	orm_state_free(st)


void test_create_table_normalizes():
	orm_migration* m = orm_migration_new(c"app", c"0001_initial")
	orm_op* op = op_on(m, ORM_OP_CREATE_TABLE, c"t")
	op.model_json = T_JSON()
	orm_state* st = replay(m)
	asserts(st.error, st.error == 0)
	assert_strings_equal(c"{\"name\":\"T\",\"table\":\"t\",\"history\":false,\"fields\":[{\"name\":\"id\",\"column\":\"id\",\"kind\":1,\"kind_name\":\"int\",\"type\":\"int\",\"pk\":true,\"null\":false,\"unique\":false,\"indexed\":false,\"auto\":true,\"auto_now_add\":false,\"auto_now\":false,\"deprecated\":false,\"no_history\":false,\"read_only\":false,\"max_length\":0,\"digits\":0,\"places\":0,\"default\":null,\"enum\":null,\"enum_values\":[],\"rel_model\":null,\"on_delete\":null,\"related_name\":null,\"through_table\":null,\"through_from\":null,\"through_to\":null,\"reverse_field\":null},{\"name\":\"a\",\"column\":\"a\",\"kind\":4,\"kind_name\":\"text\",\"type\":\"text\",\"pk\":false,\"null\":false,\"unique\":false,\"indexed\":false,\"auto\":false,\"auto_now_add\":false,\"auto_now\":false,\"deprecated\":false,\"no_history\":false,\"read_only\":false,\"max_length\":10,\"digits\":0,\"places\":0,\"default\":null,\"enum\":null,\"enum_values\":[],\"rel_model\":null,\"on_delete\":null,\"related_name\":null,\"through_table\":null,\"through_from\":null,\"through_to\":null,\"reverse_field\":null}],\"indexes\":[],\"checks\":[],\"unique_together\":[]}", model_text(st, c"t"))
	orm_state_free(st)
	# op.table overrides the model's table; history always starts off.
	orm_migration* m2 = orm_migration_new(c"app", c"0001_initial")
	orm_op* op2 = op_on(m2, ORM_OP_CREATE_TABLE, c"t_shadow")
	op2.model_json = c"{\"name\":\"T\",\"table\":\"t\",\"history\":true,\"fields\":[]}"
	orm_state* st2 = replay(m2)
	assert_strings_equal(c"{\"name\":\"T\",\"table\":\"t_shadow\",\"history\":false,\"fields\":[],\"indexes\":[],\"checks\":[],\"unique_together\":[]}", model_text(st2, c"t_shadow"))
	orm_state_free(st2)


orm_migration* base():
	orm_migration* m = orm_migration_new(c"app", c"0001_initial")
	orm_op* op = op_on(m, ORM_OP_CREATE_TABLE, c"t")
	op.model_json = T_JSON()
	orm_op* u = op_on(m, ORM_OP_CREATE_TABLE, c"u")
	u.model_json = c"{\"name\":\"U\",\"table\":\"u\",\"fields\":[{\"name\":\"id\",\"column\":\"id\",\"kind\":1,\"pk\":true}]}"
	return m


void test_columns():
	orm_migration* m = base()
	orm_op* add = op_on(m, ORM_OP_ADD_COLUMN, c"t")
	add.column = c"b"
	add.field_json = c"{\"name\": \"b\", \"kind\": 2, \"null\": true}"
	orm_op* dep = op_on(m, ORM_OP_ALTER_NULL, c"t")
	dep.column = c"a"
	dep.field_json = c"{\"column\": \"a\", \"null\": true, \"deprecated\": true}"
	orm_state* st = replay(m)
	asserts(st.error, st.error == 0)
	char* b = field_text(st, c"t", c"b")
	assert_contains(b, c"\"name\":\"b\",\"column\":\"b\",\"kind\":2,\"kind_name\":\"bigint\"")
	assert_contains(b, c"\"null\":true")
	char* a = field_text(st, c"t", c"a")
	assert_contains(a, c"\"null\":true")
	assert_contains(a, c"\"deprecated\":true")
	orm_state_free(st)
	# ALTER_NULL without "deprecated" only touches null; DROP_COLUMN removes it.
	orm_op* tighten = op_on(m, ORM_OP_ALTER_NULL, c"t")
	tighten.column = c"b"
	tighten.field_json = c"{\"null\": false}"
	orm_op* drop = op_on(m, ORM_OP_DROP_COLUMN, c"t")
	drop.column = c"a"
	orm_state* st2 = replay(m)
	asserts(st2.error, st2.error == 0)
	assert_contains(field_text(st2, c"t", c"b"), c"\"null\":false")
	asserts(c"a dropped", orm_state_field(orm_state_model(st2, c"t"), c"a") == 0)
	orm_state_free(st2)


void test_indexes():
	orm_migration* m = base()
	orm_op* add = op_on(m, ORM_OP_ADD_INDEX, c"t")
	add.name = c"t_a_idx"
	add.field_json = c"{\"columns\": [\"a\"], \"unique\": true}"
	orm_op* add2 = op_on(m, ORM_OP_ADD_INDEX, c"t")
	add2.name = c"t_id_a_idx"
	add2.column = c"id"
	add2.field_json = c"{\"columns\": [\"id\", \"a\"]}"
	orm_state* st = replay(m)
	asserts(st.error, st.error == 0)
	assert_contains(model_text(st, c"t"), c"\"indexes\":[{\"name\":\"t_a_idx\",\"fields\":[\"a\"],\"columns\":[\"a\"],\"unique\":true,\"condition\":null},{\"name\":\"t_id_a_idx\",\"fields\":[\"id\",\"a\"],\"columns\":[\"id\",\"a\"],\"unique\":false,\"condition\":null}]")
	orm_state_free(st)
	orm_op* drop = op_on(m, ORM_OP_DROP_INDEX, c"t")
	drop.name = c"t_a_idx"
	orm_state* st2 = replay(m)
	assert_contains(model_text(st2, c"t"), c"\"indexes\":[{\"name\":\"t_id_a_idx\"")
	orm_state_free(st2)
	# Dropping a column drops the indexes that use it.
	orm_op* dc = op_on(m, ORM_OP_DROP_COLUMN, c"t")
	dc.column = c"a"
	orm_state* st3 = replay(m)
	assert_contains(model_text(st3, c"t"), c"\"indexes\":[]")
	orm_state_free(st3)


void test_constraints():
	orm_migration* m = base()
	orm_op* ck = op_on(m, ORM_OP_ADD_CONSTRAINT, c"t")
	ck.name = c"t_a_check"
	ck.sql = c"CHECK (length(a) > 0)"
	orm_op* fk = op_on(m, ORM_OP_ADD_CONSTRAINT, c"t")
	fk.name = c"t_id_fk"
	fk.sql = c"FOREIGN KEY (id) REFERENCES u (id) ON DELETE CASCADE"
	orm_op* un = op_on(m, ORM_OP_ADD_CONSTRAINT, c"t")
	un.name = c"t_a_uniq"
	un.sql = c"UNIQUE USING INDEX t_a_uniq_idx"
	orm_op* v = op_on(m, ORM_OP_VALIDATE_CONSTRAINT, c"t")
	v.name = c"t_a_check"
	orm_state* st = replay(m)
	asserts(st.error, st.error == 0)
	char* t = model_text(st, c"t")
	assert_contains(t, c"\"checks\":[{\"name\":\"t_a_check\",\"sql\":\"length(a) > 0\"}]")
	assert_contains(t, c"\"constraints\":[{\"name\":\"t_id_fk\",\"sql\":\"FOREIGN KEY (id) REFERENCES u (id) ON DELETE CASCADE\"}]")
	char* id = field_text(st, c"t", c"id")
	assert_contains(id, c"\"kind\":10,\"kind_name\":\"fk\",\"type\":\"fk\"")
	assert_contains(id, c"\"rel_model\":\"U\",\"on_delete\":\"cascade\"")
	orm_state_free(st)
	orm_op* d1 = op_on(m, ORM_OP_DROP_CONSTRAINT, c"t")
	d1.name = c"t_a_check"
	orm_op* d2 = op_on(m, ORM_OP_DROP_CONSTRAINT, c"t")
	d2.name = c"t_id_fk"
	orm_state* st2 = replay(m)
	asserts(st2.error, st2.error == 0)
	char* t2 = model_text(st2, c"t")
	assert_contains(t2, c"\"checks\":[]")
	asserts(t2, contains(t2, c"constraints") == 0)
	assert_contains(field_text(st2, c"t", c"id"), c"\"kind\":1,\"kind_name\":\"int\"")
	orm_state_free(st2)


void test_tables_and_history():
	orm_migration* m = base()
	orm_op* h = op_on(m, ORM_OP_CREATE_HISTORY, c"t")
	h.model_json = T_JSON()
	orm_state* st = replay(m)
	assert_contains(model_text(st, c"t"), c"\"history\":true")
	orm_state_free(st)
	orm_op* dh = op_on(m, ORM_OP_DROP_HISTORY, c"t")
	dh.model_json = 0
	orm_op* r = op_on(m, ORM_OP_RENAME_TABLE, c"t2")
	r.source_table = c"t"
	# Data-only ops leave the state alone.
	orm_op* copy = op_on(m, ORM_OP_COPY_TABLE, c"t2")
	copy.source_table = c"u"
	orm_op* raw = op_on(m, ORM_OP_RAW_SQL, 0)
	raw.sql = c"DROP TABLE t2"
	orm_op* bf = op_on(m, ORM_OP_BACKFILL, c"t2")
	bf.name = c"fill"
	orm_op* sync = op_on(m, ORM_OP_SYNC_TRIGGER, c"t2")
	sync.source_table = c"u"
	orm_state* st2 = replay(m)
	asserts(st2.error, st2.error == 0)
	asserts(c"t renamed", orm_state_model(st2, c"t") == 0)
	assert_contains(model_text(st2, c"t2"), c"{\"name\":\"T\",\"table\":\"t2\",\"history\":false")
	orm_state_free(st2)
	# SWAP_TABLES exchanges names and list positions.
	orm_op* sw = op_on(m, ORM_OP_SWAP_TABLES, c"u")
	sw.source_table = c"t2"
	orm_state* st3 = replay(m)
	asserts(st3.error, st3.error == 0)
	char* all = orm_state_to_json(st3)
	assert_contains(all, c"\"models\":[{\"name\":\"U\",\"table\":\"t2\"")
	assert_contains(all, c"{\"name\":\"T\",\"table\":\"u\"")
	orm_state_free(st3)
	orm_op* drop = op_on(m, ORM_OP_DROP_TABLE, c"u")
	drop.model_json = 0
	orm_state* st4 = replay(m)
	asserts(c"u dropped", orm_state_model(st4, c"u") == 0)
	assert_equal(1, orm_state_models(st4).array_values.length)
	orm_state_free(st4)


char* replay_error(orm_op* op):
	orm_migration* m = base()
	orm_migration_add(m, op)
	orm_state* st = replay(m)
	asserts(c"expected an error", st.error != 0)
	char* out = strclone(st.error)
	orm_state_free(st)
	return out


void test_errors():
	orm_op* a = orm_op_new(ORM_OP_ADD_COLUMN, ORM_PHASE_EXPAND, c"nope")
	a.field_json = c"{\"name\": \"x\"}"
	assert_strings_equal(c"0001_initial: ADD_COLUMN: unknown table nope", replay_error(a))
	orm_op* b = orm_op_new(ORM_OP_ADD_COLUMN, ORM_PHASE_EXPAND, c"t")
	b.field_json = c"{\"name\": \"a\", \"column\": \"a\"}"
	assert_strings_equal(c"0001_initial: ADD_COLUMN: column exists: t", replay_error(b))
	orm_op* c = orm_op_new(ORM_OP_CREATE_TABLE, ORM_PHASE_EXPAND, c"t")
	c.model_json = T_JSON()
	assert_strings_equal(c"0001_initial: CREATE_TABLE: table exists: t", replay_error(c))
	orm_op* d = orm_op_new(ORM_OP_CREATE_TABLE, ORM_PHASE_EXPAND, c"x")
	d.model_json = c"not json"
	assert_strings_equal(c"0001_initial: CREATE_TABLE: bad model_json for x", replay_error(d))
	orm_op* e = orm_op_new(ORM_OP_DROP_COLUMN, ORM_PHASE_CONTRACT, c"t")
	e.column = c"zz"
	assert_strings_equal(c"0001_initial: DROP_COLUMN: unknown column zz", replay_error(e))
	orm_op* f = orm_op_new(ORM_OP_DROP_INDEX, ORM_PHASE_EXPAND, c"t")
	f.name = c"nope_idx"
	assert_strings_equal(c"0001_initial: DROP_INDEX: unknown index nope_idx", replay_error(f))
	orm_op* g = orm_op_new(ORM_OP_SWAP_TABLES, ORM_PHASE_MIGRATE, c"t")
	g.source_table = c"zz"
	assert_strings_equal(c"0001_initial: SWAP_TABLES: unknown table zz", replay_error(g))
	orm_op* h = orm_op_new(ORM_OP_RENAME_TABLE, ORM_PHASE_EXPAND, c"u")
	h.source_table = c"t"
	assert_strings_equal(c"0001_initial: RENAME_TABLE: table exists: u", replay_error(h))
	orm_op* i = orm_op_new(ORM_OP_DROP_TABLE, ORM_PHASE_CONTRACT, c"zz")
	assert_strings_equal(c"0001_initial: DROP_TABLE: unknown table zz", replay_error(i))
	orm_op* j = orm_op_new(ORM_OP_ALTER_NULL, ORM_PHASE_EXPAND, c"t")
	j.column = c"zz"
	j.field_json = c"{\"null\": true}"
	assert_strings_equal(c"0001_initial: ALTER_NULL: unknown column zz", replay_error(j))


void test_snapshot_round_trip():
	char* snap = c"{\"format\":\"w-orm-schema\",\"version\":1,\"app\":\"x\",\"models\":[{\"name\":\"A\",\"table\":\"x_a\",\"history\":false,\"fields\":[{\"name\":\"bs\",\"column\":null,\"kind\":12,\"rel_model\":\"A\",\"through_table\":\"x_a_bs\",\"through_from\":\"from_a_id\",\"through_to\":\"to_a_id\"}],\"indexes\":[],\"checks\":[],\"unique_together\":[]}]}"
	char* expanded = orm_state_expand_snapshot(snap)
	assert_contains(expanded, c"{\"name\":\"A_bs\",\"table\":\"x_a_bs\",\"history\":false")
	assert_contains(expanded, c"\"name\":\"from_a\",\"column\":\"from_a_id\",\"kind\":10")
	assert_contains(expanded, c"\"unique_together\":[{\"fields\":[\"from_a\",\"to_a\"],\"columns\":[\"from_a_id\",\"to_a_id\"]}]")
	# Expanding twice adds nothing.
	assert_strings_equal(expanded, orm_state_expand_snapshot(expanded))
	asserts(c"bad json", orm_state_from_json(c"[1", 0) == 0)
	orm_state* empty = orm_state_from_json(c"", c"x")
	assert_strings_equal(c"{\"format\":\"w-orm-schema\",\"version\":1,\"app\":\"x\",\"models\":[]}", orm_state_to_json(empty))
	orm_state* c = orm_state_clone(empty)
	orm_state_free(empty)
	assert_contains(orm_state_to_json(c), c"\"app\":\"x\"")
	orm_state_free(c)


int main():
	test_empty_state()
	test_create_table_normalizes()
	test_columns()
	test_indexes()
	test_constraints()
	test_tables_and_history()
	test_errors()
	test_snapshot_round_trip()
	print(c"orm_migrate_state_test: ok\n")
	return 0
