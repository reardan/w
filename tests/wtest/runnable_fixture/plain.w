# Fixture root for bin/wtest's --runnable-here probes (never executed;
# selected through tests/wtest/manifest_runnable.json): statically
# linked, no GPU — runnable on every host, so the filter must keep it.
int main():
	return 0
