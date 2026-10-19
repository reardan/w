# SQLite dialect for the w-orm compiler (issue #754, unit U1.2).
#
# The singleton carries the C5 capability flags; compile.w reads the flags
# and switches on d.id for the few spellings that differ. Flags assume
# SQLite >= 3.35 (RETURNING; FILTER and NULLS FIRST/LAST need 3.30).
import libs.standard.orm.contract


orm_dialect* __orm_dialect_sqlite


orm_dialect* orm_dialect_sqlite():
	if (__orm_dialect_sqlite != 0): return __orm_dialect_sqlite
	orm_dialect* d = new orm_dialect()
	d.id = ORM_DIALECT_SQLITE
	d.name = c"sqlite"
	d.bind_style = sql_bind_question
	d.supports_returning = 1
	d.supports_for_update = 0
	d.supports_ilike = 0
	d.supports_nulls_order = 1
	d.supports_filter_clause = 1
	d.supports_concurrent_index = 0
	d.supports_transactional_ddl = 1
	d.supports_distinct_on = 0
	# SQLITE_MAX_VARIABLE_NUMBER before 3.32; bulk callers batch below it.
	d.max_params = 999
	__orm_dialect_sqlite = d
	return d


# SQLite spelling of a portable function name (names are upper-case).
char* orm_sqlite_function_name(char* name):
	if (strcmp(name, c"GREATEST") == 0): return c"MAX"
	if (strcmp(name, c"LEAST") == 0): return c"MIN"
	if (strcmp(name, c"STRING_AGG") == 0): return c"GROUP_CONCAT"
	return name
