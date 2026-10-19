# w-orm transactions (unit U2.1, docs/projects/orm/u2_1.md).
#
#   int transfer(orm_db* db, void* ctx):
#       ... writes; return 0 (with orm_db_error set) to roll back
#       return 1
#   if (orm_atomic(db, transfer, &args) == 0): report(orm_db_error(db))
#
# The outermost block is BEGIN ... COMMIT (sql_begin); nested blocks are
# savepoints w_sp_<depth> (libs/standard/sql/savepoint.w). A block that
# fails rolls back to its own start and returns 0 to the enclosing code,
# which decides whether to fail too (propagate) or carry on. Transaction
# control statements count in db.query_count like any other statement.
#
# rollback_only: orm_set_rollback(db, 1) dooms the innermost open block:
# when that block ends it rolls back (even when its function returned 1)
# and returns 0, and the flag is cleared. The flag is also set when rolling
# back to a savepoint fails, so the enclosing block rolls back too.
#
# on_commit: callbacks queued while a transaction is open run, in order,
# after the outermost COMMIT succeeds; ones queued inside a block that
# rolls back are discarded with it. Outside a transaction they run at once.
import libs.standard.orm.contract
import libs.standard.sql.savepoint


type orm_atomic_fn = fn(orm_db*, void*) -> int


# One open block (begin/commit/rollback primitives). Blocks must end in
# reverse order of beginning.
struct orm_atomic_block:
	int depth            # db.atomic_depth while this block is innermost
	char* savepoint      # owned name, 0 for the outermost block
	int on_commit_mark   # db.on_commit.length when the block began


int orm_atomic_fail(orm_db* db, char* message, char* detail):
	string_builder* msg = string_new()
	string_append(msg, message)
	if (detail != 0 && detail[0] != 0):
		string_append(msg, c": ")
		string_append(msg, detail)
	orm_db_set_error(db, msg.data)
	string_free(msg)
	return 0


void orm_atomic_count(orm_db* db, char* text):
	db.query_count = db.query_count + 1
	if (db.log_queries): db.query_log.push(strclone(text))


int orm_in_atomic(orm_db* db):
	return db != 0 && db.atomic_depth > 0


void orm_set_rollback(orm_db* db, int flag):
	db.rollback_only = flag != 0


int orm_get_rollback(orm_db* db):
	return db.rollback_only


# Opens a block: BEGIN when no transaction is open, else a savepoint.
# Returns the block, or 0 with orm_db_error(db) set.
orm_atomic_block* orm_atomic_begin(orm_db* db):
	if (db == 0): return 0
	if (db.conn == 0):
		orm_db_set_error(db, c"orm: database is not open")
		return 0
	int depth = db.atomic_depth + 1
	char* name = 0
	if (depth == 1):
		orm_atomic_count(db, c"BEGIN")
		if (sql_begin(db.conn) == 0):
			orm_atomic_fail(db, c"orm: could not begin a transaction", sql_error(db.conn))
			return 0
		db.rollback_only = 0
		if (db.on_begin != 0):
			db.atomic_depth = 1
			orm_begin_fn* hook = cast(orm_begin_fn*, db.on_begin)
			int ok = hook(db)
			db.atomic_depth = 0
			if (ok == 0):
				orm_atomic_count(db, c"ROLLBACK")
				sql_rollback(db.conn)
				return 0
	else:
		name = sql_savepoint_name(depth - 1)
		orm_atomic_count(db, c"SAVEPOINT")
		if (sql_savepoint(db.conn, name) == 0):
			orm_atomic_fail(db, c"orm: could not create a savepoint", sql_error(db.conn))
			free(name)
			return 0
	orm_atomic_block* b = new orm_atomic_block()
	b.depth = depth
	b.savepoint = name
	b.on_commit_mark = db.on_commit.length
	db.atomic_depth = depth
	return b


void orm_atomic_block_free(orm_atomic_block* b):
	if (b.savepoint != 0): free(b.savepoint)
	free(cast(void*, b))


# Drops callbacks queued after mark.
void orm_on_commit_discard(orm_db* db, int mark):
	while (db.on_commit.length > mark):
		orm_callback* cb = db.on_commit.pop()
		free(cast(void*, cb))


void orm_on_commit_run(orm_db* db):
	list[orm_callback*] pending = db.on_commit
	db.on_commit = new list[orm_callback*]
	for orm_callback* cb in pending:
		orm_callback_fn* fn = cb.fn
		fn(cb.ctx)
		free(cast(void*, cb))
	pending.free()


