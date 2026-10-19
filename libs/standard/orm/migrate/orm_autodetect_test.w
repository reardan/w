# wbuild: arch_only=x64
# U2.2: the autodetector diffs snapshot pairs into orm_change intents, and
# makemigrations' plans replay back to the new snapshot (no remaining
# diff) and lint clean on both dialects (docs/projects/orm/u2_2.md).
import libs.standard.orm.migrate.autodetect
import tests.orm.generated.library_orm
import lib.assert


# ---------------------------------------------------------------------------
# Snapshot editing helpers

json_value* lib_snapshot():
	return json_parse(library_schema_json())


json_value* model_of(json_value* s, char* name):
	json_value* models = orm_sj_array(s, c"models")
	for json_value* m in models.array_values:
		if (orm_sj_streq(orm_sj_str(m, c"name"), name)): return m
	asserts(name, 0)
	return 0


json_value* field_of(json_value* m, char* name):
	json_value* fields = orm_sj_array(m, c"fields")
	for json_value* f in fields.array_values:
		if (orm_sj_streq(orm_sj_str(f, c"name"), name)): return f
	asserts(name, 0)
	return 0


int field_pos(json_value* m, char* name):
	json_value* fields = orm_sj_array(m, c"fields")
	for i in range(fields.array_values.length):
		if (orm_sj_streq(orm_sj_str(fields.array_values[i], c"name"), name)): return i
	return -1


void remove_field(json_value* m, char* name):
	json_free(orm_sj_array_take(orm_sj_array(m, c"fields"), field_pos(m, name)))


void remove_model(json_value* s, char* name):
	json_value* models = orm_sj_array(s, c"models")
	for i in range(models.array_values.length):
		if (orm_sj_streq(orm_sj_str(models.array_values[i], c"name"), name)):
			json_free(orm_sj_array_take(models, i))
			return


# A plain field: name/column, kind and nullability; other keys default.
json_value* new_field(char* name, int kind, int nullable):
	json_value* src = json_object()
	orm_sj_set_str(src, c"name", name)
	orm_sj_set_str(src, c"column", name)
	json_object_set(src, c"kind", json_int(kind))
	orm_sj_set_bool(src, c"null", nullable)
	json_value* f = orm_state_field_normalize(src)
	json_free(src)
	return f


void add_field(json_value* m, json_value* f):
	json_array_push(orm_sj_array(m, c"fields"), f)


char* text_of(json_value* s):
	char* out = json_stringify(s)
	json_free(s)
	return out


# ---------------------------------------------------------------------------
# Diff + plan + replay

char* describe(char* old_json, char* new_json, list[char*] hints):
	orm_detect* d = orm_autodetect(old_json, new_json, hints)
	asserts(d.error, d.error == 0)
	char* out = orm_detect_describe(d)
	orm_detect_free(d)
	return out


char* detect_error(char* old_json, char* new_json, list[char*] hints):
	orm_detect* d = orm_autodetect(old_json, new_json, hints)
	asserts(c"expected an error", d.error != 0)
	char* out = strclone(d.error)
	orm_detect_free(d)
	return out


void assert_lint_clean(list[orm_migration*] ms, int dialect):
	list[orm_lint_finding*] findings = orm_lint_plan(ms, dialect)
	char* text = orm_lint_format(findings)
	assert_strings_equal(c"", text)
	free(text)
	orm_lint_free(findings)


