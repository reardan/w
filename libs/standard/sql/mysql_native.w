# Internal Linux x64 bindings. Handles and trampolines live for the process.
import libs.standard.sql.common

int __sql_mysql_init
int __sql_mysql_options
int __sql_mysql_real_connect
int __sql_mysql_error
int __sql_mysql_close
int __sql_mysql_set_character_set
int __sql_mysql_real_query
int __sql_mysql_store_result
int __sql_mysql_field_count
int __sql_mysql_num_fields
int __sql_mysql_fetch_row
int __sql_mysql_fetch_lengths
int __sql_mysql_free_result
int __sql_mysql_affected_rows
int __sql_mysql_errno
int __sql_mysql_fetch_field_direct
int __sql_mysql_next_result

int __sql_mysql_state

int sql_mysql_available():
	if (__sql_mysql_state != 0): return __sql_mysql_state == 1
	__sql_mysql_state = -1
	if (__word_size__ != 8 || __target_isa__ != 0 || os_windows()): return 0
	char* h = dl_open(c"libmysqlclient.so.21")
	if (h == 0): h = dl_open(c"libmariadb.so.3")
	if (h == 0): return 0
	__sql_mysql_init = dl_trampoline_argv(dl_sym(h, c"mysql_init"), 1, 0)
	if (__sql_mysql_init == 0): return 0
	__sql_mysql_options = dl_trampoline_argv(dl_sym(h, c"mysql_options"), 3, 1)
	if (__sql_mysql_options == 0): return 0
	__sql_mysql_real_connect = dl_trampoline_argv(dl_sym(h, c"mysql_real_connect"), 8, 0)
	if (__sql_mysql_real_connect == 0): return 0
	__sql_mysql_error = dl_trampoline_argv(dl_sym(h, c"mysql_error"), 1, 0)
	if (__sql_mysql_error == 0): return 0
	__sql_mysql_close = dl_trampoline_argv(dl_sym(h, c"mysql_close"), 1, 0)
	if (__sql_mysql_close == 0): return 0
	__sql_mysql_set_character_set = dl_trampoline_argv(dl_sym(h, c"mysql_set_character_set"), 2, 1)
	if (__sql_mysql_set_character_set == 0): return 0
	__sql_mysql_real_query = dl_trampoline_argv(dl_sym(h, c"mysql_real_query"), 3, 1)
	if (__sql_mysql_real_query == 0): return 0
	__sql_mysql_store_result = dl_trampoline_argv(dl_sym(h, c"mysql_store_result"), 1, 0)
	if (__sql_mysql_store_result == 0): return 0
	__sql_mysql_field_count = dl_trampoline_argv(dl_sym(h, c"mysql_field_count"), 1, 1)
	if (__sql_mysql_field_count == 0): return 0
	__sql_mysql_num_fields = dl_trampoline_argv(dl_sym(h, c"mysql_num_fields"), 1, 1)
	if (__sql_mysql_num_fields == 0): return 0
	__sql_mysql_fetch_row = dl_trampoline_argv(dl_sym(h, c"mysql_fetch_row"), 1, 0)
	if (__sql_mysql_fetch_row == 0): return 0
	__sql_mysql_fetch_lengths = dl_trampoline_argv(dl_sym(h, c"mysql_fetch_lengths"), 1, 0)
	if (__sql_mysql_fetch_lengths == 0): return 0
	__sql_mysql_free_result = dl_trampoline_argv(dl_sym(h, c"mysql_free_result"), 1, 0)
	if (__sql_mysql_free_result == 0): return 0
	__sql_mysql_affected_rows = dl_trampoline_argv(dl_sym(h, c"mysql_affected_rows"), 1, 0)
	if (__sql_mysql_affected_rows == 0): return 0
	__sql_mysql_errno = dl_trampoline_argv(dl_sym(h, c"mysql_errno"), 1, 1)
	if (__sql_mysql_errno == 0): return 0
	__sql_mysql_fetch_field_direct = dl_trampoline_argv(dl_sym(h, c"mysql_fetch_field_direct"), 2, 0)
	if (__sql_mysql_fetch_field_direct == 0): return 0
	__sql_mysql_next_result = dl_trampoline_argv(dl_sym(h, c"mysql_next_result"), 1, 1)
	if (__sql_mysql_next_result == 0): return 0
	__sql_mysql_state = 1
	return 1
