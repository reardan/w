# wbuild: x64
/*
Corpus round-trip fixtures for libs/extras/compress/inflate.w
(docs/projects/compress.md §8: "corpus round-trip fixtures, text-
committed, not binary"). tests/compress/deflate_corpus.txt holds lines
of `<hex compressed bytes>|<hex expected decompressed bytes>`, generated
once with a real python3 zlib at fixture-authoring time (not a build-time
dependency -- the fixture is just the resulting bytes) and read here at
test run time, mirroring tests/asm/corpus_*.txt's own hex-per-line
format and libs/asm/hexutil.w's asm_corpus_load shape (a lighter-weight
version of the same idea: two hex fields instead of hex+assembly-text).

Covers block types and content shapes the hand-crafted fixtures in
compress_inflate_test.w do not: a full 0-255 byte-value sweep, a long
single-byte run (exercises repeated maximal-length matches), repeated
English-like text (a bigger dynamic-Huffman block than the small-
alphabet unit fixture), low-compressibility pseudo-random bytes (mostly-
literal blocks), a single-byte input, and a fixed-Huffman block over
varied text.
*/
import lib.testing
import lib.file
import lib.result
import libs.standard.crypto.base64
import libs.extras.compress.inflate


struct compress_corpus_entry:
	char* compressed
	int compressed_length
	char* plain
	int plain_length
	int line


list[compress_corpus_entry] compress_corpus_load(char* path):
	list[compress_corpus_entry] entries = new list[compress_corpus_entry]
	list[char*] lines = file_read_lines(path)
	asserts(c"missing corpus file", cast(int, lines) != 0)
	int index = 0
	while (index < lines.length):
		char* line = lines[index]
		index = index + 1
		if (line[0] == 0):
			continue
		if (line[0] == '#'):
			continue
		int bar = 0
		int line_len = strlen(line)
		while ((bar < line_len) && (line[bar] != '|')):
			bar = bar + 1
		asserts(c"bad corpus line: missing '|'", bar < line_len)
		int complen = 0
		char* compressed = hex_decode(line, bar, &complen)
		asserts(c"bad corpus line: invalid compressed hex", compressed != 0)
		int plainlen = 0
		char* plain = hex_decode(line + bar + 1, line_len - bar - 1, &plainlen)
		asserts(c"bad corpus line: invalid plaintext hex", plain != 0)
		compress_corpus_entry entry
		entry.compressed = compressed
		entry.compressed_length = complen
		entry.plain = plain
		entry.plain_length = plainlen
		entry.line = index
		entries.push(entry)
	return entries


void test_deflate_corpus_roundtrip():
	list[compress_corpus_entry] entries = compress_corpus_load(c"tests/compress/deflate_corpus.txt")
	asserts(c"empty deflate corpus", entries.length >= 6)
	int i = 0
	while (i < entries.length):
		compress_corpus_entry entry = entries[i]
		i = i + 1
		wresult[inflate_result*]* r = inflate(entry.compressed, entry.compressed_length, 0)
		if (result_is_error[inflate_result*](r)):
			print2(c"corpus line ")
			print2(itoa(entry.line))
			print2(c": inflate failed: ")
			println2(inflate_error_string(result_code[inflate_result*](r)))
			exit(1)
		inflate_result* out = result_value[inflate_result*](r)
		result_free[inflate_result*](r)
		if (out.length != entry.plain_length):
			print2(c"corpus line ")
			print2(itoa(entry.line))
			println2(c": length mismatch")
			exit(1)
		int j = 0
		while (j < entry.plain_length):
			if ((out.data[j] & 255) != (entry.plain[j] & 255)):
				print2(c"corpus line ")
				print2(itoa(entry.line))
				print2(c": byte mismatch at offset ")
				println2(itoa(j))
				exit(1)
			j = j + 1
		inflate_result_free(out)
