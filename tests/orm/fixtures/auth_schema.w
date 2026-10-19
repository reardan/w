# Hand-written DDL for libs/standard/orm/auth/auth.orm on SQLite and
# PostgreSQL, used by the U3.1 auth tests until the migration applier
# (U2.4) creates tables from the schema snapshot. Table and column names
# are Django's (auth_user, auth_group, auth_permission, django_content_type
# and the three M2M join tables); the column set matches the descriptors in
# libs/standard/orm/auth/auth_orm.w.
import libs.standard.orm.contract


char* auth_sqlite_ddl(int i):
	if (i == 0): return c"CREATE TABLE django_content_type (id INTEGER PRIMARY KEY AUTOINCREMENT, app_label VARCHAR(100) NOT NULL, model VARCHAR(100) NOT NULL, UNIQUE (app_label, model))"
	if (i == 1): return c"CREATE TABLE auth_permission (id INTEGER PRIMARY KEY AUTOINCREMENT, name VARCHAR(255) NOT NULL, content_type_id INTEGER NOT NULL REFERENCES django_content_type (id) ON DELETE CASCADE, codename VARCHAR(100) NOT NULL, UNIQUE (content_type_id, codename))"
	if (i == 2): return c"CREATE INDEX auth_permission_content_type_id_idx ON auth_permission (content_type_id)"
	if (i == 3): return c"CREATE TABLE auth_group (id INTEGER PRIMARY KEY AUTOINCREMENT, name VARCHAR(150) NOT NULL UNIQUE)"
	if (i == 4): return c"CREATE TABLE auth_group_permissions (id INTEGER PRIMARY KEY AUTOINCREMENT, group_id INTEGER NOT NULL REFERENCES auth_group (id) ON DELETE CASCADE, permission_id INTEGER NOT NULL REFERENCES auth_permission (id) ON DELETE CASCADE, UNIQUE (group_id, permission_id))"
	if (i == 5): return c"CREATE TABLE auth_user (id INTEGER PRIMARY KEY AUTOINCREMENT, password VARCHAR(128) NOT NULL, last_login TEXT NULL, is_superuser BOOLEAN NOT NULL DEFAULT FALSE, username VARCHAR(150) NOT NULL UNIQUE, first_name VARCHAR(150) NOT NULL DEFAULT '', last_name VARCHAR(150) NOT NULL DEFAULT '', email VARCHAR(254) NOT NULL DEFAULT '', is_staff BOOLEAN NOT NULL DEFAULT FALSE, is_active BOOLEAN NOT NULL DEFAULT TRUE, date_joined TEXT NOT NULL)"
	if (i == 6): return c"CREATE TABLE auth_user_groups (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL REFERENCES auth_user (id) ON DELETE CASCADE, group_id INTEGER NOT NULL REFERENCES auth_group (id) ON DELETE CASCADE, UNIQUE (user_id, group_id))"
	if (i == 7): return c"CREATE TABLE auth_user_user_permissions (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL REFERENCES auth_user (id) ON DELETE CASCADE, permission_id INTEGER NOT NULL REFERENCES auth_permission (id) ON DELETE CASCADE, UNIQUE (user_id, permission_id))"
	return 0


char* auth_postgres_ddl(int i):
	if (i == 0): return c"CREATE TABLE django_content_type (id BIGSERIAL PRIMARY KEY, app_label VARCHAR(100) NOT NULL, model VARCHAR(100) NOT NULL, UNIQUE (app_label, model))"
	if (i == 1): return c"CREATE TABLE auth_permission (id BIGSERIAL PRIMARY KEY, name VARCHAR(255) NOT NULL, content_type_id BIGINT NOT NULL REFERENCES django_content_type (id) ON DELETE CASCADE, codename VARCHAR(100) NOT NULL, UNIQUE (content_type_id, codename))"
	if (i == 2): return c"CREATE INDEX auth_permission_content_type_id_idx ON auth_permission (content_type_id)"
	if (i == 3): return c"CREATE TABLE auth_group (id BIGSERIAL PRIMARY KEY, name VARCHAR(150) NOT NULL UNIQUE)"
	if (i == 4): return c"CREATE TABLE auth_group_permissions (id BIGSERIAL PRIMARY KEY, group_id BIGINT NOT NULL REFERENCES auth_group (id) ON DELETE CASCADE, permission_id BIGINT NOT NULL REFERENCES auth_permission (id) ON DELETE CASCADE, UNIQUE (group_id, permission_id))"
	if (i == 5): return c"CREATE TABLE auth_user (id BIGSERIAL PRIMARY KEY, password VARCHAR(128) NOT NULL, last_login TIMESTAMP NULL, is_superuser BOOLEAN NOT NULL DEFAULT FALSE, username VARCHAR(150) NOT NULL UNIQUE, first_name VARCHAR(150) NOT NULL DEFAULT '', last_name VARCHAR(150) NOT NULL DEFAULT '', email VARCHAR(254) NOT NULL DEFAULT '', is_staff BOOLEAN NOT NULL DEFAULT FALSE, is_active BOOLEAN NOT NULL DEFAULT TRUE, date_joined TIMESTAMP NOT NULL)"
	if (i == 6): return c"CREATE TABLE auth_user_groups (id BIGSERIAL PRIMARY KEY, user_id BIGINT NOT NULL REFERENCES auth_user (id) ON DELETE CASCADE, group_id BIGINT NOT NULL REFERENCES auth_group (id) ON DELETE CASCADE, UNIQUE (user_id, group_id))"
	if (i == 7): return c"CREATE TABLE auth_user_user_permissions (id BIGSERIAL PRIMARY KEY, user_id BIGINT NOT NULL REFERENCES auth_user (id) ON DELETE CASCADE, permission_id BIGINT NOT NULL REFERENCES auth_permission (id) ON DELETE CASCADE, UNIQUE (user_id, permission_id))"
	return 0


# Creates the auth tables on db. Returns 1, or 0 with orm_db_error(db).
int auth_create_schema(orm_db* db):
	int i = 0
	while (1):
		char* ddl = 0
		if (db.dialect.id == ORM_DIALECT_POSTGRES): ddl = auth_postgres_ddl(i)
		else: ddl = auth_sqlite_ddl(i)
		if (ddl == 0): return 1
		if (orm_db_exec_sql(db, ddl) == 0): return 0
		i = i + 1
	return 1


# Drops the auth tables (PostgreSQL tests reuse one database).
int auth_drop_schema(orm_db* db):
	int ok = orm_db_exec_sql(db, c"DROP TABLE IF EXISTS auth_user_user_permissions")
	ok = ok && orm_db_exec_sql(db, c"DROP TABLE IF EXISTS auth_user_groups")
	ok = ok && orm_db_exec_sql(db, c"DROP TABLE IF EXISTS auth_user")
	ok = ok && orm_db_exec_sql(db, c"DROP TABLE IF EXISTS auth_group_permissions")
	ok = ok && orm_db_exec_sql(db, c"DROP TABLE IF EXISTS auth_group")
	ok = ok && orm_db_exec_sql(db, c"DROP TABLE IF EXISTS auth_permission")
	ok = ok && orm_db_exec_sql(db, c"DROP TABLE IF EXISTS django_content_type")
	return ok
