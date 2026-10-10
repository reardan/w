# Build targets are owned by tests/wsh_test.w (root sources are not scanned).
# Standalone shell frontend; startup, parsing and execution are shared with REPL.
import repl.frontend


int main(int argc, int argv):
	return repl_main(argc, argv, 1)
