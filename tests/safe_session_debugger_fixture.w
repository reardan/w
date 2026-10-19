# Debuggee for tests/safe_session_debugger_test.w: checked owners and
# borrows at 'debugger' stops and a conditional breakpoint (#713).
struct box:
	int value


int consume(own box* b):
	int v = b.value
	debugger
	return v


int step(ref box* b, int i):
	int r = b.value + i
	return r


int main():
	own box* p = new box
	p.value = 41
	int plain = 7
	ref box* r = p
	debugger
	int got = r.value + plain
	int sum = 0
	for i in range(4):
		sum = sum + step(p, i)
	debugger
	int total = consume(p)
	debugger
	return total + got + sum - 41 - 48 - 170