# Initial migration from `old_json`, then makemigrations to `new_json` on
# `dialect`; the replayed state must leave no diff against new_json and
# every migration must lint clean. Returns the new plan's description.
char* converge(char* old_json, char* new_json, list[char*] hints, int dialect):
	orm_makemig* init = orm_makemigrations(c"library", c"", old_json, dialect, 1, 0, 0)
	asserts(init.error, init.error == 0)
	assert_equal(1, init.migrations.length)
	orm_makemig* r = orm_makemigrations_next(c"library", init.migrations, new_json, dialect, hints)
	asserts(r.error, r.error == 0)
	assert_lint_clean(init.migrations, dialect)
	assert_lint_clean(r.migrations, dialect)
	list[orm_migration*] all = new list[orm_migration*]
	for orm_migration* a in init.migrations: all.push(a)
	for orm_migration* b in r.migrations: all.push(b)
	orm_state* st = orm_state_from_migrations(c"library", all)
	asserts(st.error, st.error == 0)
	char* state_json = orm_state_to_json(st)
	# Renames are applied by now, so the check diffs without hints.
	char* rest = describe(state_json, new_json, 0)
	assert_strings_equal(c"", rest)
	free(rest)
	free(state_json)
	orm_state_free(st)
	all.free()
	char* out = orm_plan_describe(r.migrations)
	orm_makemig_free(r)
	orm_makemig_free(init)
	return out


list[char*] one_hint(char* h):
	list[char*] l = new list[char*]
	l.push(h)
	return l


# ---------------------------------------------------------------------------
# Tests

void test_initial_migration():
	char* lib = library_schema_json()
	assert_strings_equal(c"create_table library_author\ncreate_table library_tag\ncreate_table library_book\ncreate_table library_book_tags\nadd_history library_book\n", describe(c"", lib, 0))
	orm_makemig* r = orm_makemigrations(c"library", 0, lib, ORM_DIALECT_POSTGRES, 1, 0, 0)
	asserts(r.error, r.error == 0)
	assert_equal(1, r.migrations.length)
	orm_migration* m = r.migrations[0]
	assert_strings_equal(c"0001_initial", m.name)
	assert_equal(0, m.dependencies.length)
	assert_equal(ORM_PHASE_EXPAND, m.phase)
	assert_strings_equal(c"0001_initial (atomic)\n  expand CREATE_TABLE library_author\n  expand CREATE_TABLE library_tag\n  expand CREATE_TABLE library_book\n  expand CREATE_TABLE library_book_tags\n  expand CREATE_HISTORY library_book\n", orm_plan_describe(r.migrations))
	assert_lint_clean(r.migrations, ORM_DIALECT_POSTGRES)
	assert_lint_clean(r.migrations, ORM_DIALECT_SQLITE)
	# CREATE_TABLE carries the snapshot model with history off.
	assert_contains(m.ops[2].model_json, c"\"table\":\"library_book\",\"history\":false")
	assert_contains(m.ops[4].model_json, c"\"history\":true")
	# The through table is a model of its own.
	assert_contains(m.ops[3].model_json, c"\"name\":\"Book_tags\"")
	assert_contains(m.ops[3].model_json, c"\"unique_together\":[{\"fields\":[\"book\",\"tag\"],\"columns\":[\"book_id\",\"tag_id\"]}]")
	# Replay gives exactly the expanded snapshot.
	orm_state* st = orm_state_from_migrations(c"library", r.migrations)
	asserts(st.error, st.error == 0)
	char* expanded = orm_state_expand_snapshot(lib)
	assert_strings_equal(expanded, orm_state_to_json(st))
	orm_state_free(st)
	orm_makemig_free(r)
	# And nothing is left to do.
	assert_strings_equal(c"", describe(expanded, lib, 0))
	assert_strings_equal(c"", describe(lib, lib, 0))
	free(expanded)


void test_numbering_and_dependencies():
	json_value* s = lib_snapshot()
	add_field(model_of(s, c"Tag"), new_field(c"slug", ORM_TEXT, 1))
	char* next = text_of(s)
	orm_makemig* r = orm_makemigrations(c"library", library_schema_json(), next, ORM_DIALECT_SQLITE, 5, c"0004_prev", 0)
	asserts(r.error, r.error == 0)
	assert_equal(1, r.migrations.length)
	assert_strings_equal(c"0005_expand_library_tag_slug", r.migrations[0].name)
	assert_strings_equal(c"library.0004_prev", r.migrations[0].dependencies[0])
	orm_makemig_free(r)
	assert_equal(12, orm_migration_number(c"0012_x"))
	assert_equal(0, orm_migration_number(c"x"))


