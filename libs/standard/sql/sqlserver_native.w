# Internal Linux x64 bindings. Handles and trampolines live for the process.
import libs.standard.sql.common

int __sql_dbinit
int __sql_dblogin
int __sql_dbloginfree
int __sql_dbsetlname
int __sql_dbsetlversion
int __sql_tdsdbopen
int __sql_dbclose
int __sql_dbuse
int __sql_dbcmd
int __sql_dbsqlexec
int __sql_dbresults
int __sql_dbnumcols
int __sql_dbcolname
int __sql_dbnextrow
int __sql_dbdata
int __sql_dbdatlen
int __sql_dbcoltype
int __sql_dbconvert
int __sql_dbcancel
int __sql_dbcount
int __sql_dberrhandle
int __sql_dbmsghandle

int __sql_sqlserver_state

int sql_sqlserver_available():
	if (__sql_sqlserver_state != 0): return __sql_sqlserver_state == 1
	__sql_sqlserver_state = -1
	if (__word_size__ != 8 || __target_isa__ != 0 || os_windows()): return 0
	char* h = dl_open(c"libsybdb.so.5")
	if (h == 0): return 0
	__sql_dbinit = dl_trampoline_argv(dl_sym(h, c"dbinit"), 0, 1)
	if (__sql_dbinit == 0): return 0
	__sql_dblogin = dl_trampoline_argv(dl_sym(h, c"dblogin"), 0, 0)
	if (__sql_dblogin == 0): return 0
	__sql_dbloginfree = dl_trampoline_argv(dl_sym(h, c"dbloginfree"), 1, 0)
	if (__sql_dbloginfree == 0): return 0
	__sql_dbsetlname = dl_trampoline_argv(dl_sym(h, c"dbsetlname"), 3, 1)
	if (__sql_dbsetlname == 0): return 0
	__sql_dbsetlversion = dl_trampoline_argv(dl_sym(h, c"dbsetlversion"), 2, 1)
	if (__sql_dbsetlversion == 0): return 0
	__sql_tdsdbopen = dl_trampoline_argv(dl_sym(h, c"tdsdbopen"), 3, 0)
	if (__sql_tdsdbopen == 0): return 0
	__sql_dbclose = dl_trampoline_argv(dl_sym(h, c"dbclose"), 1, 0)
	if (__sql_dbclose == 0): return 0
	__sql_dbuse = dl_trampoline_argv(dl_sym(h, c"dbuse"), 2, 1)
	if (__sql_dbuse == 0): return 0
	__sql_dbcmd = dl_trampoline_argv(dl_sym(h, c"dbcmd"), 2, 1)
	if (__sql_dbcmd == 0): return 0
	__sql_dbsqlexec = dl_trampoline_argv(dl_sym(h, c"dbsqlexec"), 1, 1)
	if (__sql_dbsqlexec == 0): return 0
	__sql_dbresults = dl_trampoline_argv(dl_sym(h, c"dbresults"), 1, 1)
	if (__sql_dbresults == 0): return 0
	__sql_dbnumcols = dl_trampoline_argv(dl_sym(h, c"dbnumcols"), 1, 1)
	if (__sql_dbnumcols == 0): return 0
	__sql_dbcolname = dl_trampoline_argv(dl_sym(h, c"dbcolname"), 2, 0)
	if (__sql_dbcolname == 0): return 0
	__sql_dbnextrow = dl_trampoline_argv(dl_sym(h, c"dbnextrow"), 1, 1)
	if (__sql_dbnextrow == 0): return 0
	__sql_dbdata = dl_trampoline_argv(dl_sym(h, c"dbdata"), 2, 0)
	if (__sql_dbdata == 0): return 0
	__sql_dbdatlen = dl_trampoline_argv(dl_sym(h, c"dbdatlen"), 2, 1)
	if (__sql_dbdatlen == 0): return 0
	__sql_dbcoltype = dl_trampoline_argv(dl_sym(h, c"dbcoltype"), 2, 1)
	if (__sql_dbcoltype == 0): return 0
	__sql_dbconvert = dl_trampoline_argv(dl_sym(h, c"dbconvert"), 7, 1)
	if (__sql_dbconvert == 0): return 0
	__sql_dbcancel = dl_trampoline_argv(dl_sym(h, c"dbcancel"), 1, 1)
	if (__sql_dbcancel == 0): return 0
	__sql_dbcount = dl_trampoline_argv(dl_sym(h, c"dbcount"), 1, 1)
	if (__sql_dbcount == 0): return 0
	__sql_dberrhandle = dl_trampoline_argv(dl_sym(h, c"dberrhandle"), 1, 0)
	if (__sql_dberrhandle == 0): return 0
	__sql_dbmsghandle = dl_trampoline_argv(dl_sym(h, c"dbmsghandle"), 1, 0)
	if (__sql_dbmsghandle == 0): return 0
	__sql_sqlserver_state = 1
	return 1
