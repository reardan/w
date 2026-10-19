# Hand-written DDL for tests/orm/fixtures/library.orm on SQLite and
# PostgreSQL, used by ORM tests until the migration units (U2.x) create
# schemas. Matches the descriptors in library_orm.w (C1 naming rules).
import libs.standard.orm.contract


char* library_sqlite_ddl(int i):
	if (i == 0): return c"CREATE TABLE library_author (id INTEGER PRIMARY KEY AUTOINCREMENT, name VARCHAR(200) NOT NULL, email VARCHAR(254) NOT NULL UNIQUE, created TEXT NOT NULL)"
	if (i == 1): return c"CREATE INDEX library_author_created_idx ON library_author (created)"
	if (i == 2): return c"CREATE TABLE library_tag (id INTEGER PRIMARY KEY AUTOINCREMENT, name VARCHAR(50) NOT NULL UNIQUE)"
	if (i == 3): return c"CREATE TABLE library_book (id INTEGER PRIMARY KEY AUTOINCREMENT, title VARCHAR(300) NOT NULL, author_id INTEGER NOT NULL REFERENCES library_author (id) ON DELETE CASCADE, status VARCHAR(5) NOT NULL DEFAULT 'draft', price NUMERIC(8, 2) NOT NULL, pages INTEGER NULL, published_at TEXT NULL, CONSTRAINT library_book_price_nonnegative CHECK (price >= 0))"
	if (i == 4): return c"CREATE INDEX library_book_author_id_idx ON library_book (author_id)"
	if (i == 5): return c"CREATE TABLE library_book_tags (id INTEGER PRIMARY KEY AUTOINCREMENT, book_id INTEGER NOT NULL REFERENCES library_book (id) ON DELETE CASCADE, tag_id INTEGER NOT NULL REFERENCES library_tag (id) ON DELETE CASCADE, UNIQUE (book_id, tag_id))"
	return 0


char* library_postgres_ddl(int i):
	if (i == 0): return c"CREATE TABLE library_author (id BIGSERIAL PRIMARY KEY, name VARCHAR(200) NOT NULL, email VARCHAR(254) NOT NULL UNIQUE, created TIMESTAMP NOT NULL)"
	if (i == 1): return c"CREATE INDEX library_author_created_idx ON library_author (created)"
	if (i == 2): return c"CREATE TABLE library_tag (id BIGSERIAL PRIMARY KEY, name VARCHAR(50) NOT NULL UNIQUE)"
	if (i == 3): return c"CREATE TABLE library_book (id BIGSERIAL PRIMARY KEY, title VARCHAR(300) NOT NULL, author_id BIGINT NOT NULL REFERENCES library_author (id) ON DELETE CASCADE, status VARCHAR(5) NOT NULL DEFAULT 'draft', price NUMERIC(8, 2) NOT NULL, pages BIGINT NULL, published_at TIMESTAMP NULL, CONSTRAINT library_book_price_nonnegative CHECK (price >= 0))"
	if (i == 4): return c"CREATE INDEX library_book_author_id_idx ON library_book (author_id)"
	if (i == 5): return c"CREATE TABLE library_book_tags (id BIGSERIAL PRIMARY KEY, book_id BIGINT NOT NULL REFERENCES library_book (id) ON DELETE CASCADE, tag_id BIGINT NOT NULL REFERENCES library_tag (id) ON DELETE CASCADE, UNIQUE (book_id, tag_id))"
	return 0


# Creates the library tables on db (SQLite or PostgreSQL). Returns 1, or 0
# with orm_db_error(db) set. Statements count in db.query_count.
int library_create_schema(orm_db* db):
	int i = 0
	while (1):
		char* ddl = 0
		if (db.dialect.id == ORM_DIALECT_POSTGRES): ddl = library_postgres_ddl(i)
		else: ddl = library_sqlite_ddl(i)
		if (ddl == 0): return 1
		if (orm_db_exec_sql(db, ddl) == 0): return 0
		i = i + 1
	return 1


# Drops the library tables (PostgreSQL tests reuse one database).
int library_drop_schema(orm_db* db):
	int ok = orm_db_exec_sql(db, c"DROP TABLE IF EXISTS library_book_tags")
	ok = ok && orm_db_exec_sql(db, c"DROP TABLE IF EXISTS library_book")
	ok = ok && orm_db_exec_sql(db, c"DROP TABLE IF EXISTS library_tag")
	ok = ok && orm_db_exec_sql(db, c"DROP TABLE IF EXISTS library_author")
	return ok
