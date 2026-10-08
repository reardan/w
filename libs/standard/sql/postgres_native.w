# Internal Linux x64 bindings. Handles and trampolines live for the process.
import libs.standard.sql.common

int __sql_PQconnectdb
int __sql_PQstatus
int __sql_PQtransactionStatus
int __sql_PQerrorMessage
int __sql_PQfinish
int __sql_PQexecParams
int __sql_PQresultStatus
int __sql_PQresultErrorMessage
int __sql_PQntuples
int __sql_PQnfields
int __sql_PQfname
int __sql_PQgetisnull
int __sql_PQgetvalue
int __sql_PQgetlength
int __sql_PQcmdTuples
int __sql_PQclear

int __sql_postgres_state

int sql_postgres_available():
	if (__sql_postgres_state != 0): return __sql_postgres_state == 1
	__sql_postgres_state = -1
	if (__word_size__ != 8 || __target_isa__ != 0 || os_windows()): return 0
	char* h = dl_open(c"libpq.so.5")
	if (h == 0): return 0
	__sql_PQconnectdb = dl_trampoline_argv(dl_sym(h, c"PQconnectdb"), 1, 0)
	if (__sql_PQconnectdb == 0): return 0
	__sql_PQstatus = dl_trampoline_argv(dl_sym(h, c"PQstatus"), 1, 1)
	if (__sql_PQstatus == 0): return 0
	__sql_PQtransactionStatus = dl_trampoline_argv(dl_sym(h, c"PQtransactionStatus"), 1, 1)
	if (__sql_PQtransactionStatus == 0): return 0
	__sql_PQerrorMessage = dl_trampoline_argv(dl_sym(h, c"PQerrorMessage"), 1, 0)
	if (__sql_PQerrorMessage == 0): return 0
	__sql_PQfinish = dl_trampoline_argv(dl_sym(h, c"PQfinish"), 1, 0)
	if (__sql_PQfinish == 0): return 0
	__sql_PQexecParams = dl_trampoline_argv(dl_sym(h, c"PQexecParams"), 8, 0)
	if (__sql_PQexecParams == 0): return 0
	__sql_PQresultStatus = dl_trampoline_argv(dl_sym(h, c"PQresultStatus"), 1, 1)
	if (__sql_PQresultStatus == 0): return 0
	__sql_PQresultErrorMessage = dl_trampoline_argv(dl_sym(h, c"PQresultErrorMessage"), 1, 0)
	if (__sql_PQresultErrorMessage == 0): return 0
	__sql_PQntuples = dl_trampoline_argv(dl_sym(h, c"PQntuples"), 1, 1)
	if (__sql_PQntuples == 0): return 0
	__sql_PQnfields = dl_trampoline_argv(dl_sym(h, c"PQnfields"), 1, 1)
	if (__sql_PQnfields == 0): return 0
	__sql_PQfname = dl_trampoline_argv(dl_sym(h, c"PQfname"), 2, 0)
	if (__sql_PQfname == 0): return 0
	__sql_PQgetisnull = dl_trampoline_argv(dl_sym(h, c"PQgetisnull"), 3, 1)
	if (__sql_PQgetisnull == 0): return 0
	__sql_PQgetvalue = dl_trampoline_argv(dl_sym(h, c"PQgetvalue"), 3, 0)
	if (__sql_PQgetvalue == 0): return 0
	__sql_PQgetlength = dl_trampoline_argv(dl_sym(h, c"PQgetlength"), 3, 1)
	if (__sql_PQgetlength == 0): return 0
	__sql_PQcmdTuples = dl_trampoline_argv(dl_sym(h, c"PQcmdTuples"), 1, 0)
	if (__sql_PQcmdTuples == 0): return 0
	__sql_PQclear = dl_trampoline_argv(dl_sym(h, c"PQclear"), 1, 0)
	if (__sql_PQclear == 0): return 0
	__sql_postgres_state = 1
	return 1
