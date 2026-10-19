# wbuild: arch_only=x64
# wbuild: target=orm_relations_postgres_local_test tag=tests dep=orm_relations_postgres_test dep=sql_postgres_fixture data=tests/sql_postgres_fixture.w
# wbuild: step="bin/sql_postgres_fixture bin/orm_relations_postgres_test"
# U2.1 on PostgreSQL: the orm_related_test and orm_atomic_test scenarios,
# an aborted savepoint, and select_for_update(skip_locked) across two
# connections. Needs W_SQL_POSTGRES (a libpq conninfo for an empty
# database); orm_relations_postgres_local_test starts a temporary cluster.
import tests.orm.orm_related_cases
import tests.orm.orm_atomic_cases
import lib.env


# Returns 1 although its statement failed: PostgreSQL aborted the
# transaction, so RELEASE fails and the block rolls back to its savepoint.
int pg_ignore_error(orm_db* db, void* ctx):
	at_insert(db, c"a1@example.com")
	return 1


void test_aborted_savepoint(orm_db* db):
	orm_atomic_block* outer = orm_atomic_begin(db)
	asserts(orm_db_error(db), outer != 0)
	assert_equal(0, orm_atomic(db, pg_ignore_error, 0))
	assert_contains(orm_db_error(db), c"could not release savepoint")
	# The transaction is usable again.
	check(db, at_insert(db, c"pg1@example.com"))
	check(db, orm_atomic_commit(db, outer))
	assert_equal(1, at_count(db, c"pg1@example.com"))


int first_id(orm_db* db, orm_result* r):
	asserts(orm_db_error(db), r != 0)
	assert_equal(1, r.rows.length)
	int id = Author_rows(r)[0].id
	orm_result_free(r)
	return id


void test_skip_locked(orm_db* a, orm_db* b):
	orm_atomic_block* ta = orm_atomic_begin(a)
	asserts(orm_db_error(a), ta != 0)
	int locked = first_id(a, Author_objects(a).for_update(1, 0).order_by(c"id").limit(1).all())
	orm_atomic_block* tb = orm_atomic_begin(b)
	asserts(orm_db_error(b), tb != 0)
	# B skips the row A holds.
	int other = first_id(b, Author_objects(b).for_update(1, 0).order_by(c"id").limit(1).all())
	assert1(other > locked)
	# NOWAIT on A's row fails at once (and aborts B's transaction).
	assert1(Author_objects(b).filter(q_eq_int(c"id", locked)).for_update(0, 1).all() == 0)
	assert_contains(orm_db_error(b), c"lock")
	check(b, orm_atomic_rollback(b, tb))
	check(a, orm_atomic_commit(a, ta))
	# Once A committed, B gets the first row.
	tb = orm_atomic_begin(b)
	assert_equal(locked, first_id(b, Author_objects(b).for_update(1, 0).order_by(c"id").limit(1).all()))
	check(b, orm_atomic_commit(b, tb))


int main():
	char* conninfo = env_get(c"W_SQL_POSTGRES")
	if (conninfo == 0):
		println(c"orm relations PostgreSQL: SKIP (W_SQL_POSTGRES unset)")
		return 0
	orm_db* db = orm_open_postgres(conninfo)
	asserts(orm_db_error(db), orm_is_open(db))
	check(db, orm_db_exec_sql(db, c"SET client_min_messages = warning"))
	check(db, library_drop_schema(db))
	orm_related_run(db, c"INSERT INTO library_tag (name) SELECT 'bulk' || x FROM generate_series(1, 120000) AS x")
	check(db, library_drop_schema(db))
	orm_atomic_run(db)
	test_aborted_savepoint(db)
	orm_db* other = orm_open_postgres(conninfo)
	asserts(orm_db_error(other), orm_is_open(other))
	test_skip_locked(db, other)
	orm_close(other)
	check(db, library_drop_schema(db))
	orm_close(db)
	println(c"orm_relations_postgres_test: OK")
	return 0
