# Fixture root for bin/wtest's --runnable-here soname probe (never
# executed; selected through tests/wtest/manifest_runnable.json): the
# column-0 c_lib names a library NO host has, so the target is dropped
# on every machine — either the word size's ELF interpreter is missing
# (its reason) or the loader exists and the soname probe reports this
# name. The fictional-soname trick mirrors manifest_unavailable.json's
# fictional tools/mac/ path: a deterministic drop without depending on
# what the host happens to have installed.
c_lib "libwtest_no_such_lib.so.9"

extern int wtest_no_such_symbol()

int main():
	return wtest_no_such_symbol()
