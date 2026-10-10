# Bounded content-decoding collector. Feeds are explicit chunks, never EOF;
# finish is the only completion signal. Existing whole-buffer codec registry
# supplies gzip/deflate (import extras.compress.codecs and register at startup).
# Owns its input and decoded output. No bytes are exposed before validation.
import libs.standard.web.codec
import structures.string
import libs.standard.web.http_client


const int content_decode_more = 0
const int content_decode_done = 1
const int content_decode_input_limit = 2
const int content_decode_output_limit = 3
const int content_decode_corrupt = 4
const int content_decode_unsupported = 5
const int content_decode_state_error = 6
const int content_decode_transport_error = 7


struct content_decoder:
	char* encoding
	string_builder* input
	int max_input
	int max_output
	int status
	char* output
	int output_length


# Limits must be positive: zero never silently selects unlimited decoding.
content_decoder* content_decoder_new(char* encoding, int max_input, int max_output):
	content_decoder* d = new content_decoder()
	if (encoding == 0): encoding = c"identity"
	d.encoding = strclone(encoding)
	d.input = string_new()
	d.max_input = max_input
	d.max_output = max_output
	d.status = content_decode_more
	d.output = 0
	d.output_length = 0
	if (max_input <= 0 || max_output <= 0): d.status = content_decode_state_error
	else if (codec_supported(encoding) == 0): d.status = content_decode_unsupported
	return d


int content_decoder_feed(content_decoder* d, char* data, int length):
	if (d.status != content_decode_more): return content_decode_state_error
	if (length < 0 || (data == 0 && length > 0)):
		d.status = content_decode_state_error
		return d.status
	if (length > d.max_input - d.input.length):
		d.status = content_decode_input_limit
		return d.status
	if (codec_is_identity(d.encoding) && length > d.max_output - d.input.length):
		d.status = content_decode_output_limit
		return d.status
	if (length > 0): string_append_bytes(d.input, data, length)
	return d.status


int content_decoder_finish(content_decoder* d):
	if (d.status != content_decode_more): return d.status
	int status = codec_decompress(d.encoding, d.input.data, d.input.length, d.max_output, &d.output, &d.output_length)
	if (status == codec_ok): d.status = content_decode_done
	else if (status == codec_err_too_large): d.status = content_decode_output_limit
	else if (status == codec_err_unsupported): d.status = content_decode_unsupported
	else: d.status = content_decode_corrupt
	string_clear(d.input)
	return d.status


void content_decoder_free(content_decoder* d):
	if (d == 0): return
	free(d.encoding)
	string_free(d.input)
	if (d.output != 0): free(d.output)
	free(d)


# Borrowed stream remains caller-owned; its response retains transport errors.
# Caller advertises gzip/deflate explicitly after registering codecs.
content_decoder* http_content_collect(http_stream* stream, int max_input, int max_output):
	content_decoder* d = content_decoder_new(http_response_header(stream.resp, c"content-encoding"), max_input, max_output)
	char* buf = cast(char*, malloc(8192))
	while (d.status == content_decode_more):
		int count = http_stream_read(stream, buf, 8192)
		if (count < 0): d.status = content_decode_transport_error
		else if (count == 0): content_decoder_finish(d)
		else: content_decoder_feed(d, buf, count)
	free(buf)
	return d
