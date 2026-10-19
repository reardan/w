# orm_atomic, savepoints, on_commit and select_for_update over the library
# fixture (unit U2.1, docs/projects/orm/u2_1.md). Shared by
# tests/orm/orm_atomic_test.w (SQLite) and orm_relations_postgres_test.w.
# Transaction control statements count in db.query_count.
import tests.orm.orm_e2e_cases


struct at_ctx:
	char* email          # author to create
	char* inner_email    # created by the nested block, 0 = none
	int inner_ok         # what the nested block's function returns
	int outer_ok         # what the outer function returns after the nested block
	int inner_result     # orm_atomic's result for the nested block
	int duplicate        # nested block inserts a duplicate email (SQL error)
	int doom             # outer calls orm_set_rollback(db, 1)
	int* commits         # on_commit counter


int at_count(orm_db* db, char* email):
	return Author_objects(db).filter(q_eq(c"email", email)).count()


int at_insert(orm_db* db, char* email):
	Author* a = Author_new()
	a.name = c"Someone"
	a.email = email
	int ok = Author_save(db, a)
	Author_free(a)
	return ok


void at_bump(void* ctx):
	int* n = cast(int*, ctx)
	n[0] = n[0] + 1


int at_inner(orm_db* db, void* p):
	at_ctx* c = cast(at_ctx*, p)
	orm_on_commit(db, at_bump, cast(void*, c.commits))
	if (c.duplicate):
		if (at_insert(db, c.email)): return 1
		return 0
	if (at_insert(db, c.inner_email) == 0): return 0
	if (c.inner_ok == 0): orm_db_set_error(db, c"inner block gave up")
	return c.inner_ok


int at_outer(orm_db* db, void* p):
	at_ctx* c = cast(at_ctx*, p)
	if (at_insert(db, c.email) == 0): return 0
	orm_on_commit(db, at_bump, cast(void*, c.commits))
	if (c.inner_email != 0 || c.duplicate): c.inner_result = orm_atomic(db, at_inner, p)
	if (c.doom): orm_set_rollback(db, 1)
	if (c.outer_ok == 0 && orm_db_error(db)[0] == 0): orm_db_set_error(db, c"outer block gave up")
	return c.outer_ok


at_ctx* at_new(char* email, int* commits):
	at_ctx* c = new at_ctx()
	c.email = email
	c.inner_ok = 1
	c.outer_ok = 1
	c.commits = commits
	return c


void test_atomic_blocks(orm_db* db):
	int commits = 0
	# Commit: BEGIN, INSERT, COMMIT; on_commit runs once, after COMMIT.
	at_ctx* c = at_new(c"a1@example.com", &commits)
	assert_equal(1, orm_atomic(db, at_outer, c))
	expect_queries(db, 3)
	assert_equal(1, commits)
	assert_equal(0, db.atomic_depth)
	assert_equal(1, at_count(db, c"a1@example.com"))
	expect_queries(db, 1)
	# The function fails: rolled back, its error kept, callbacks dropped.
	c = at_new(c"a2@example.com", &commits)
	c.outer_ok = 0
	assert_equal(0, orm_atomic(db, at_outer, c))
	expect_queries(db, 3)
	assert_strings_equal(c"outer block gave up", orm_db_error(db))
	assert_equal(1, commits)
	assert_equal(0, at_count(db, c"a2@example.com"))
	expect_queries(db, 1)
	assert_equal(0, db.on_commit.length)
	# Nested block fails, outer carries on: savepoint rolled back only.
	c = at_new(c"a3@example.com", &commits)
	c.inner_email = c"a3-inner@example.com"
	c.inner_ok = 0
	assert_equal(1, orm_atomic(db, at_outer, c))
	# BEGIN, INSERT, SAVEPOINT, INSERT, ROLLBACK TO, RELEASE, COMMIT
	expect_queries(db, 7)
	assert_equal(0, c.inner_result)
	assert_equal(2, commits)
	assert_equal(1, at_count(db, c"a3@example.com"))
	assert_equal(0, at_count(db, c"a3-inner@example.com"))
	expect_queries(db, 2)
	# Nested block succeeds, both commit; both callbacks run.
	c = at_new(c"a4@example.com", &commits)
	c.inner_email = c"a4-inner@example.com"
	assert_equal(1, orm_atomic(db, at_outer, c))
	# BEGIN, INSERT, SAVEPOINT, INSERT, RELEASE, COMMIT
	expect_queries(db, 6)
	assert_equal(1, c.inner_result)
	assert_equal(4, commits)
	assert_equal(1, at_count(db, c"a4-inner@example.com"))
	expect_queries(db, 1)
	# Nested block succeeds but the outer fails: everything rolls back.
	c = at_new(c"a5@example.com", &commits)
	c.inner_email = c"a5-inner@example.com"
	c.outer_ok = 0
	assert_equal(0, orm_atomic(db, at_outer, c))
	expect_queries(db, 6)
	assert_equal(4, commits)
	assert_equal(0, at_count(db, c"a5-inner@example.com"))
	expect_queries(db, 1)
	# An SQL error inside the nested block (duplicate email): the savepoint
	# recovers the transaction (PostgreSQL aborts it otherwise).
	c = at_new(c"a6@example.com", &commits)
	c.duplicate = 1
	assert_equal(1, orm_atomic(db, at_outer, c))
	expect_queries(db, 7)
	assert_equal(0, c.inner_result)
	assert_equal(5, commits)
	assert_equal(1, at_count(db, c"a6@example.com"))
	expect_queries(db, 1)
	# rollback_only: the function returned 1 but the block is doomed.
	c = at_new(c"a7@example.com", &commits)
	c.doom = 1
	assert_equal(0, orm_atomic(db, at_outer, c))
	expect_queries(db, 3)
	assert_contains(orm_db_error(db), c"rollback-only")
	assert_equal(0, db.rollback_only)
	assert_equal(5, commits)
	assert_equal(0, at_count(db, c"a7@example.com"))
	expect_queries(db, 1)
	# Outside a transaction on_commit runs at once.
	orm_on_commit(db, at_bump, cast(void*, &commits))
	assert_equal(6, commits)


