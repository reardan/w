/* C twin of tests/bench/inflate_corpus.w (see bench.h): a port of
 * libs/extras/compress/inflate.w -- the same canonical-Huffman tables
 * (RFC 1951 §3.2.2 counts/symbols, decoded one bit at a time like
 * puff.c), the same context struct with a sticky status, the same
 * byte-at-a-time output buffer with the runtime's doubling growth -- over
 * the same corpus (tests/compress/deflate_corpus.txt, hex-decoded like
 * lib/hex.w). Run from the repository root. */
#include "bench.h"

#define INFLATE_OK 0
#define INFLATE_ERR_BAD_BTYPE 1
#define INFLATE_ERR_BAD_STORED_LEN 2
#define INFLATE_ERR_BAD_HUFFMAN 3
#define INFLATE_ERR_BAD_DISTANCE 4
#define INFLATE_ERR_TRUNCATED 5
#define INFLATE_ERR_TOO_LARGE 6

#define WH_MAXBITS 15

typedef struct {
	word* count;
	word* symbol;
} whuff;

typedef struct {
	word capacity;
	word length;
	unsigned char* data;
} sbuilder;

typedef struct {
	const unsigned char* in_data;
	word in_length;
	word byte_pos;
	word bit_pos;
	sbuilder* out;
	word max_output;
	word status;
	word base;
} ictx;

/* structures/string.w: a string_builder with __w_grow_capacity doubling. */
static sbuilder* sb_new(void) {
	sbuilder* s = malloc(sizeof(sbuilder));
	s->capacity = 16;
	s->length = 0;
	s->data = malloc(16);
	return s;
}

static void sb_reserve(sbuilder* s, word extra) {
	if (extra <= 0) return;
	word needed = s->length + extra + 1;
	if (needed > s->capacity) {
		word new_capacity = s->capacity * 2;
		if (new_capacity < needed) new_capacity = needed;
		s->data = realloc(s->data, (size_t)new_capacity);
		s->capacity = new_capacity;
	}
}

static void sb_append_char(sbuilder* s, int c) {
	sb_reserve(s, 1);
	s->data[s->length] = (unsigned char)c;
	s->length = s->length + 1;
}

static void sb_append_bytes(sbuilder* s, const unsigned char* data, word length) {
	sb_reserve(s, length);
	word i = 0;
	while (i < length) {
		s->data[s->length + i] = data[i];
		i = i + 1;
	}
	s->length = s->length + length;
}

static whuff* wh_new(word n) {
	whuff* h = malloc(sizeof(whuff));
	h->count = malloc((WH_MAXBITS + 1) * sizeof(word));
	h->symbol = malloc(n * sizeof(word));
	return h;
}

static void wh_free(whuff* h) {
	free(h->count);
	free(h->symbol);
	free(h);
}

static word wh_construct(whuff* h, word* lengths, word n) {
	word len = 0;
	while (len <= WH_MAXBITS) {
		h->count[len] = 0;
		len = len + 1;
	}
	word symbol = 0;
	while (symbol < n) {
		h->count[lengths[symbol]] = h->count[lengths[symbol]] + 1;
		symbol = symbol + 1;
	}
	if (h->count[0] == n) return 0;
	word left = 1;
	len = 1;
	while (len <= WH_MAXBITS) {
		left = left * 2 - h->count[len];
		if (left < 0) return left;
		len = len + 1;
	}
	word* offs = malloc((WH_MAXBITS + 1) * sizeof(word));
	offs[1] = 0;
	len = 1;
	while (len < WH_MAXBITS) {
		offs[len + 1] = offs[len] + h->count[len];
		len = len + 1;
	}
	symbol = 0;
	while (symbol < n) {
		if (lengths[symbol] != 0) {
			offs[lengths[symbol]] = offs[lengths[symbol]] + 1;
			h->symbol[offs[lengths[symbol]] - 1] = symbol;
		}
		symbol = symbol + 1;
	}
	free(offs);
	return left;
}

static word inf_get_bit(ictx* c) {
	if (c->status != 0) return 0;
	if (c->byte_pos >= c->in_length) {
		c->status = INFLATE_ERR_TRUNCATED;
		return 0;
	}
	word b = ((c->in_data[c->byte_pos] & 255) >> c->bit_pos) & 1;
	c->bit_pos = c->bit_pos + 1;
	if (c->bit_pos == 8) {
		c->bit_pos = 0;
		c->byte_pos = c->byte_pos + 1;
	}
	return b;
}

