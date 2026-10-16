# Leak JSON is emitted only after a complete, stopped-process snapshot.
import libs.wgrind.leaks
import libs.wgrind.report


int wg_leak_write(int fd, char* text, int size):
	int pos = 0
	while (pos < size):
		int count = write(fd, text + pos, size - pos)
		if (count == -4): continue
		if (count <= 0): return 0
		pos = pos + count
	return 1


char* wg_leak_name(int kind):
	if (kind == WG_LEAK_REACHABLE): return c"still-reachable"
	if (kind == WG_LEAK_POSSIBLE): return c"possibly-lost"
	if (kind == WG_LEAK_DIRECT): return c"definitely-lost"
	return c"indirectly-lost"


int wg_leaks_found(wg_leaks* l):
	if (l.context.error || (l.phase != 2)): return -1
	return (l.blocks[WG_LEAK_POSSIBLE] + l.blocks[WG_LEAK_DIRECT] + l.blocks[WG_LEAK_INDIRECT]) != 0


int wg_leaks_report(wg_leaks* l, int fd):
	if (l.context.error || (l.phase != 2)): return 0
	char[512] buffer
	char* dst = &buffer[0]
	int n = wg_text(dst, 0, c"{\"kind\":\"leak-summary\"")
	for kind in range(1, 5):
		n = wg_text(dst, n, c",\"")
		n = wg_text(dst, n, wg_leak_name(kind))
		n = wg_text(dst, n, c"\":{\"blocks\":")
		n = wg_decimal(dst, n, l.blocks[kind])
		n = wg_text(dst, n, c",\"bytes\":")
		n = wg_decimal(dst, n, l.bytes[kind])
		n = wg_text(dst, n, c"}")
	n = wg_text(dst, n, c"}\n")
	return wg_leak_write(fd, dst, n)


int wg_leaks_report_details(wg_leaks* l, int fd):
	if (l.context.error || (l.phase != 2)): return 0
	char[512] buffer
	char* dst = &buffer[0]
	for i in range(l.count):
		wg_leak_node* node = &l.nodes[i]
		int n = wg_text(dst, 0, c"{\"kind\":\"leak\",\"classification\":\"")
		n = wg_text(dst, n, wg_leak_name(node.kind))
		n = wg_text(dst, n, c"\",\"address\":")
		n = wg_hex(dst, n, node.block.address)
		n = wg_text(dst, n, c",\"size\":")
		n = wg_decimal(dst, n, node.block.size)
		n = wg_text(dst, n, c",\"allocation\":")
		n = wg_hex(dst, n, node.block.allocated_at)
		n = wg_text(dst, n, c"}\n")
		if (wg_leak_write(fd, dst, n) == 0): return 0
	return 1
