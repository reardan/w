# Django-compatible password hashing for w-orm auth (issue #754, unit U3.1;
# docs/projects/orm/u3_1.md).
#
#   char* enc = make_password(c"hunter2")   # pbkdf2_sha256$1000000$<salt>$<b64>
#   check_password(c"hunter2", enc)          # 1
#   password_needs_rehash(enc)               # 1 once the iteration setting rises
#   free(enc)
#
# The stored form is Django's PBKDF2PasswordHasher output,
# `pbkdf2_sha256$<iterations>$<salt>$<base64(PBKDF2-HMAC-SHA256, 32 bytes)>`,
# so hashes move between a Django app and a W app on the same database in
# both directions. The salt is 22 characters of [A-Za-z0-9] (Django's
# 128-bit salt entropy). Unusable passwords start with "!" and never check.
# Nothing here touches the database.
import lib.str
import structures.string
import libs.standard.crypto.pbkdf2
import libs.standard.crypto.base64
import libs.standard.crypto.secrets


const int AUTH_PBKDF2_DEFAULT_ITERATIONS = 1000000   # Django 5.2's default
const int AUTH_SALT_LENGTH = 22                      # ceil(128 / log2(62))
const int AUTH_UNUSABLE_SUFFIX_LENGTH = 40

int __auth_pbkdf2_iterations


# The iteration count new hashes use (and below which a stored hash needs a
# rehash). Tests lower it; 0 restores the default.
void auth_password_set_iterations(int n):
	if (n < 0): n = 0
	__auth_pbkdf2_iterations = n


int auth_password_iterations():
	if (__auth_pbkdf2_iterations > 0): return __auth_pbkdf2_iterations
	return AUTH_PBKDF2_DEFAULT_ITERATIONS


char* auth_random_chars():
	return c"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"


# Django's get_random_string(n): n CSPRNG-chosen characters of [a-zA-Z0-9],
# owned. 0 when the CSPRNG fails.
char* auth_random_string(int n):
	char* chars = auth_random_chars()
	char* out = cast(char*, malloc(n + 1))
	for i in range(n):
		int k = secrets_randbelow(62)
		if (k < 0):
			free(out)
			return 0
		out[i] = chars[k]
	out[n] = 0
	return out


# Django's PBKDF2PasswordHasher.encode(password, salt, iterations): owned
# encoded text, or 0 when iterations < 1 or the salt is empty or holds '$'.
char* auth_pbkdf2_sha256_encode(char* password, char* salt, int iterations):
	if (password == 0 || salt == 0 || iterations < 1): return 0
	if (salt[0] == 0 || index_of(salt, c"$") >= 0): return 0
	char* dk = pbkdf2_hmac(c"sha256", password, strlen(password), salt, strlen(salt), iterations, 32)
	if (dk == 0): return 0
	char* b64 = base64_encode(dk, 32)
	secrets_wipe(dk, 32)
	free(dk)
	string_builder* sb = string_new()
	string_append(sb, c"pbkdf2_sha256$")
	string_append_int(sb, iterations)
	string_append_char(sb, '$')
	string_append(sb, salt)
	string_append_char(sb, '$')
	string_append(sb, b64)
	free(b64)
	char* r = sb.data
	free(cast(void*, sb))
	return r


# make_password(password, salt, hasher) with an explicit salt and iteration
# count (salt 0 = a fresh random salt, iterations 0 = the current setting).
# password 0 makes an unusable password. Owned; 0 on bad arguments.
char* make_password_with(char* password, char* salt, int iterations):
	if (password == 0):
		char* tail = auth_random_string(AUTH_UNUSABLE_SUFFIX_LENGTH)
		if (tail == 0): return 0
		char* r = cast(char*, malloc(AUTH_UNUSABLE_SUFFIX_LENGTH + 2))
		r[0] = '!'
		for i in range(AUTH_UNUSABLE_SUFFIX_LENGTH + 1): r[i + 1] = tail[i]
		free(tail)
		return r
	if (iterations == 0): iterations = auth_password_iterations()
	if (salt != 0): return auth_pbkdf2_sha256_encode(password, salt, iterations)
	char* fresh = auth_random_string(AUTH_SALT_LENGTH)
	if (fresh == 0): return 0
	char* enc = auth_pbkdf2_sha256_encode(password, fresh, iterations)
	free(fresh)
	return enc