static word inf_get_bits(ictx* c, word n) {
	word v = 0;
	word i = 0;
	while (i < n) {
		v = v | (inf_get_bit(c) << i);
		i = i + 1;
	}
	return v;
}

static void inf_align_byte(ictx* c) {
	if (c->status != 0) return;
	if (c->bit_pos != 0) {
		c->bit_pos = 0;
		c->byte_pos = c->byte_pos + 1;
	}
}

static word wh_decode(ictx* c, whuff* h) {
	word code = 0;
	word first = 0;
	word index = 0;
	word len = 1;
	while (len <= WH_MAXBITS) {
		code = code | inf_get_bit(c);
		if (c->status != 0) return -1;
		word count = h->count[len];
		if (code - first < count) return h->symbol[index + (code - first)];
		index = index + count;
		first = first + count;
		first = first << 1;
		code = code << 1;
		len = len + 1;
	}
	return -1;
}

static word inf_decode_symbol(ictx* c, whuff* h) {
	word sym = wh_decode(c, h);
	if (c->status != 0) return -1;
	if (sym < 0) {
		c->status = INFLATE_ERR_BAD_HUFFMAN;
		return -1;
	}
	return sym;
}

static word wh_build(ictx* c, whuff* h, word* lengths, word n) {
	if (c->status != 0) return 0;
	word left = wh_construct(h, lengths, n);
	if (left != 0) {
		int single_short_code = n == h->count[0] + h->count[1];
		if (left < 0 || single_short_code == 0) {
			c->status = INFLATE_ERR_BAD_HUFFMAN;
			return 0;
		}
	}
	return 1;
}

static void inf_emit_byte(ictx* c, word b) {
	if (c->status != 0) return;
	if (c->max_output > 0 && c->out->length - c->base >= c->max_output) {
		c->status = INFLATE_ERR_TOO_LARGE;
		return;
	}
	sb_append_char(c->out, (int)b);
}

static void inf_copy_match(ictx* c, word length, word distance) {
	if (c->status != 0) return;
	if (distance <= 0 || distance > c->out->length) {
		c->status = INFLATE_ERR_BAD_DISTANCE;
		return;
	}
	word i = 0;
	while (i < length) {
		if (c->status != 0) return;
		word b = c->out->data[c->out->length - distance] & 255;
		inf_emit_byte(c, b);
		i = i + 1;
	}
}

static const word inf_length_base[29] = {3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258};
static const word inf_length_extra[29] = {0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0};
static const word inf_dist_base[30] = {1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577};
static const word inf_dist_extra[30] = {0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13};
static const word inf_clc_order[19] = {16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15};

static word inf_read_length(ictx* c, word sym) {
	word idx = sym - 257;
	word extra = inf_length_extra[idx];
	word extra_bits = 0;
	if (extra > 0) extra_bits = inf_get_bits(c, extra);
	return inf_length_base[idx] + extra_bits;
}

static word inf_read_distance(ictx* c, word dsym) {
	word extra = inf_dist_extra[dsym];
	word extra_bits = 0;
	if (extra > 0) extra_bits = inf_get_bits(c, extra);
	return inf_dist_base[dsym] + extra_bits;
}

static void inf_huffman_block(ictx* c, whuff* litlen, whuff* dist) {
	while (c->status == 0) {
		word sym = inf_decode_symbol(c, litlen);
		if (c->status != 0) return;
		if (sym < 256) inf_emit_byte(c, sym);
		else if (sym == 256) return;
		else if (sym <= 285) {
			word length = inf_read_length(c, sym);
			if (c->status != 0) return;
			word dsym = inf_decode_symbol(c, dist);
			if (c->status != 0) return;
			if (dsym > 29) {
				c->status = INFLATE_ERR_BAD_HUFFMAN;
				return;
			}
			word distance = inf_read_distance(c, dsym);
			if (c->status != 0) return;
			inf_copy_match(c, length, distance);
		} else {
			c->status = INFLATE_ERR_BAD_HUFFMAN;
			return;
		}
	}
}

