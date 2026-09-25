# Byte run-length codec for 8-bit coverage bitmaps (issue #338: the
# encoder was tools/generate_ui_atlas.w's, the decoder graphics/ui/font.w's
# baked-mask expansion). The stream is 2-byte tokens: tag 0 = a run of
# `count` zero bytes, tag 1 = a run of `count` 255 bytes, tag 2 = `count`
# literal bytes following the token. Counts are 1..255.
import lib.lib


# Zero/full runs of 3+ become 2-byte tokens; everything else joins a
# literal run (tag 2, count, raw bytes).
char* rle_encode(char* pixels, int total, int* out_length):
	char* stream = malloc(total * 2 + 16)
	int pos = 0
	int i = 0
	while (i < total):
		int v = pixels[i] & 255
		int run = 1
		while ((i + run < total) && ((pixels[i + run] & 255) == v) && (run < 255)):
			run = run + 1
		if (((v == 0) || (v == 255)) && (run >= 3)):
			if (v == 0):
				stream[pos] = 0
			else:
				stream[pos] = 1
			stream[pos + 1] = run
			pos = pos + 2
			i = i + run
		else:
			# Literal run: until a 3+ run of 0/255 starts or 255 bytes.
			int start = i
			int n = 0
			int stop = 0
			while ((i < total) && (n < 255) && (stop == 0)):
				int b = pixels[i] & 255
				if ((b == 0) || (b == 255)):
					int ahead = 1
					while ((i + ahead < total) && ((pixels[i + ahead] & 255) == b) && (ahead < 3)):
						ahead = ahead + 1
					if (ahead >= 3):
						stop = 1
				if (stop == 0):
					i = i + 1
					n = n + 1
			stream[pos] = 2
			stream[pos + 1] = n
			pos = pos + 2
			int k = 0
			while (k < n):
				stream[pos + k] = pixels[start + k]
				k = k + 1
			pos = pos + n
	out_length[0] = pos
	return stream


# Expands length stream bytes into out (total bytes); pixels past the
# end of the stream, and any a truncated run would leave, are zero.
# Runs that would overflow out are clipped. Returns out.
char* rle_decode(char* stream, int length, char* out, int total):
	int pos = 0
	int n = 0
	while ((pos + 1 < length) && (n < total)):
		int tag = stream[pos] & 255
		int count = stream[pos + 1] & 255
		pos = pos + 2
		if (n + count > total):
			count = total - n
		int k = 0
		if (tag == 0):
			while (k < count):
				out[n + k] = 0
				k = k + 1
		else if (tag == 1):
			while (k < count):
				out[n + k] = 255
				k = k + 1
		else:
			while (k < count):
				out[n + k] = stream[pos + k]
				k = k + 1
			pos = pos + count
		n = n + count
	while (n < total):
		out[n] = 0
		n = n + 1
	return out
