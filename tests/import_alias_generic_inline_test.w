# Generic bodies instantiate at the end-of-file drain with the root file's
# import aliases hidden unless the body is defined in the root file itself:
# an inlined parameter must not read as an unqualified use of an alias
# (it used to warn, and the warning broke the inline re-parse).
# wbuild: step="bin/wv2 --strict --inline tests/import_alias_generic_inline_fixture.w -o bin/import_alias_generic_inline"
# wbuild: step="bin/import_alias_generic_inline"
# wbuild: step="bin/wv2 --strict tests/import_alias_generic_inline_fixture.w -o bin/import_alias_generic_plain"
# wbuild: step="bin/import_alias_generic_plain"
# wbuild: step="bin/wv2 x64 --strict --inline tests/import_alias_generic_inline_fixture.w -o bin/import_alias_generic_inline64"
# wbuild: step="bin/import_alias_generic_inline64"
int main():
	return 0