int orm_atomic_check_order(orm_db* db, orm_atomic_block* b):
	if (b == 0): return orm_db_set_error(db, c"orm: no atomic block")
	if (b.depth != db.atomic_depth): return orm_db_set_error(db, c"orm: atomic blocks must end in reverse order")
	return 1


# Rolls the block back (ROLLBACK, or ROLLBACK TO + RELEASE its savepoint)
# and frees it. Keeps orm_db_error unless the rollback itself fails.
# Returns 1 when the rollback succeeded.
int orm_atomic_rollback(orm_db* db, orm_atomic_block* b):
	if (orm_atomic_check_order(db, b) == 0): return 0
	int ok = 1
	orm_on_commit_discard(db, b.on_commit_mark)
	if (b.savepoint == 0):
		orm_atomic_count(db, c"ROLLBACK")
		if (sql_rollback(db.conn) == 0):
			ok = orm_atomic_fail(db, c"orm: rollback failed", sql_error(db.conn))
		db.rollback_only = 0
		orm_on_commit_discard(db, 0)
	else:
		orm_atomic_count(db, c"ROLLBACK TO SAVEPOINT")
		if (sql_rollback_to_savepoint(db.conn, b.savepoint) == 0):
			ok = orm_atomic_fail(db, c"orm: rollback to savepoint failed", sql_error(db.conn))
			db.rollback_only = 1
		else:
			orm_atomic_count(db, c"RELEASE SAVEPOINT")
			if (sql_release_savepoint(db.conn, b.savepoint) == 0):
				ok = orm_atomic_fail(db, c"orm: release savepoint failed", sql_error(db.conn))
				db.rollback_only = 1
			else: db.rollback_only = 0
	db.atomic_depth = b.depth - 1
	orm_atomic_block_free(b)
	return ok


# Commits the block (COMMIT, or RELEASE its savepoint) and frees it. The
# outermost COMMIT runs the on_commit callbacks. A block marked
# rollback-only, or one whose commit fails, is rolled back instead and 0
# is returned with orm_db_error set.
int orm_atomic_commit(orm_db* db, orm_atomic_block* b):
	if (orm_atomic_check_order(db, b) == 0): return 0
	if (db.rollback_only):
		orm_atomic_rollback(db, b)
		return orm_db_set_error(db, c"orm: transaction was marked rollback-only")
	if (b.savepoint != 0):
		orm_atomic_count(db, c"RELEASE SAVEPOINT")
		if (sql_release_savepoint(db.conn, b.savepoint) == 0):
			# PostgreSQL: a statement in the block failed and aborted it.
			char* err = strclone(sql_error(db.conn))
			orm_atomic_rollback(db, b)
			orm_atomic_fail(db, c"orm: could not release savepoint", err)
			free(err)
			return 0
		db.atomic_depth = b.depth - 1
		orm_atomic_block_free(b)
		return 1
	orm_atomic_count(db, c"COMMIT")
	if (sql_commit(db.conn) == 0):
		char* err = strclone(sql_error(db.conn))
		if (db.conn.transaction):
			orm_atomic_count(db, c"ROLLBACK")
			sql_rollback(db.conn)
		orm_on_commit_discard(db, 0)
		db.atomic_depth = 0
		db.rollback_only = 0
		orm_atomic_block_free(b)
		orm_atomic_fail(db, c"orm: commit failed", err)
		free(err)
		return 0
	db.atomic_depth = 0
	db.rollback_only = 0
	orm_atomic_block_free(b)
	orm_on_commit_run(db)
	return 1


# Runs fn(db, ctx) in a block. fn returns 1 to commit (release), 0 to roll
# back. Returns 1 when the block's work was kept, else 0 with
# orm_db_error(db) describing the failure (fn's own error is kept).
int orm_atomic(orm_db* db, orm_atomic_fn* fn, void* ctx):
	orm_atomic_block* b = orm_atomic_begin(db)
	if (b == 0): return 0
	orm_db_set_error(db, c"")
	int ok = fn(db, ctx)
	if (ok): return orm_atomic_commit(db, b)
	if (db.error == 0 || db.error[0] == 0): orm_db_set_error(db, c"orm: atomic block failed")
	char* err = strclone(db.error)
	orm_atomic_rollback(db, b)
	if (db.error == 0 || db.error[0] == 0 || strcmp(db.error, err) == 0): orm_db_set_error(db, err)
	free(err)
	return 0


# Queues fn(ctx) to run after the outermost transaction commits; runs it
# immediately when no transaction is open.
void orm_on_commit(orm_db* db, orm_callback_fn* fn, void* ctx):
	if (db.atomic_depth == 0):
		fn(ctx)
		return
	orm_callback* cb = new orm_callback()
	cb.fn = fn
	cb.ctx = ctx
	db.on_commit.push(cb)
