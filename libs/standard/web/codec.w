# Content-coding registry for the pure-W web stack (issue #436,
# "Protocols"): a process-wide table of named whole-buffer codecs
# ("gzip", "deflate", ...) that protocol modules under libs/standard look
# up by name instead of importing an implementation.
#
# Why a registry: the DEFLATE family lives in libs/extras/compress, and
# no libs/standard module depends on libs/extras (docs/projects/
# http2_grpc.md, "gRPC"). Protocols that negotiate a coding also need
# to ADVERTISE exactly the codings this process can decode (gRPC's
# grpc-accept-encoding, HTTP Accept-Encoding), so the registry is the
# single source of truth for both. The implementation side registers
# itself once; libs/extras/compress/codecs.w does that for gzip and
# deflate:
#
#	import libs.extras.compress.codecs
#	compress_codecs_register()
#
# Until something is registered only "identity" is supported, which is
# a complete, spec-compliant configuration for every consumer (the peer
# is told we accept nothing else). The same seam hooks up the SHA-1
# digest for WebSocket (sha2.w's whash_register, websocket.w's
# ws_use_sha1) -- there the reason is the libs/x/unsafe quarantine, here
# it is optional layering.
#
# Callbacks work on whole buffers (every consumer frames messages
# first):
#   compress:   fn(char* in, int len, char** out, int* out_len) -> int
#   decompress: fn(char* in, int len, int max, char** out, int* out_len) -> int
# returning codec_ok(), codec_err_corrupt() or codec_err_too_large().
# *out is malloc'd (with one extra NUL byte past *out_len) on success
# and 0 otherwise. decompress must stop and fail with
# codec_err_too_large() as soon as the output would exceed max bytes
# (max <= 0 means unbounded -- only for trusted input); that cap is what
# keeps a small compressed message from expanding without bound.
#
# Public API:
#   void codec_register(char* name, codec_compress_fn* c, codec_decompress_fn* d)
#                                  replaces an existing entry of that name
#   int  codec_supported(char* name)      1 for "identity" or a registered name
#   int  codec_is_identity(char* name)    1 for 0, "" or "identity"
#   char* codec_accept_list()             malloc'd "gzip,deflate" (registration
#                                         order), "" when nothing is registered
#   int  codec_list_contains(char* list, char* name)
#                                  1 when a comma-separated header value
#                                  (grpc-accept-encoding, Accept-Encoding)
#                                  names the coding; ";q=" parameters and
#                                  whitespace are ignored, "identity" is
#                                  always accepted
#   int  codec_compress(char* name, char* in, int len, char** out, int* out_len)
#   int  codec_decompress(char* name, char* in, int len, int max, char** out, int* out_len)
#                                  identity copies (and enforces max); an
#                                  unregistered name is codec_err_unsupported()
#   char* codec_error_string(int code)
#
# Names compare ASCII case-insensitively (content-coding tokens are
# case-insensitive, RFC 9110 section 8.4.1).
import lib.lib
import lib.mem


const int codec_ok = 0
const int codec_err_corrupt = 1
const int codec_err_too_large = 2
const int codec_err_unsupported = 3


char* codec_error_string(int code):
	if (code == codec_ok):
		return c"ok"
	if (code == codec_err_corrupt):
		return c"corrupt compressed data"
	if (code == codec_err_too_large):
		return c"decompressed size exceeds the limit"
	if (code == codec_err_unsupported):
		return c"unsupported encoding"
	return c"unknown codec error"


type codec_compress_fn = fn(char*, int, char**, int*) -> int
type codec_decompress_fn = fn(char*, int, int, char**, int*) -> int


struct codec_entry:
	char* name
	codec_compress_fn* compress
	codec_decompress_fn* decompress
	codec_entry* next


codec_entry* codec_registry


int codec_lower(int ch):
	if ((ch >= 'A') && (ch <= 'Z')):
		return ch + 32
	return ch


# Compares a[0..alen) with the NUL-terminated b, ASCII case-insensitive.
int codec_name_eq(char* a, int alen, char* b):
	for i in range(alen):
		if ((b[i] == 0) || (codec_lower(a[i] & 255) != codec_lower(b[i] & 255))):
			return 0
	return b[alen] == 0


int codec_is_identity(char* name):
	if ((name == 0) || (name[0] == 0)):
		return 1
	return codec_name_eq(name, strlen(name), c"identity")


codec_entry* codec_find(char* name):
	if (name == 0):
		return 0
	int n = strlen(name)
	codec_entry* e = codec_registry
	while (e != 0):
		if (codec_name_eq(name, n, e.name) != 0):
			return e
		e = e.next
	return 0


# Appends so codec_accept_list keeps registration order.
void codec_register(char* name, codec_compress_fn* compress, codec_decompress_fn* decompress):
	codec_entry* e = codec_find(name)
	if (e == 0):
		e = new codec_entry
		e.name = strclone(name)
		e.next = 0
		if (codec_registry == 0):
			codec_registry = e
		else:
			codec_entry* tail = codec_registry
			while (tail.next != 0):
				tail = tail.next
			tail.next = e
	e.compress = compress
	e.decompress = decompress


int codec_supported(char* name):
	if (codec_is_identity(name) != 0):
		return 1
	return codec_find(name) != 0


char* codec_accept_list():
	int n = 1
	codec_entry* e = codec_registry
	while (e != 0):
		n = n + strlen(e.name) + 1
		e = e.next
	char* out = malloc(n)
	int pos = 0
	e = codec_registry
	while (e != 0):
		if (pos > 0):
			out[pos] = ','
			pos = pos + 1
		int k = 0
		while (e.name[k] != 0):
			out[pos] = e.name[k]
			pos = pos + 1
			k = k + 1
		e = e.next
	out[pos] = 0
	return out


int codec_is_space(int ch):
	return (ch == ' ') || (ch == 9)


int codec_list_contains(char* hdr, char* name):
	if (codec_is_identity(name) != 0):
		return 1
	if (hdr == 0):
		return 0
	int i = 0
	while (hdr[i] != 0):
		while (codec_is_space(hdr[i] & 255) || (hdr[i] == ',')):
			i = i + 1
		int start = i
		while ((hdr[i] != 0) && (hdr[i] != ',') && (hdr[i] != ';') && (codec_is_space(hdr[i] & 255) == 0)):
			i = i + 1
		if ((i > start) && (codec_name_eq(hdr + start, i - start, name) != 0)):
			return 1
		while ((hdr[i] != 0) && (hdr[i] != ',')):
			i = i + 1
	return 0


int codec_compress(char* name, char* in, int len, char** out, int* out_len):
	*out = 0
	*out_len = 0
	if (codec_is_identity(name) != 0):
		*out = mem_dup(in, len)
		*out_len = len
		return codec_ok
	codec_entry* e = codec_find(name)
	if (e == 0):
		return codec_err_unsupported
	return e.compress(in, len, out, out_len)


int codec_decompress(char* name, char* in, int len, int max, char** out, int* out_len):
	*out = 0
	*out_len = 0
	if (codec_is_identity(name) != 0):
		if ((max > 0) && (len > max)):
			return codec_err_too_large
		*out = mem_dup(in, len)
		*out_len = len
		return codec_ok
	codec_entry* e = codec_find(name)
	if (e == 0):
		return codec_err_unsupported
	return e.decompress(in, len, max, out, out_len)