static void inf_stored_block(ictx* c) {
	inf_align_byte(c);
	if (c->status != 0) return;
	if (c->byte_pos + 4 > c->in_length) {
		c->status = INFLATE_ERR_TRUNCATED;
		return;
	}
	word len = (c->in_data[c->byte_pos] & 255) | ((c->in_data[c->byte_pos + 1] & 255) << 8);
	word nlen = (c->in_data[c->byte_pos + 2] & 255) | ((c->in_data[c->byte_pos + 3] & 255) << 8);
	c->byte_pos = c->byte_pos + 4;
	if ((len ^ 65535) != nlen) {
		c->status = INFLATE_ERR_BAD_STORED_LEN;
		return;
	}
	if (c->byte_pos + len > c->in_length) {
		c->status = INFLATE_ERR_TRUNCATED;
		return;
	}
	if (c->max_output > 0 && c->out->length - c->base + len > c->max_output) {
		c->status = INFLATE_ERR_TOO_LARGE;
		return;
	}
	sb_append_bytes(c->out, &c->in_data[c->byte_pos], len);
	c->byte_pos = c->byte_pos + len;
}

static whuff* inf_fixed_litlen_cache;
static whuff* inf_fixed_dist_cache;

static whuff* inf_fixed_litlen_table(void) {
	if (inf_fixed_litlen_cache == 0) {
		word* lengths = malloc(288 * sizeof(word));
		word i = 0;
		while (i < 144) { lengths[i] = 8; i = i + 1; }
		while (i < 256) { lengths[i] = 9; i = i + 1; }
		while (i < 280) { lengths[i] = 7; i = i + 1; }
		while (i < 288) { lengths[i] = 8; i = i + 1; }
		whuff* h = wh_new(288);
		wh_construct(h, lengths, 288);
		free(lengths);
		inf_fixed_litlen_cache = h;
	}
	return inf_fixed_litlen_cache;
}

static whuff* inf_fixed_dist_table(void) {
	if (inf_fixed_dist_cache == 0) {
		word* lengths = malloc(32 * sizeof(word));
		word i = 0;
		while (i < 32) { lengths[i] = 5; i = i + 1; }
		whuff* h = wh_new(32);
		wh_construct(h, lengths, 32);
		free(lengths);
		inf_fixed_dist_cache = h;
	}
	return inf_fixed_dist_cache;
}

static void inf_fixed_block(ictx* c) {
	inf_huffman_block(c, inf_fixed_litlen_table(), inf_fixed_dist_table());
}

static void inf_dynamic_block(ictx* c) {
	word hlit = inf_get_bits(c, 5) + 257;
	word hdist = inf_get_bits(c, 5) + 1;
	word hclen = inf_get_bits(c, 4) + 4;
	if (c->status != 0) return;

	word* cl_lengths = malloc(19 * sizeof(word));
	memset(cl_lengths, 0, 19 * sizeof(word));
	word i = 0;
	while (i < hclen) {
		cl_lengths[inf_clc_order[i]] = inf_get_bits(c, 3);
		i = i + 1;
	}
	if (c->status != 0) {
		free(cl_lengths);
		return;
	}
	whuff* cl_huff = wh_new(19);
	word cl_ok = wh_build(c, cl_huff, cl_lengths, 19);
	free(cl_lengths);
	if (cl_ok == 0) {
		wh_free(cl_huff);
		return;
	}
	word total = hlit + hdist;
	word* lengths = malloc(total * sizeof(word));
	i = 0;
	word prev = 0;
	while (i < total) {
		if (c->status != 0) break;
		word sym = inf_decode_symbol(c, cl_huff);
		if (c->status != 0) break;
		if (sym < 16) {
			lengths[i] = sym;
			prev = sym;
			i = i + 1;
		} else if (sym == 16) {
			if (i == 0) {
				c->status = INFLATE_ERR_BAD_HUFFMAN;
				break;
			}
			word rep = inf_get_bits(c, 2) + 3;
			if (c->status != 0 || i + rep > total) {
				if (c->status == 0) c->status = INFLATE_ERR_BAD_HUFFMAN;
				break;
			}
			word k = 0;
			while (k < rep) { lengths[i] = prev; i = i + 1; k = k + 1; }
		} else if (sym == 17) {
			word rep = inf_get_bits(c, 3) + 3;
			if (c->status != 0 || i + rep > total) {
				if (c->status == 0) c->status = INFLATE_ERR_BAD_HUFFMAN;
				break;
			}
			word k = 0;
			while (k < rep) { lengths[i] = 0; i = i + 1; k = k + 1; }
			prev = 0;
		} else {
			word rep = inf_get_bits(c, 7) + 11;
			if (c->status != 0 || i + rep > total) {
				if (c->status == 0) c->status = INFLATE_ERR_BAD_HUFFMAN;
				break;
			}
			word k = 0;
			while (k < rep) { lengths[i] = 0; i = i + 1; k = k + 1; }
			prev = 0;
		}
	}
	wh_free(cl_huff);
	if (c->status != 0) {
		free(lengths);
		return;
	}
	whuff* litlen_huff = wh_new(hlit);
	word litlen_ok = wh_build(c, litlen_huff, lengths, hlit);
	whuff* dist_huff = wh_new(hdist);
	word dist_ok = 0;
	if (litlen_ok != 0) dist_ok = wh_build(c, dist_huff, &lengths[hlit], hdist);
	free(lengths);
	if (litlen_ok != 0 && dist_ok != 0) inf_huffman_block(c, litlen_huff, dist_huff);
	wh_free(litlen_huff);
	wh_free(dist_huff);
}