void test_add_columns():
	json_value* s = lib_snapshot()
	json_value* tag = model_of(s, c"Tag")
	add_field(tag, new_field(c"note", ORM_TEXT, 1))
	json_value* rank = new_field(c"rank", ORM_INT, 0)
	json_object_set(rank, c"default", json_string(c"0"))
	add_field(tag, rank)
	add_field(tag, new_field(c"color", ORM_TEXT, 0))
	json_value* code = new_field(c"code", ORM_TEXT, 1)
	orm_sj_set_bool(code, c"unique", 1)
	add_field(tag, code)
	json_value* seen = new_field(c"seen", ORM_DATE, 1)
	orm_sj_set_bool(seen, c"indexed", 1)
	add_field(tag, seen)
	char* next = text_of(s)
	assert_strings_equal(c"add_column library_tag.note null\nadd_column library_tag.rank not-null default\nadd_column library_tag.color not-null\nadd_column library_tag.code null\nadd_column library_tag.seen null\nadd_index library_tag.seen name=library_tag_seen_idx columns=[\"seen\"]\nadd_unique library_tag.code name=library_tag_code_uniq columns=[\"code\"]\n", describe(library_schema_json(), next, 0))
	char* pg = converge(library_schema_json(), next, 0, ORM_DIALECT_POSTGRES)
	assert_contains(pg, c"0002_expand_library_tag_note (atomic)\n  expand ADD_COLUMN library_tag.note null\n")
	assert_contains(pg, c"expand ADD_COLUMN library_tag.color null\n")
	assert_contains(pg, c"migrate BACKFILL library_tag.color name=library_tag_color_backfill")
	assert_contains(pg, c"expand ADD_INDEX library_tag.seen name=library_tag_seen_idx non_atomic")
	assert_contains(pg, c"migrate ADD_CONSTRAINT library_tag.code name=library_tag_code_uniq sql=\"UNIQUE USING INDEX library_tag_code_uniq_idx\"")
	char* sl = converge(library_schema_json(), next, 0, ORM_DIALECT_SQLITE)
	assert_contains(sl, c"expand ADD_INDEX library_tag.code name=library_tag_code_uniq unique\n")


void test_drop_column():
	json_value* s = lib_snapshot()
	remove_field(model_of(s, c"Book"), c"pages")
	char* next = text_of(s)
	assert_strings_equal(c"drop_column library_book.pages\n", describe(library_schema_json(), next, 0))
	assert_strings_equal(c"0002_expand_library_book_pages (atomic)\n  expand ALTER_NULL library_book.pages null deprecated\n0003_contract_library_book_pages (atomic) requires 0002_expand_library_book_pages\n  contract DROP_COLUMN library_book.pages\n", converge(library_schema_json(), next, 0, ORM_DIALECT_POSTGRES))


void test_alter_null():
	json_value* s = lib_snapshot()
	json_value* book = model_of(s, c"Book")
	orm_sj_set_bool(field_of(book, c"title"), c"null", 1)
	orm_sj_set_bool(field_of(book, c"pages"), c"null", 0)
	char* next = text_of(s)
	assert_strings_equal(c"alter_null library_book.title null\nalter_null library_book.pages not-null\n", describe(library_schema_json(), next, 0))
	char* pg = converge(library_schema_json(), next, 0, ORM_DIALECT_POSTGRES)
	assert_contains(pg, c"expand ALTER_NULL library_book.title null\n")
	assert_contains(pg, c"contract ALTER_NULL library_book.pages not-null\n")
	converge(library_schema_json(), next, 0, ORM_DIALECT_SQLITE)


