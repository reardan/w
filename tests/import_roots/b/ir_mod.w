# --import-root fixture (tests/import_root_test.w, tools/import_root_e2e.w):
# the module 'ir_mod' exists in both roots a/ and b/, so the root named
# first on the command line supplies it.
char* ir_which():
	return c"b"
