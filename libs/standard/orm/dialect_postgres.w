# PostgreSQL dialect for the w-orm compiler (issue #754, unit U1.2).
#
# The singleton carries the C5 capability flags; compile.w reads the flags
# and switches on d.id for the few spellings that differ.
import libs.standard.orm.contract


orm_dialect* __orm_dialect_postgres


orm_dialect* orm_dialect_postgres():
	if (__orm_dialect_postgres != 0): return __orm_dialect_postgres
	orm_dialect* d = new orm_dialect()
	d.id = ORM_DIALECT_POSTGRES
	d.name = c"postgresql"
	d.bind_style = sql_bind_dollar
	d.supports_returning = 1
	d.supports_for_update = 1
	d.supports_ilike = 1
	d.supports_nulls_order = 1
	d.supports_filter_clause = 1
	d.supports_concurrent_index = 1
	d.supports_transactional_ddl = 1
	d.supports_distinct_on = 1
	# The wire protocol counts bind parameters in an int16.
	d.max_params = 65535
	__orm_dialect_postgres = d
	return d


# PostgreSQL spelling of a portable function name (names are upper-case).
char* orm_postgres_function_name(char* name):
	if (strcmp(name, c"GROUP_CONCAT") == 0): return c"STRING_AGG"
	return name
