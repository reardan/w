# Fixture root for bin/wtest's --runnable-here probes (never executed;
# selected through tests/wtest/manifest_runnable.json): the column-0
# 'import lib.cuda' marks a binary that opens the NVIDIA driver, so a
# run step for it needs a GPU on this host.
import lib.cuda

int main():
	return 0
