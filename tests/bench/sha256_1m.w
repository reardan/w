# bench sha256_1m: lib/sha256.w over size MB of deterministic data. The
# compression loop (sha256_block_w) is the hottest function of the
# compiler's own self-compile (docs/projects/register_allocation_pgo.md
# §1.2): 20 word-sized locals and no calls. The checksum is the full
# digest. C twin: tests/bench/c/sha256_1m.c, a port of lib/sha256.w.
# wbuild: target=bench_sha256_1m tag=bench dep=wv2
# wbuild: step="bin/wv2 tests/bench/sha256_1m.w -o bin/bench_sha256_1m"
# wbuild: step="bin/bench_sha256_1m" expect_stdout="sha256_1m size=16 checksum=88f95233e8233b09972269d14cda6d1e8cdd4a13906b384d63862568d6e1015c"
# wbuild: step="bin/wv2 x64 tests/bench/sha256_1m.w -o bin/bench_sha256_1m_64"
# wbuild: step="bin/bench_sha256_1m_64" expect_stdout="sha256_1m size=16 checksum=88f95233e8233b09972269d14cda6d1e8cdd4a13906b384d63862568d6e1015c"
# wbuild: target=bench_sha256_1m_smoke_test tag=tests dep=wv2
# wbuild: step="bin/wv2 tests/bench/sha256_1m.w -o bin/bench_sha256_1m_smoke"
# wbuild: step="bin/bench_sha256_1m_smoke 1" expect_stdout="sha256_1m size=1 checksum=bd569ddb2b77ae57402aeac36165538f5167cc727df4c73b8364613a7dc4b028"
# wbuild: step="bin/wv2 x64 tests/bench/sha256_1m.w -o bin/bench_sha256_1m_smoke_64"
# wbuild: step="bin/bench_sha256_1m_smoke_64 1" expect_stdout="sha256_1m size=1 checksum=bd569ddb2b77ae57402aeac36165538f5167cc727df4c73b8364613a7dc4b028"
import lib.lib
import lib.sha256
import tests.bench.bench_lib


int main(int argc, char** argv):
	int mb = bench_size(argc, argv, 16)
	int len = mb * 1048576
	char* data = cast(char*, malloc(len))
	int state = 123456789
	int i = 0
	while (i < len):
		data[i] = bench_rand(&state) & 255
		i = i + 1
	char* digest = cast(char*, malloc(32))
	sha256(data, len, digest)
	char* digits = c"0123456789abcdef"
	char* hex = cast(char*, malloc(65))
	i = 0
	while (i < 32):
		int b = digest[i] & 255
		hex[i * 2] = digits[(b >> 4) & 15]
		hex[i * 2 + 1] = digits[b & 15]
		i = i + 1
	hex[64] = 0
	print(c"sha256_1m size=")
	print(itoa(mb))
	print(c" checksum=")
	println(hex)
	return 0