static void inf_run_blocks(ictx* c) {
	word bfinal = 0;
	while (bfinal == 0 && c->status == 0) {
		bfinal = inf_get_bits(c, 1);
		word btype = inf_get_bits(c, 2);
		if (c->status != 0) break;
		if (btype == 0) inf_stored_block(c);
		else if (btype == 1) inf_fixed_block(c);
		else if (btype == 2) inf_dynamic_block(c);
		else c->status = INFLATE_ERR_BAD_BTYPE;
	}
}

/* inflate(): the whole stream, unbounded output; returns the malloc'd
 * output and its length, or exits on a malformed stream. */
static unsigned char* inflate(const unsigned char* data, word length, word* out_len) {
	ictx* c = malloc(sizeof(ictx));
	c->in_data = data;
	c->in_length = length;
	c->byte_pos = 0;
	c->bit_pos = 0;
	c->out = sb_new();
	c->max_output = 0;
	c->status = 0;
	c->base = 0;
	inf_run_blocks(c);
	if (c->status != 0) {
		fprintf(stderr, "inflate_corpus: inflate failed with status %ld\n", (long)c->status);
		exit(1);
	}
	unsigned char* out = c->out->data;
	*out_len = c->out->length;
	free(c->out);
	free(c);
	return out;
}

typedef struct {
	unsigned char* compressed;
	word compressed_length;
} ic_entry;

static int hex_digit(int ch) {
	if (ch >= '0' && ch <= '9') return ch - '0';
	if (ch >= 'a' && ch <= 'f') return ch - 'a' + 10;
	if (ch >= 'A' && ch <= 'F') return ch - 'A' + 10;
	return -1;
}

static ic_entry* ic_load(const char* path, word* out_count) {
	FILE* f = fopen(path, "r");
	if (f == 0) {
		fprintf(stderr, "inflate_corpus: cannot read %s\n", path);
		exit(1);
	}
	word capacity = 16;
	word count = 0;
	ic_entry* entries = malloc(capacity * sizeof(ic_entry));
	char* line = malloc(65536);
	while (fgets(line, 65536, f) != 0) {
		if (line[0] == 0 || line[0] == '#' || line[0] == '\n') continue;
		word bar = 0;
		while (line[bar] != 0 && line[bar] != '|') bar = bar + 1;
		if (bar % 2 != 0) {
			fprintf(stderr, "inflate_corpus: bad corpus line\n");
			exit(1);
		}
		unsigned char* bytes = malloc(bar / 2 + 1);
		word i = 0;
		while (i < bar) {
			int hi = hex_digit(line[i]);
			int lo = hex_digit(line[i + 1]);
			if (hi < 0 || lo < 0) {
				fprintf(stderr, "inflate_corpus: bad corpus line\n");
				exit(1);
			}
			bytes[i / 2] = (unsigned char)((hi << 4) | lo);
			i = i + 2;
		}
		if (count == capacity) {
			capacity = capacity * 2;
			entries = realloc(entries, capacity * sizeof(ic_entry));
		}
		entries[count].compressed = bytes;
		entries[count].compressed_length = bar / 2;
		count = count + 1;
	}
	free(line);
	fclose(f);
	*out_count = count;
	return entries;
}

int main(int argc, char** argv) {
	word reps = bench_size(argc, argv, 6000);
	word count = 0;
	ic_entry* entries = ic_load("tests/compress/deflate_corpus.txt", &count);
	uint32_t h = 0;
	word r = 0;
	while (r < reps) {
		word e = 0;
		while (e < count) {
			word out_len = 0;
			unsigned char* out = inflate(entries[e].compressed, entries[e].compressed_length, &out_len);
			word j = 0;
			while (j < out_len) {
				h = bench_fold(h, out[j]);
				j = j + 1;
			}
			h = bench_fold(h, (uint32_t)out_len);
			free(out);
			e = e + 1;
		}
		r = r + 1;
	}
	bench_report("inflate_corpus", reps, h);
	return 0;
}