void test_deprecate_and_restore():
	json_value* s = lib_snapshot()
	orm_sj_set_bool(field_of(model_of(s, c"Book"), c"price"), c"deprecated", 1)
	char* dep = text_of(s)
	assert_strings_equal(c"alter_null library_book.price null\n", describe(library_schema_json(), dep, 0))
	assert_strings_equal(c"0002_expand_library_book_price (atomic)\n  expand ALTER_NULL library_book.price null deprecated\n", converge(library_schema_json(), dep, 0, ORM_DIALECT_POSTGRES))
	# Un-deprecating a NOT NULL column backfills and tightens it again.
	char* back = converge(dep, library_schema_json(), 0, ORM_DIALECT_SQLITE)
	assert_contains(back, c"migrate BACKFILL library_book.price")
	assert_contains(back, c"contract ALTER_NULL library_book.price not-null\n")


json_value* lib_with_tag_uuid():
	json_value* s = lib_snapshot()
	json_object_set(field_of(model_of(s, c"Tag"), c"name"), c"kind", json_int(ORM_UUID))
	return s


void test_type_change_rebuilds():
	json_value* s = lib_snapshot()
	json_value* book = model_of(s, c"Book")
	json_object_set(field_of(book, c"title"), c"max_length", json_int(400))
	char* next = text_of(s)
	assert_strings_equal(c"rebuild_table library_book\nadd_history library_book\n", describe(library_schema_json(), next, 0))
	char* pg = converge(library_schema_json(), next, 0, ORM_DIALECT_POSTGRES)
	assert_contains(pg, c"expand CREATE_TABLE library_book__new\n  expand SYNC_TRIGGER library_book__new <- library_book\n")
	assert_contains(pg, c"migrate SWAP_TABLES library_book__new <- library_book\n")
	assert_contains(pg, c"contract DROP_TABLE library_book__new\n")
	assert_contains(pg, c"expand CREATE_HISTORY library_book\n")
	# Decimal precision and kind changes rebuild too.
	json_value* s2 = lib_snapshot()
	json_object_set(field_of(model_of(s2, c"Book"), c"price"), c"places", json_int(3))
	assert_contains(describe(library_schema_json(), text_of(s2), 0), c"rebuild_table library_book\n")
	json_value* s3 = lib_snapshot()
	json_value* name = field_of(model_of(s3, c"Tag"), c"name")
	json_object_set(name, c"kind", json_int(ORM_UUID))
	assert_strings_equal(c"rebuild_table library_tag\n", describe(library_schema_json(), text_of(s3), 0))
	converge(library_schema_json(), text_of(lib_with_tag_uuid()), 0, ORM_DIALECT_SQLITE)


void test_add_fk_to_int_column():
	json_value* old = lib_snapshot()
	json_value* tag = model_of(old, c"Tag")
	json_value* owner = new_field(c"owner_id", ORM_INT, 1)
	add_field(tag, owner)
	char* old_json = text_of(old)
	json_value* s = lib_snapshot()
	json_value* fk = new_field(c"owner", ORM_FK, 1)
	orm_sj_set_str(fk, c"column", c"owner_id")
	orm_sj_set_str(fk, c"rel_model", c"Author")
	orm_sj_set_str(fk, c"on_delete", c"set_null")
	add_field(model_of(s, c"Tag"), fk)
	char* next = text_of(s)
	assert_strings_equal(c"add_fk library_tag.owner_id sql=\"FOREIGN KEY (owner_id) REFERENCES library_author (id) ON DELETE SET NULL\"\n", describe(old_json, next, 0))
	char* pg = converge(old_json, next, 0, ORM_DIALECT_POSTGRES)
	assert_contains(pg, c"expand ADD_CONSTRAINT library_tag.owner_id name=library_tag_owner_id_fk")
	assert_contains(pg, c"migrate VALIDATE_CONSTRAINT library_tag.owner_id name=library_tag_owner_id_fk")
	# Removing or retargeting the FK needs a rebuild.
	assert_strings_equal(c"rebuild_table library_tag\n", describe(next, old_json, 0))
	converge(next, old_json, 0, ORM_DIALECT_SQLITE)


