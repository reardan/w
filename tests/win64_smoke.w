# win64 runtime smoke test: exercises the kernel32-backed primitives and
# the language runtime pieces every W program leans on. Compiled with
# `w win64`, runs under Wine or Windows; prints "win64 smoke OK" when
# every check passes.
import lib.lib
import lib.generator


void check(char* label, int ok):
	if (ok == 0):
		print2(c"FAIL: ")
		println2(str_from_cstr(label))
		exit(1)


# Generators run on a private mmap'd (VirtualAlloc) stack switched by the
# shared gen_switch stub.
generator int count_up(int limit):
	int i = 0
	while (i < limit):
		yield i
		i = i + 1


int main(int argc, char** argv):
	# Heap: many allocations so brk growth (committed VirtualAlloc pages)
	# gets exercised past the first 64KB chunk.
	int i = 0
	while (i < 200):
		char* chunk = malloc(1000)
		chunk[999] = 42
		free(chunk)
		i = i + 1
	check(c"heap", 1)

	# Strings and formatting.
	char* joined = strjoin(c"con", c"cat")
	check(c"strjoin", strcmp(joined, c"concat") == 0)
	check(c"itoa", strcmp(itoa(-12345), c"-12345") == 0)

	# File round trip: create, write, close, reopen, seek, read back.
	# The scratch file lands in bin/ (gitignored) when run from the repo
	# root; CreateFileA accepts forward slashes on Wine and Windows.
	char* path = c"bin/win64_smoke_scratch.txt"
	int fd = create_file(path, 493)
	check(c"create_file", fd >= 0)
	check(c"write", write(fd, c"0123456789", 10) == 10)
	check(c"close", close(fd) == 0)
	fd = open(path, 0, 0)
	check(c"open", fd >= 0)
	check(c"seek", seek(fd, 4, 0) == 4)
	char* buf = malloc(16)
	int n = read(fd, buf, 16)
	buf[n] = 0
	check(c"read", n == 6)
	check(c"read contents", strcmp(buf, c"456789") == 0)
	close(fd)
	check(c"unlink", unlink(path) == 0)

	# Built-in containers (structures/hash_table.w, w_list.w).
	map[char*, int] ages = new map[char*, int]
	ages[c"ada"] = 36
	ages[c"alan"] = 41
	check(c"map", ages[c"ada"] + ages[c"alan"] == 77)
	list[int] numbers = new list[int]
	numbers.push(3)
	numbers.push(4)
	check(c"list", numbers[0] + numbers[1] == 7)

	# Generators (gen_switch + mmap'd stacks).
	int total = 0
	for int v in count_up(5):
		total = total + v
	check(c"generator", total == 10)

	# Time: the Unix epoch conversion should land after 2020-01-01 and
	# the monotonic clock should produce a plausible timespec.
	int now = linux_time(0)
	check(c"time", now > 1577836800)
	int ts0
	int ts1
	int* ts = &ts0
	check(c"clock_gettime", clock_gettime(1, ts) == 0)
	check(c"clock ns range", (ts[1] >= 0) & (ts[1] < 1000000000))

	println(c"win64 smoke OK")
	return 0
