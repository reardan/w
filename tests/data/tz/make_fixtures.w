# wbuild: binary=tz_make_fixtures
# Hand-made TZif fixtures. --check validates without rewriting snapshots.
import tools.host_tools

void tz_fixture(char* name, int version, int offset, int dst, char* abbreviation, char* footer, int check):
	string_builder* out = string_new()
	for i in range(2):
		string_append(out, c"TZif")
		string_append_char(out, version)
		for j in range(15 + 16): string_append_char(out, 0)
		char[4] number
		store_be32(&number[0], 1)
		string_append_bytes(out, &number[0], 4)
		store_be32(&number[0], strlen(abbreviation) + 1)
		string_append_bytes(out, &number[0], 4)
		store_be32(&number[0], offset)
		string_append_bytes(out, &number[0], 4)
		string_append_char(out, dst)
		string_append_char(out, 0)
		string_append_bytes(out, abbreviation, strlen(abbreviation) + 1)
	string_append_char(out, 10)
	string_append(out, footer)
	string_append_char(out, 10)
	ht_generated(path_join(c"tests/data/tz/Test", name), out, check)

int main(int argc, int argv):
	args_init(argc, argv)
	ht_require(argc == 1 || (argc == 2 && strcmp(args_get(1), c"--check") == 0), c"usage: tz_make_fixtures [--check]")
	string_builder* data = ht_read(c"tests/data/tz/America/New_York")
	ht_require(data.length >= 44, c"truncated New York TZif")
	int size = 44 + load_be32(data.data + 32) * 5 + load_be32(data.data + 36) * 6 + load_be32(data.data + 40) + load_be32(data.data + 28) * 8 + load_be32(data.data + 24) + load_be32(data.data + 20)
	ht_require(size <= data.length && size >= 44, c"invalid New York TZif header")
	data.data[4] = 0
	data.length = size
	ht_generated(c"tests/data/tz/Test/NewYorkV1", data, argc == 2)
	tz_fixture(c"Julian", '2', -10800, 0, c"AAA", c"AAA3BBB,J60/0,300/1:30", argc == 2)
	tz_fixture(c"NegativeDST", '2', 3600, 0, c"IST", c"IST-1GMT0,M10.5.0,M3.5.0/1", argc == 2)
	tz_fixture(c"AllYearDST", '3', -14400, 1, c"EDT", c"EST5EDT,0/0,J365/25", argc == 2)
	return 0