void test_indexes():
	json_value* s = lib_snapshot()
	json_value* author = model_of(s, c"Author")
	json_value* idx = orm_sj_array(author, c"indexes")
	json_free(orm_sj_array_take(idx, 0))
	json_value* x = json_object()
	orm_sj_set_str(x, c"name", c"author_name_email")
	list[char*] cols = new list[char*]
	cols.push(c"name")
	cols.push(c"email")
	json_object_set(x, c"fields", orm_sj_str_array(cols))
	json_object_set(x, c"columns", orm_sj_str_array(cols))
	json_array_push(idx, x)
	char* next = text_of(s)
	assert_strings_equal(c"add_index library_author.name name=author_name_email columns=[\"name\",\"email\"]\ndrop_index library_author.created name=library_author_created_idx\n", describe(library_schema_json(), next, 0))
	char* pg = converge(library_schema_json(), next, 0, ORM_DIALECT_POSTGRES)
	assert_contains(pg, c"_expand_drop_library_author_created_idx (atomic)\n  expand DROP_INDEX library_author name=library_author_created_idx\n")
	# An index the database named itself (an "indexed" field) is rebuilt away.
	json_value* s2 = lib_snapshot()
	orm_sj_set_bool(field_of(model_of(s2, c"Book"), c"author"), c"indexed", 0)
	assert_strings_equal(c"rebuild_table library_book\nadd_history library_book\n", describe(library_schema_json(), text_of(s2), 0))


void test_checks_and_unique_together():
	json_value* s = lib_snapshot()
	json_value* book = model_of(s, c"Book")
	json_value* ck = json_object()
	orm_sj_set_str(ck, c"name", c"library_book_pages_positive")
	orm_sj_set_str(ck, c"sql", c"pages > 0")
	json_array_push(orm_sj_array(book, c"checks"), ck)
	json_value* ut = json_object()
	list[char*] cols = new list[char*]
	cols.push(c"title")
	cols.push(c"author_id")
	json_object_set(ut, c"fields", orm_sj_str_array(cols))
	json_object_set(ut, c"columns", orm_sj_str_array(cols))
	json_array_push(orm_sj_array(book, c"unique_together"), ut)
	char* next = text_of(s)
	assert_strings_equal(c"add_unique library_book.title name=library_book_title_author_id_uniq columns=[\"title\",\"author_id\"]\nadd_check library_book name=library_book_pages_positive sql=\"CHECK (pages > 0)\"\n", describe(library_schema_json(), next, 0))
	char* pg = converge(library_schema_json(), next, 0, ORM_DIALECT_POSTGRES)
	assert_contains(pg, c"expand ADD_CONSTRAINT library_book.pages_positive name=library_book_pages_positive sql=\"CHECK (pages > 0)\"")
	converge(library_schema_json(), next, 0, ORM_DIALECT_SQLITE)
	# Dropping either one rebuilds the table.
	assert_strings_equal(c"rebuild_table library_book\nadd_history library_book\n", describe(next, library_schema_json(), 0))
	converge(next, library_schema_json(), 0, ORM_DIALECT_POSTGRES)
	# A changed check body rebuilds too.
	json_value* s2 = lib_snapshot()
	json_value* checks = orm_sj_array(model_of(s2, c"Book"), c"checks")
	orm_sj_set_str(checks.array_values[0], c"sql", c"price > 0")
	assert_strings_equal(c"rebuild_table library_book\nadd_history library_book\n", describe(library_schema_json(), text_of(s2), 0))


