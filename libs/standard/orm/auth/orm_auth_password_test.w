# wbuild: arch_only=x64
# U3.1 password hashing: Django-format PBKDF2-SHA256 against vectors
# produced by Django's hasher (the first is Django 5.2's own test vector;
# the rest were computed with Python's hashlib.pbkdf2_hmac, which is what
# Django's PBKDF2PasswordHasher calls), rehash rules and unusable values.
import lib.assert
import libs.standard.orm.auth.password


void check_vector(char* password, char* salt, int iterations, char* want):
	char* got = make_password_with(password, salt, iterations)
	assert_strings_equal(want, got)
	assert_equal(1, check_password(password, want))
	free(got)


void test_django_vectors():
	# django/tests/auth_tests/test_hashers.py (Django 5.2, 1,000,000 iterations).
	check_vector(c"l\xc3\xa8tmein", c"seasalt", 1000000, c"pbkdf2_sha256$1000000$seasalt$r1uLUxoxpP2Ued/qxvmje7UH9PUJBkRrvf9gGPL7Cps=")
	check_vector(c"l\xc3\xa8tmein", c"seasalt", 1000, c"pbkdf2_sha256$1000$seasalt$JgZryXe2Ga8ysg6XbzkLpTdyPQrHqsinbL9BnnhgX4A=")
	check_vector(c"", c"abcdefghijklmnopqrstuv", 1000, c"pbkdf2_sha256$1000$abcdefghijklmnopqrstuv$vqafFtFOwJN9wrhga0SNKKw1GODAJgholvjeoMoWcZs=")
	check_vector(c"hunter2", c"Xq7Ba2Lm9pRtZc4eHs1wKd", 260000, c"pbkdf2_sha256$260000$Xq7Ba2Lm9pRtZc4eHs1wKd$H/+5iemK5KsXlvfcOHkyWDJH0J2NPKxgcQ0op8HP4lQ=")
	check_vector(c"correct horse battery staple", c"W3rgUq0x8f1bTzN6aY5cLm", 20000, c"pbkdf2_sha256$20000$W3rgUq0x8f1bTzN6aY5cLm$fMTEmMoYLyV5G6bFUkR3v8YuzBmFnQLlrJxQbhWOffg=")


void test_check_rejects():
	char* good = c"pbkdf2_sha256$1000$seasalt$JgZryXe2Ga8ysg6XbzkLpTdyPQrHqsinbL9BnnhgX4A="
	assert_equal(0, check_password(c"letmein", good))
	assert_equal(0, check_password(c"l\xc3\xa8tmeiN", good))
	assert_equal(0, check_password(0, good))
	assert_equal(0, check_password(c"l\xc3\xa8tmein", 0))
	assert_equal(0, check_password(c"l\xc3\xa8tmein", c""))
	# Tampered hash, iterations, salt and algorithm.
	assert_equal(0, check_password(c"l\xc3\xa8tmein", c"pbkdf2_sha256$1000$seasalt$JgZryXe2Ga8ysg6XbzkLpTdyPQrHqsinbL9BnnhgX4B="))
	assert_equal(0, check_password(c"l\xc3\xa8tmein", c"pbkdf2_sha256$1001$seasalt$JgZryXe2Ga8ysg6XbzkLpTdyPQrHqsinbL9BnnhgX4A="))
	assert_equal(0, check_password(c"l\xc3\xa8tmein", c"pbkdf2_sha256$1000$seasalT$JgZryXe2Ga8ysg6XbzkLpTdyPQrHqsinbL9BnnhgX4A="))
	assert_equal(0, check_password(c"l\xc3\xa8tmein", c"pbkdf2_sha1$1000$seasalt$JgZryXe2Ga8ysg6XbzkLpTdyPQrHqsinbL9BnnhgX4A="))
	# Malformed.
	assert_equal(0, check_password(c"x", c"pbkdf2_sha256$1000$seasalt"))
	assert_equal(0, check_password(c"x", c"pbkdf2_sha256$$seasalt$abc"))
	assert_equal(0, check_password(c"x", c"pbkdf2_sha256$-5$seasalt$abc"))
	assert_equal(0, check_password(c"x", c"pbkdf2_sha256$0$seasalt$abc"))
	assert_equal(0, check_password(c"x", c"pbkdf2_sha256$99999999999$seasalt$abc"))
	assert_equal(0, check_password(c"x", c"$1000$seasalt$abc"))
	assert_equal(0, check_password(c"x", c"pbkdf2_sha256$1000$$abc"))
	assert1(auth_pbkdf2_sha256_encode(c"x", c"a$b", 10) == 0)
	assert1(auth_pbkdf2_sha256_encode(c"x", c"", 10) == 0)
	assert1(auth_pbkdf2_sha256_encode(c"x", c"ab", 0) == 0)


