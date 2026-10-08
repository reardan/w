# Internal Linux x64 bindings. Handles and trampolines live for the process.
import libs.standard.sql.common

int __sql_OCIEnvNlsCreate
int __sql_OCIHandleAlloc
int __sql_OCIHandleFree
int __sql_OCILogon2
int __sql_OCILogoff
int __sql_OCIErrorGet
int __sql_OCIStmtPrepare2
int __sql_OCIStmtRelease
int __sql_OCIStmtExecute
int __sql_OCIAttrGet
int __sql_OCIParamGet
int __sql_OCIDescriptorFree
int __sql_OCIDefineByPos
int __sql_OCIStmtFetch2
int __sql_OCIBindByPos
int __sql_OCITransCommit
int __sql_OCITransRollback

int __sql_oracle_state

int sql_oracle_available():
	if (__sql_oracle_state != 0): return __sql_oracle_state == 1
	__sql_oracle_state = -1
	if (__word_size__ != 8 || __target_isa__ != 0 || os_windows()): return 0
	char* h = dl_open(c"libclntsh.so")
	if (h == 0): h = dl_open(c"libclntsh.so.19.1")
	if (h == 0): return 0
	__sql_OCIEnvNlsCreate = dl_trampoline_argv(dl_sym(h, c"OCIEnvNlsCreate"), 10, 1)
	if (__sql_OCIEnvNlsCreate == 0): return 0
	__sql_OCIHandleAlloc = dl_trampoline_argv(dl_sym(h, c"OCIHandleAlloc"), 5, 1)
	if (__sql_OCIHandleAlloc == 0): return 0
	__sql_OCIHandleFree = dl_trampoline_argv(dl_sym(h, c"OCIHandleFree"), 2, 1)
	if (__sql_OCIHandleFree == 0): return 0
	__sql_OCILogon2 = dl_trampoline_argv(dl_sym(h, c"OCILogon2"), 10, 1)
	if (__sql_OCILogon2 == 0): return 0
	__sql_OCILogoff = dl_trampoline_argv(dl_sym(h, c"OCILogoff"), 2, 1)
	if (__sql_OCILogoff == 0): return 0
	__sql_OCIErrorGet = dl_trampoline_argv(dl_sym(h, c"OCIErrorGet"), 7, 1)
	if (__sql_OCIErrorGet == 0): return 0
	__sql_OCIStmtPrepare2 = dl_trampoline_argv(dl_sym(h, c"OCIStmtPrepare2"), 9, 1)
	if (__sql_OCIStmtPrepare2 == 0): return 0
	__sql_OCIStmtRelease = dl_trampoline_argv(dl_sym(h, c"OCIStmtRelease"), 5, 1)
	if (__sql_OCIStmtRelease == 0): return 0
	__sql_OCIStmtExecute = dl_trampoline_argv(dl_sym(h, c"OCIStmtExecute"), 8, 1)
	if (__sql_OCIStmtExecute == 0): return 0
	__sql_OCIAttrGet = dl_trampoline_argv(dl_sym(h, c"OCIAttrGet"), 6, 1)
	if (__sql_OCIAttrGet == 0): return 0
	__sql_OCIParamGet = dl_trampoline_argv(dl_sym(h, c"OCIParamGet"), 5, 1)
	if (__sql_OCIParamGet == 0): return 0
	__sql_OCIDescriptorFree = dl_trampoline_argv(dl_sym(h, c"OCIDescriptorFree"), 2, 1)
	if (__sql_OCIDescriptorFree == 0): return 0
	__sql_OCIDefineByPos = dl_trampoline_argv(dl_sym(h, c"OCIDefineByPos"), 11, 1)
	if (__sql_OCIDefineByPos == 0): return 0
	__sql_OCIStmtFetch2 = dl_trampoline_argv(dl_sym(h, c"OCIStmtFetch2"), 6, 1)
	if (__sql_OCIStmtFetch2 == 0): return 0
	__sql_OCIBindByPos = dl_trampoline_argv(dl_sym(h, c"OCIBindByPos"), 13, 1)
	if (__sql_OCIBindByPos == 0): return 0
	__sql_OCITransCommit = dl_trampoline_argv(dl_sym(h, c"OCITransCommit"), 3, 1)
	if (__sql_OCITransCommit == 0): return 0
	__sql_OCITransRollback = dl_trampoline_argv(dl_sym(h, c"OCITransRollback"), 3, 1)
	if (__sql_OCITransRollback == 0): return 0
	__sql_oracle_state = 1
	return 1