void test_atomic_primitives(orm_db* db):
	int commits = 0
	orm_atomic_block* outer = orm_atomic_begin(db)
	asserts(orm_db_error(db), outer != 0)
	assert1(orm_in_atomic(db))
	check(db, at_insert(db, c"p1@example.com"))
	orm_atomic_block* inner = orm_atomic_begin(db)
	assert_equal(2, db.atomic_depth)
	check(db, at_insert(db, c"p2@example.com"))
	orm_on_commit(db, at_bump, cast(void*, &commits))
	# Ending the outer block first is refused.
	assert_equal(0, orm_atomic_commit(db, outer))
	assert_contains(orm_db_error(db), c"reverse order")
	check(db, orm_atomic_rollback(db, inner))
	assert_equal(1, db.atomic_depth)
	assert_equal(0, db.on_commit.length)
	inner = orm_atomic_begin(db)
	check(db, at_insert(db, c"p3@example.com"))
	orm_on_commit(db, at_bump, cast(void*, &commits))
	check(db, orm_atomic_commit(db, inner))
	assert_equal(0, commits)
	check(db, orm_atomic_commit(db, outer))
	assert_equal(1, commits)
	assert1(orm_in_atomic(db) == 0)
	assert_equal(1, at_count(db, c"p1@example.com"))
	assert_equal(0, at_count(db, c"p2@example.com"))
	assert_equal(1, at_count(db, c"p3@example.com"))
	# Outer rollback discards everything, including released savepoints.
	outer = orm_atomic_begin(db)
	inner = orm_atomic_begin(db)
	check(db, at_insert(db, c"p4@example.com"))
	orm_on_commit(db, at_bump, cast(void*, &commits))
	check(db, orm_atomic_commit(db, inner))
	check(db, orm_atomic_rollback(db, outer))
	assert_equal(1, commits)
	assert_equal(0, at_count(db, c"p4@example.com"))
	# A savepoint marked rollback-only rolls back only itself.
	outer = orm_atomic_begin(db)
	inner = orm_atomic_begin(db)
	check(db, at_insert(db, c"p5@example.com"))
	orm_set_rollback(db, 1)
	assert1(orm_get_rollback(db))
	assert_equal(0, orm_atomic_commit(db, inner))
	assert_equal(0, orm_get_rollback(db))
	check(db, at_insert(db, c"p6@example.com"))
	check(db, orm_atomic_commit(db, outer))
	assert_equal(0, at_count(db, c"p5@example.com"))
	assert_equal(1, at_count(db, c"p6@example.com"))
	__e2e_mark = db.query_count


void test_atomic_for_update(orm_db* db):
	orm_atomic_block* b = orm_atomic_begin(db)
	orm_result* r = Author_objects(db).for_update(1, 0).order_by(c"id").limit(1).all()
	if (db.dialect.supports_for_update):
		asserts(orm_db_error(db), r != 0)
		assert_equal(1, r.rows.length)
		orm_result_free(r)
	else:
		assert1(r == 0)
		assert_strings_equal(c"orm: select_for_update is not supported by this database", orm_db_error(db))
	check(db, orm_atomic_commit(db, b))
	__e2e_mark = db.query_count


void test_atomic_get_or_create_race(orm_db* db):
	check(db, at_insert(db, c"race@example.com"))
	orm_atomic_block* b = orm_atomic_begin(db)
	asserts(orm_db_error(db), b != 0)
	# The lookup misses but the INSERT hits the unique email: the INSERT's
	# own savepoint rolls back, so the transaction stays usable on
	# PostgreSQL and the outer block still commits.
	list[orm_assignment*] clash = new list[orm_assignment*]
	clash.push(orm_set_text(c"name", c"Impostor"))
	clash.push(orm_set_text(c"email", c"race@example.com"))
	int created = -1
	orm_result* r = orm_get_or_create(db, Author_desc(), clash, 0, &created)
	assert1(r == 0)
	assert_equal(0, created)
	assert_equal(1, db.atomic_depth)
	check(db, at_insert(db, c"race2@example.com"))
	check(db, orm_atomic_commit(db, b))
	assert_equal(1, at_count(db, c"race2@example.com"))
	clash.free()
	__e2e_mark = db.query_count


void orm_atomic_run(orm_db* db):
	library_register()
	db.log_queries = 1
	check(db, library_create_schema(db))
	__e2e_mark = db.query_count
	test_atomic_blocks(db)
	test_atomic_primitives(db)
	test_atomic_for_update(db)
	test_atomic_get_or_create_race(db)
