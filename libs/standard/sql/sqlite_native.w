# Internal Linux x64 bindings. Handles and trampolines live for the process.
import libs.standard.sql.common

int __sql_sqlite3_open_v2
int __sql_sqlite3_close
int __sql_sqlite3_errmsg
int __sql_sqlite3_prepare_v2
int __sql_sqlite3_step
int __sql_sqlite3_finalize
int __sql_sqlite3_bind_parameter_count
int __sql_sqlite3_bind_null
int __sql_sqlite3_bind_text
int __sql_sqlite3_column_count
int __sql_sqlite3_column_name
int __sql_sqlite3_column_type
int __sql_sqlite3_column_text
int __sql_sqlite3_column_blob
int __sql_sqlite3_column_bytes
int __sql_sqlite3_total_changes64
int __sql_sqlite3_busy_timeout
int __sql_sqlite3_stmt_readonly

int __sql_sqlite_state

int sql_sqlite_available():
	if (__sql_sqlite_state != 0): return __sql_sqlite_state == 1
	__sql_sqlite_state = -1
	if (__word_size__ != 8 || __target_isa__ != 0 || os_windows()): return 0
	char* h = dl_open(c"libsqlite3.so.0")
	if (h == 0): return 0
	__sql_sqlite3_open_v2 = dl_trampoline_argv(dl_sym(h, c"sqlite3_open_v2"), 4, 1)
	if (__sql_sqlite3_open_v2 == 0): return 0
	__sql_sqlite3_close = dl_trampoline_argv(dl_sym(h, c"sqlite3_close"), 1, 1)
	if (__sql_sqlite3_close == 0): return 0
	__sql_sqlite3_errmsg = dl_trampoline_argv(dl_sym(h, c"sqlite3_errmsg"), 1, 0)
	if (__sql_sqlite3_errmsg == 0): return 0
	__sql_sqlite3_prepare_v2 = dl_trampoline_argv(dl_sym(h, c"sqlite3_prepare_v2"), 5, 1)
	if (__sql_sqlite3_prepare_v2 == 0): return 0
	__sql_sqlite3_step = dl_trampoline_argv(dl_sym(h, c"sqlite3_step"), 1, 1)
	if (__sql_sqlite3_step == 0): return 0
	__sql_sqlite3_finalize = dl_trampoline_argv(dl_sym(h, c"sqlite3_finalize"), 1, 1)
	if (__sql_sqlite3_finalize == 0): return 0
	__sql_sqlite3_bind_parameter_count = dl_trampoline_argv(dl_sym(h, c"sqlite3_bind_parameter_count"), 1, 1)
	if (__sql_sqlite3_bind_parameter_count == 0): return 0
	__sql_sqlite3_bind_null = dl_trampoline_argv(dl_sym(h, c"sqlite3_bind_null"), 2, 1)
	if (__sql_sqlite3_bind_null == 0): return 0
	__sql_sqlite3_bind_text = dl_trampoline_argv(dl_sym(h, c"sqlite3_bind_text"), 5, 1)
	if (__sql_sqlite3_bind_text == 0): return 0
	__sql_sqlite3_column_count = dl_trampoline_argv(dl_sym(h, c"sqlite3_column_count"), 1, 1)
	if (__sql_sqlite3_column_count == 0): return 0
	__sql_sqlite3_column_name = dl_trampoline_argv(dl_sym(h, c"sqlite3_column_name"), 2, 0)
	if (__sql_sqlite3_column_name == 0): return 0
	__sql_sqlite3_column_type = dl_trampoline_argv(dl_sym(h, c"sqlite3_column_type"), 2, 1)
	if (__sql_sqlite3_column_type == 0): return 0
	__sql_sqlite3_column_text = dl_trampoline_argv(dl_sym(h, c"sqlite3_column_text"), 2, 0)
	if (__sql_sqlite3_column_text == 0): return 0
	__sql_sqlite3_column_blob = dl_trampoline_argv(dl_sym(h, c"sqlite3_column_blob"), 2, 0)
	if (__sql_sqlite3_column_blob == 0): return 0
	__sql_sqlite3_column_bytes = dl_trampoline_argv(dl_sym(h, c"sqlite3_column_bytes"), 2, 1)
	if (__sql_sqlite3_column_bytes == 0): return 0
	__sql_sqlite3_total_changes64 = dl_trampoline_argv(dl_sym(h, c"sqlite3_total_changes64"), 1, 0)
	if (__sql_sqlite3_total_changes64 == 0): return 0
	__sql_sqlite3_busy_timeout = dl_trampoline_argv(dl_sym(h, c"sqlite3_busy_timeout"), 2, 1)
	if (__sql_sqlite3_busy_timeout == 0): return 0
	__sql_sqlite3_stmt_readonly = dl_trampoline_argv(dl_sym(h, c"sqlite3_stmt_readonly"), 1, 1)
	if (__sql_sqlite3_stmt_readonly == 0): return 0
	__sql_sqlite_state = 1
	return 1