void test_decode():
	auth_password_parts* p = auth_password_decode(c"pbkdf2_sha256$1000$seasalt$a$b")
	assert1(p != 0)
	assert_strings_equal(c"pbkdf2_sha256", p.algorithm)
	assert_equal(1000, p.iterations)
	assert_strings_equal(c"seasalt", p.salt)
	assert_strings_equal(c"a$b", p.hash)
	auth_password_parts_free(p)


void test_make_and_rehash():
	assert_equal(1000000, auth_password_iterations())
	auth_password_set_iterations(1000)
	assert_equal(1000, auth_password_iterations())
	char* a = make_password(c"s3cret")
	char* b = make_password(c"s3cret")
	assert1(starts_with_at(a, c"pbkdf2_sha256$1000$", 0))
	assert_equal(strlen(c"pbkdf2_sha256$1000$") + 22 + 1 + 44, strlen(a))
	assert1(strcmp(a, b) != 0)
	assert_equal(1, check_password(c"s3cret", a))
	assert_equal(1, check_password(c"s3cret", b))
	assert_equal(0, check_password(c"s3creT", a))
	assert_equal(0, password_needs_rehash(a))
	auth_password_parts* p = auth_password_decode(a)
	assert_equal(22, strlen(p.salt))
	for i in range(22): assert1(isalnum(p.salt[i]))
	auth_password_parts_free(p)
	# Raising the setting makes older hashes stale; lowering does not.
	auth_password_set_iterations(2000)
	assert_equal(1, password_needs_rehash(a))
	auth_password_set_iterations(500)
	assert_equal(0, password_needs_rehash(a))
	auth_password_set_iterations(1000)
	# Short (Django < 3.1 style) salts and other algorithms need a rehash.
	assert_equal(1, password_needs_rehash(c"pbkdf2_sha256$1000$seasalt$JgZryXe2Ga8ysg6XbzkLpTdyPQrHqsinbL9BnnhgX4A="))
	assert_equal(1, password_needs_rehash(c"argon2$argon2id$v=19$m=102400,t=2,p=8$abc$def"))
	assert_equal(0, password_needs_rehash(c"pbkdf2_sha256$1000$abcdefghijklmnopqrstuv$vqafFtFOwJN9wrhga0SNKKw1GODAJgholvjeoMoWcZs="))
	free(a)
	free(b)
	auth_password_set_iterations(0)
	assert_equal(1000000, auth_password_iterations())


void test_unusable():
	char* u = make_password(0)
	char* v = make_password(0)
	assert_equal(41, strlen(u))
	assert_equal('!', u[0])
	assert1(strcmp(u, v) != 0)
	assert_equal(0, is_password_usable(u))
	assert_equal(0, check_password(c"", u))
	assert_equal(0, check_password(u, u))
	assert_equal(0, password_needs_rehash(u))
	assert_equal(1, is_password_usable(c"pbkdf2_sha256$1$a$b"))
	free(u)
	free(v)
	char* r = auth_random_string(64)
	assert_equal(64, strlen(r))
	for i in range(64): assert1(isalnum(r[i]))
	free(r)


int main():
	test_decode()
	test_check_rejects()
	test_make_and_rehash()
	test_unusable()
	test_django_vectors()
	println(c"orm_auth_password_test: OK")
	return 0
