# Fixture root for bin/wtest's --runnable-here probes (never executed;
# selected through tests/wtest/manifest_runnable.json): the column-0
# c_lib directive marks the produced binary dynamically linked, so a
# run step for it needs the target word size's ELF interpreter.
c_lib "libc.so.6"

extern int getppid()

int main():
	return getppid()
