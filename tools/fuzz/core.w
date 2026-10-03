# Shared deterministic generation and artifact helpers for wfuzz.
import lib.lib
import lib.file
import lib.process
import lib.sha256
import structures.json
import structures.string
import libs.asm.hexutil
import libs.standard.distributed.prng


char* wf_arg(int argv, int index):
	char** p = argv + index * __word_size__
	return *p


int wf_equal(char* a, char* b):
	return strcmp(a, b) == 0


void wf_require(int ok, char* message):
	if (ok == 0):
		print2(c"wfuzz: ")
		println2(message)
		exit(2)


char* wf_read(char* path):
	char* data = file_read_text(path)
	wf_require(data != 0, c"cannot read input")
	return data


void wf_write(char* path, char* data):
	wf_require(file_write_text(path, data), c"cannot write artifact")


char* wf_hash(char* data, int length):
	char* digest = malloc(32)
	sha256(data, length, digest)
	char* out = asm_hex_encode(digest, 32)
	free(digest)
	return out


char* wf_file_hash(char* path):
	wstream* in = stream_open_read(path)
	wf_require(in != 0, c"cannot hash executable")
	string_builder* b = string_new()
	stream_read_all(in, b)
	stream_close(in)
	char* out = wf_hash(b.data, b.length)
	string_free(b)
	return out


void wf_json_write(char* path, json_value* value):
	char* text = json_stringify(value)
	wf_write(path, text)
	free(text)


char* wf_gets(json_value* value, char* key):
	json_value* field = json_object_get(value, key)
	wf_require(field != 0, c"missing artifact field")
	wf_require(field.type == json_type_string(), c"invalid artifact string")
	return field.string_value


int wf_geti(json_value* value, char* key):
	json_value* field = json_object_get(value, key)
	wf_require(field != 0, c"missing artifact field")
	wf_require(field.type == json_type_int(), c"invalid artifact integer")
	return field.int_value


# Case IDs choose independent streams: sharding never consumes/skips draws.
prng* wf_rng(int seed, int case_id):
	prng* r = prng_new(seed)
	int i = 0
	# Mix the ID a byte at a time, avoiding host-width multiplication.
	while (i < 4):
		r.state = (r.state ^ ((shr(case_id, i * 8) & 255) + 1)) & prng_mask32()
		prng_next(r)
		i = i + 1
	return r


int wf_known(char* target):
	return wf_equal(target, c"compiler") || wf_equal(target, c"program") || wf_equal(target, c"asm-x86") || wf_equal(target, c"asm-x64") || wf_equal(target, c"asm-arm64") || wf_equal(target, c"asm-text-x86") || wf_equal(target, c"asm-text-x64") || wf_equal(target, c"asm-text-arm64") || wf_equal(target, c"json") || wf_equal(target, c"protobuf") || wf_equal(target, c"compress") || wf_equal(target, c"containers") || wf_equal(target, c"http") || wf_equal(target, c"asn1") || wf_equal(target, c"hpack") || wf_equal(target, c"websocket")


int wf_text_target(char* target):
	return wf_equal(target, c"compiler") || wf_equal(target, c"json") || wf_equal(target, c"http") || wf_equal(target, c"asm-text-x86") || wf_equal(target, c"asm-text-x64") || wf_equal(target, c"asm-text-arm64")


char* wf_seed_text(char* target, int which):
	if (wf_equal(target, c"compiler")):
		if (which == 0):
			return c"int main():\n\tint x = 3\n\tif (x < 9):\n\t\treturn x + 1\n\treturn 0\n"
		if (which == 1):
			return c"struct Pair:\n\tint x\n\tint y\nint main():\n\tPair p\n\tp.x = 7\n\treturn p.x\n"
		return c"int main():\n\tlist[int] xs = new list[int]\n\txs.push(4)\n\treturn xs[0]\n"
	if (wf_equal(target, c"json")):
		return c"{\"items\":[0,-1,true,null,\"hello\\u0020world\"],\"nested\":{\"x\":12}}"
	if (wf_equal(target, c"http")):
		return c"GET /a?b=1 HTTP/1.1"
	if (wf_equal(target, c"asm-text-arm64")):
		return c"ldr x1,[x2,#8]"
	return c"mov eax,[ebx+ecx*4+127]"


