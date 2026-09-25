# No '= help' line when no in-scope name is within the suggester's edit
# budget (#377): a wild guess would be worse than no hint.
# expect_fail
# expect_stderr: error: Cannot find symbol: 'qqqzzzx'
# reject_stderr: help:
import lib.lib


int main():
	int counter = 3
	return qqqzzzx + counter
