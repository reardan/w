# bench inflate_corpus: libs/extras/compress/inflate.w over the DEFLATE
# round-trip corpus (tests/compress/deflate_corpus.txt), decompressed
# size times. Bit-at-a-time Huffman decoding through a context struct:
# pointer-field traffic rather than scalar locals. The checksum folds
# every decompressed byte and length. C twin: tests/bench/c/inflate_corpus.c,
# a port of inflate.w. Run from the repository root (the corpus path is
# relative).
# wbuild: target=bench_inflate_corpus tag=bench dep=wv2 data=tests/compress/deflate_corpus.txt
# wbuild: step="bin/wv2 tests/bench/inflate_corpus.w -o bin/bench_inflate_corpus"
# wbuild: step="bin/bench_inflate_corpus" expect_stdout="inflate_corpus size=6000 checksum=06fa0a40"
# wbuild: step="bin/wv2 x64 tests/bench/inflate_corpus.w -o bin/bench_inflate_corpus_64"
# wbuild: step="bin/bench_inflate_corpus_64" expect_stdout="inflate_corpus size=6000 checksum=06fa0a40"
# wbuild: target=bench_inflate_corpus_smoke_test tag=tests dep=wv2 data=tests/compress/deflate_corpus.txt
# wbuild: step="bin/wv2 tests/bench/inflate_corpus.w -o bin/bench_inflate_corpus_smoke"
# wbuild: step="bin/bench_inflate_corpus_smoke 2" expect_stdout="inflate_corpus size=2 checksum=c38e12f8"
# wbuild: step="bin/wv2 x64 tests/bench/inflate_corpus.w -o bin/bench_inflate_corpus_smoke_64"
# wbuild: step="bin/bench_inflate_corpus_smoke_64 2" expect_stdout="inflate_corpus size=2 checksum=c38e12f8"
import lib.lib
import lib.file
import lib.hex
import lib.result
import libs.extras.compress.inflate
import tests.bench.bench_lib


struct ic_entry:
	char* compressed
	int compressed_length


list[ic_entry*] ic_load(char* path):
	list[ic_entry*] entries = new list[ic_entry*]
	list[char*] lines = file_read_lines(path)
	if (cast(int, lines) == 0):
		print2(c"inflate_corpus: cannot read ")
		println2(path)
		exit(1)
	for char* line in lines:
		if ((line[0] == 0) || (line[0] == '#')): continue
		int bar = 0
		while ((line[bar] != 0) && (line[bar] != '|')): bar = bar + 1
		ic_entry* e = new ic_entry()
		e.compressed = hex_decode(line, bar, &e.compressed_length)
		if (e.compressed == 0):
			println2(c"inflate_corpus: bad corpus line")
			exit(1)
		entries.push(e)
	return entries


int main(int argc, char** argv):
	int reps = bench_size(argc, argv, 6000)
	list[ic_entry*] entries = ic_load(c"tests/compress/deflate_corpus.txt")
	int h = 0
	int r = 0
	while (r < reps):
		for ic_entry* e in entries:
			wresult[inflate_result*]* res = inflate(e.compressed, e.compressed_length, 0)
			if (result_is_error[inflate_result*](res)):
				println2(inflate_error_string(result_code[inflate_result*](res)))
				exit(1)
			inflate_result* out = result_value[inflate_result*](res)
			result_free[inflate_result*](res)
			int j = 0
			while (j < out.length):
				h = bench_fold(h, out.data[j] & 255)
				j = j + 1
			h = bench_fold(h, out.length)
			inflate_result_free(out)
		r = r + 1
	bench_report(c"inflate_corpus", reps, h)
	return 0