char* wf_generate(char* target, int seed, int case_id, char* corpus):
	prng* r = wf_rng(seed, case_id)
	string_builder* b = string_new()
	if (wf_text_target(target)):
		char* base = wf_seed_text(target, case_id % 3)
		if (corpus != 0):
			base = corpus
		string_append(b, base)
		int mutations = prng_range(r, 9)
		int j = 0
		while (j < mutations):
			int pos = prng_range(r, b.length + 1)
			int action = prng_range(r, 3)
			if (pos < b.length):
				if (action == 0):
					b.data[pos] = c"\t\n :()[]{}#\"'0129+-*/&|<>abcdefghijklmnopqrstuvwxyz"[prng_range(r, 49)]
				else if (action == 1):
					b.length = pos
					b.data[pos] = 0
				else:
					string_append_char(b, b.data[pos])
			j = j + 1
	else:
		int n = case_id % 65
		if (wf_equal(target, c"program")):
			n = 32 + case_id % 33
		int i = 0
		while (i < n):
			int v = prng_range(r, 256)
			# Frequent boundary/prefix runs alongside uniform bytes.
			if (case_id % 4 == 0):
				v = c"\x00\x01\x7f\x80\xff\x66\xf3\x0f"[prng_range(r, 8)] & 255
			string_append_char(b, v)
			i = i + 1
		char* hextext = asm_hex_encode(b.data, b.length)
		string_free(b)
		prng_free(r)
		return hextext
	char* result = strclone(b.data)
	string_free(b)
	prng_free(r)
	return result


char* wf_unhex(char* text, int* length):
	int capacity = strlen(text) / 2 + 1
	char* data = malloc(capacity)
	*length = asm_hex_decode(text, data, capacity)
	wf_require(*length >= 0, c"invalid hex input")
	return data


# A bounded typed program model. Every instruction keeps state in 0..1023;
# the evaluator uses arithmetic where emitted source uses bit masks/shifts.
# No overflow, invalid shifts, division by zero, or architecture-sized result.
char* wf_program(char* input, int* expected):
	int n = 0
	char* data = wf_unhex(input, &n)
	string_builder* s = string_new()
	string_append(s, c"import lib.lib\nstruct FuzzPair:\n\tint x\n\tint y\nint fuzz_add(int a, int b):\n\treturn (a + b) & 1023\nint main():\n\tint x = 7\n\tint i = 0\n\tint a[4]\n\tFuzzPair p\n\tp.x = 0\n\tp.y = 0\n")
	int x = 7
	int i = 0
	while (i + 1 < n):
		int op = (data[i] & 255) % 8
		int v = data[i + 1] & 255
		if (op == 0):
			string_append(s, c"\tx = (x + ")
			string_append_int(s, v)
			string_append(s, c") & 1023\n")
			x = (x + v) % 1024
		else if (op == 1):
			string_append(s, c"\tx = (x * ")
			string_append_int(s, v)
			string_append(s, c") & 1023\n")
			x = (x * v) % 1024
		else if (op == 2):
			string_append(s, c"\tx = fuzz_add(x, ")
			string_append_int(s, v)
			string_append(s, c")\n")
			x = (x + v) % 1024
		else if (op == 3):
			string_append(s, c"\tif (x < ")
			string_append_int(s, v)
			string_append(s, c"):\n\t\tx = x + 1\n\telse:\n\t\tx = x / 2\n")
			if (x < v):
				x = x + 1
			else:
				x = x / 2
		else if (op == 4):
			string_append(s, c"\ti = 0\n\twhile (i < ")
			string_append_int(s, v % 8)
			string_append(s, c"):\n\t\tx = (x + i) & 1023\n\t\ti = i + 1\n")
			int j = 0
			while (j < v % 8):
				x = (x + j) % 1024
				j = j + 1
		else if (op == 5):
			string_append(s, c"\ta[2] = x\n\tp.x = a[2]\n\tx = (p.x + 3 * 7) & 1023\n")
			x = (x + 21) % 1024
		else if (op == 6):
			string_append(s, c"\tx = (x << 2) & 1023\n")
			x = (x * 4) % 1024
		else:
			string_append(s, c"\tif (x >= 0 && x < 1024):\n\t\tx = (x + 1) & 1023\n")
			x = (x + 1) % 1024
		i = i + 2
	string_append(s, c"\tprintln(itoa(x))\n\treturn 0\n")
	*expected = x
	free(data)
	char* result = strclone(s.data)
	string_free(s)
	return result