void test_models_and_m2m():
	json_value* small = lib_snapshot()
	remove_model(small, c"Book")
	remove_field(model_of(small, c"Author"), c"books")
	char* small_json = text_of(small)
	assert_strings_equal(c"create_table library_book\ncreate_table library_book_tags\nadd_history library_book\n", describe(small_json, library_schema_json(), 0))
	char* up = converge(small_json, library_schema_json(), 0, ORM_DIALECT_POSTGRES)
	assert_contains(up, c"0002_expand_library_book (atomic)\n  expand CREATE_TABLE library_book\n")
	assert_contains(up, c"expand CREATE_HISTORY library_book\n")
	assert_strings_equal(c"drop_table library_book_tags\ndrop_table library_book\n", describe(library_schema_json(), small_json, 0))
	char* down = converge(library_schema_json(), small_json, 0, ORM_DIALECT_SQLITE)
	assert_contains(down, c"contract DROP_TABLE library_book_tags\n")
	# Removing only the m2m field drops its through table.
	json_value* s = lib_snapshot()
	remove_field(model_of(s, c"Book"), c"tags")
	char* no_tags = text_of(s)
	assert_strings_equal(c"drop_table library_book_tags\n", describe(library_schema_json(), no_tags, 0))
	assert_strings_equal(c"create_table library_book_tags\n", describe(no_tags, library_schema_json(), 0))
	converge(no_tags, library_schema_json(), 0, ORM_DIALECT_POSTGRES)


void test_history_flags():
	json_value* s = lib_snapshot()
	orm_sj_set_bool(model_of(s, c"Book"), c"history", 0)
	orm_sj_set_bool(model_of(s, c"Tag"), c"history", 1)
	char* next = text_of(s)
	assert_strings_equal(c"add_history library_tag\ndrop_history library_book\n", describe(library_schema_json(), next, 0))
	assert_strings_equal(c"0002_expand_library_tag_history (atomic)\n  expand CREATE_HISTORY library_tag\n0003_expand_library_book_history (atomic)\n  (no database change)\n0004_contract_library_book_history (atomic) requires 0003_expand_library_book_history\n  contract DROP_HISTORY library_book\n", converge(library_schema_json(), next, 0, ORM_DIALECT_POSTGRES))


void test_rename_column_hint():
	json_value* s = lib_snapshot()
	json_value* title = field_of(model_of(s, c"Book"), c"title")
	orm_sj_set_str(title, c"name", c"headline")
	orm_sj_set_str(title, c"column", c"headline")
	char* next = text_of(s)
	# Without a hint a rename is an add plus a drop.
	assert_strings_equal(c"add_column library_book.headline not-null\ndrop_column library_book.title\n", describe(library_schema_json(), next, 0))
	assert_strings_equal(c"rename_column library_book.title -> headline not-null\n", describe(library_schema_json(), next, one_hint(c"Book.title->headline")))
	assert_strings_equal(c"rename_column library_book.title -> headline not-null\n", describe(library_schema_json(), next, one_hint(c"library_book.title->headline")))
	char* pg = converge(library_schema_json(), next, one_hint(c"Book.title->headline"), ORM_DIALECT_POSTGRES)
	assert_contains(pg, c"expand ADD_COLUMN library_book.headline null\n  expand SYNC_TRIGGER library_book.headline <- library_book.title\n")
	assert_contains(pg, c"contract DROP_COLUMN library_book.title\n")
	converge(library_schema_json(), next, one_hint(c"Book.title->headline"), ORM_DIALECT_SQLITE)
	# A rename that also changes the type carries the new type.
	json_value* s2 = lib_snapshot()
	json_value* t2 = field_of(model_of(s2, c"Book"), c"title")
	orm_sj_set_str(t2, c"column", c"headline")
	json_object_set(t2, c"max_length", json_int(500))
	char* next2 = text_of(s2)
	assert_strings_equal(c"rename_column library_book.title -> headline not-null\n", describe(library_schema_json(), next2, one_hint(c"Book.title->headline")))
	converge(library_schema_json(), next2, one_hint(c"Book.title->headline"), ORM_DIALECT_POSTGRES)