# Django's make_password(password): a new salted hash at the current
# iteration setting; password 0 gives an unusable "!..." value. Owned.
char* make_password(char* password):
	return make_password_with(password, 0, 0)


# Django's is_password_usable: 0 for "!"-prefixed (unusable) values.
int is_password_usable(char* encoded):
	return encoded == 0 || encoded[0] != '!'


# The parts of an encoded hash.
struct auth_password_parts:
	char* algorithm
	int iterations
	char* salt
	char* hash


void auth_password_parts_free(auth_password_parts* p):
	if (p == 0): return
	if (p.algorithm != 0): free(p.algorithm)
	if (p.salt != 0): free(p.salt)
	if (p.hash != 0): free(p.hash)
	free(cast(void*, p))


# Splits "algorithm$iterations$salt$hash" (the hash keeps any further '$',
# like Python's split("$", 3)). 0 when it is not that shape or the
# iteration count is not a positive decimal.
auth_password_parts* auth_password_decode(char* encoded):
	if (encoded == 0): return 0
	int n = strlen(encoded)
	int d1 = index_of(encoded, c"$")
	if (d1 <= 0): return 0
	int d2 = d1 + 1
	while (d2 < n && encoded[d2] != '$'): d2 = d2 + 1
	if (d2 >= n): return 0
	int d3 = d2 + 1
	while (d3 < n && encoded[d3] != '$'): d3 = d3 + 1
	if (d3 >= n): return 0
	int iterations = 0
	if (d2 == d1 + 1 || d2 - d1 > 10): return 0
	for i in range(d1 + 1, d2):
		if (isdigit(encoded[i]) == 0): return 0
		iterations = iterations * 10 + (encoded[i] - '0')
	if (iterations < 1): return 0
	auth_password_parts* p = new auth_password_parts()
	p.algorithm = substring(encoded, 0, d1)
	p.iterations = iterations
	p.salt = substring(encoded, d2 + 1, d3)
	p.hash = substring(encoded, d3 + 1, n)
	return p


# Django's check_password(password, encoded): 1 when password matches the
# stored hash. Unusable, malformed and non-pbkdf2_sha256 values never match.
# The final comparison is constant-time over the encoded text.
int check_password(char* password, char* encoded):
	if (password == 0 || encoded == 0 || is_password_usable(encoded) == 0): return 0
	auth_password_parts* p = auth_password_decode(encoded)
	if (p == 0): return 0
	int ok = 0
	if (strcmp(p.algorithm, c"pbkdf2_sha256") == 0):
		char* again = auth_pbkdf2_sha256_encode(password, p.salt, p.iterations)
		if (again != 0):
			ok = secrets_compare_digest_str(encoded, again)
			free(again)
	auth_password_parts_free(p)
	return ok


# 1 when a usable stored hash should be replaced on the next successful
# login: another algorithm, fewer iterations than the current setting, or
# a salt shorter than Django's 128-bit minimum. Unusable values: 0.
int password_needs_rehash(char* encoded):
	if (encoded == 0 || is_password_usable(encoded) == 0): return 0
	auth_password_parts* p = auth_password_decode(encoded)
	if (p == 0): return 1
	int r = 0
	if (strcmp(p.algorithm, c"pbkdf2_sha256") != 0): r = 1
	else if (p.iterations < auth_password_iterations()): r = 1
	else if (strlen(p.salt) < AUTH_SALT_LENGTH): r = 1
	auth_password_parts_free(p)
	return r