void test_rename_table_hint():
	json_value* s = lib_snapshot()
	orm_sj_set_str(model_of(s, c"Tag"), c"table", c"library_label")
	char* next = text_of(s)
	# The through table's FK now targets the new table, so it is rebuilt.
	assert_strings_equal(c"create_table library_label\nrebuild_table library_book_tags\ndrop_table library_tag\n", describe(library_schema_json(), next, 0))
	assert_strings_equal(c"rename_table library_tag -> library_label\nrebuild_table library_book_tags\n", describe(library_schema_json(), next, one_hint(c"library_tag->library_label")))
	char* pg = converge(library_schema_json(), next, one_hint(c"Tag->library_label"), ORM_DIALECT_POSTGRES)
	assert_contains(pg, c"expand CREATE_TABLE library_label\n  expand SYNC_TRIGGER library_label <- library_tag\n")
	assert_contains(pg, c"contract DROP_TABLE library_tag\n")


void test_hint_errors():
	assert_strings_equal(c"bad hint 'nope' (expect table.old->new or old->new)", detect_error(library_schema_json(), library_schema_json(), one_hint(c"nope")))
	assert_strings_equal(c"hint 'Nobody->x': unknown table", detect_error(library_schema_json(), library_schema_json(), one_hint(c"Nobody->x")))
	assert_strings_equal(c"hint 'Book.nothing->title': unknown column", detect_error(library_schema_json(), library_schema_json(), one_hint(c"Book.nothing->title")))
	assert_strings_equal(c"hint 'Book.title->pages': the new column already exists", detect_error(library_schema_json(), library_schema_json(), one_hint(c"Book.title->pages")))
	assert_strings_equal(c"hint 'Tag->Author': the new table already exists", detect_error(library_schema_json(), library_schema_json(), one_hint(c"Tag->Author")))
	assert_strings_equal(c"invalid schema JSON", detect_error(c"{", library_schema_json(), 0))
	# A rename hint cannot ride along with a rebuild of the same table.
	json_value* s = lib_snapshot()
	json_value* book = model_of(s, c"Book")
	json_value* title = field_of(book, c"title")
	orm_sj_set_str(title, c"column", c"headline")
	json_object_set(field_of(book, c"price"), c"digits", json_int(9))
	assert_strings_equal(c"table library_book needs a rebuild; a column rename hint cannot be combined with it", detect_error(library_schema_json(), text_of(s), one_hint(c"Book.title->headline")))


void test_replay_errors_surface():
	list[orm_migration*] ms = new list[orm_migration*]
	orm_migration* m = orm_migration_new(c"library", c"0001_bad")
	orm_migration_add(m, orm_op_new(ORM_OP_DROP_COLUMN, ORM_PHASE_CONTRACT, c"nowhere"))
	ms.push(m)
	orm_makemig* r = orm_makemigrations_next(c"library", ms, library_schema_json(), ORM_DIALECT_SQLITE, 0)
	assert_strings_equal(c"0001_bad: DROP_COLUMN: unknown table nowhere", r.error)
	orm_makemig_free(r)


void test_empty_diff():
	orm_makemig* r = orm_makemigrations(c"library", library_schema_json(), library_schema_json(), ORM_DIALECT_POSTGRES, 2, c"0001_initial", 0)
	asserts(r.error, r.error == 0)
	assert_equal(0, r.migrations.length)
	orm_makemig_free(r)


int main():
	test_initial_migration()
	test_numbering_and_dependencies()
	test_add_columns()
	test_drop_column()
	test_alter_null()
	test_deprecate_and_restore()
	test_type_change_rebuilds()
	test_add_fk_to_int_column()
	test_indexes()
	test_checks_and_unique_together()
	test_models_and_m2m()
	test_history_flags()
	test_rename_column_hint()
	test_rename_table_hint()
	test_hint_errors()
	test_replay_errors_surface()
	test_empty_diff()
	print(c"orm_autodetect_test: ok\n")
	return 0
