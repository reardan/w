# Sessions, API tokens, CSRF and login throttle scenarios (unit U3.2,
# docs/projects/orm/u3_2.md), shared by
# libs/standard/orm/auth/orm_session_test.w (SQLite) and
# orm_session_postgres_test.w. Every database step asserts how many
# statements it ran; the clock is injected with auth_set_clock.
import libs.standard.orm.auth.perms
import libs.standard.orm.auth.token
import libs.standard.orm.auth.csrf
import libs.standard.orm.auth.throttle
import tests.orm.fixtures.auth_schema
import lib.assert


int __sess_mark
int __sess_t


int sess_clock():
	return __sess_t


# 2026-10-19 10:00:00 UTC
int sess_t0():
	return 1792404000


void sess_expect_queries(orm_db* db, int n):
	if (db.query_count - __sess_mark != n):
		print(c"expected queries: ")
		println(itoa(n))
		print(c"got: ")
		println(itoa(db.query_count - __sess_mark))
		print(c"last error: ")
		println(orm_db_error(db))
	assert_equal(n, db.query_count - __sess_mark)
	__sess_mark = db.query_count


void sess_check(orm_db* db, int ok):
	asserts(orm_db_error(db), ok)


char* sess_sqlite_ddl(int i):
	if (i == 0): return c"CREATE TABLE auth_session (id INTEGER PRIMARY KEY AUTOINCREMENT, session_key VARCHAR(64) NOT NULL UNIQUE, user_id INTEGER NULL REFERENCES auth_user (id) ON DELETE CASCADE, session_data TEXT NOT NULL, expire_date TEXT NOT NULL, created TEXT NOT NULL)"
	if (i == 1): return c"CREATE INDEX auth_session_user_id_idx ON auth_session (user_id)"
	if (i == 2): return c"CREATE INDEX auth_session_expire_date_idx ON auth_session (expire_date)"
	if (i == 3): return c"CREATE TABLE auth_api_token (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL REFERENCES auth_user (id) ON DELETE CASCADE, name VARCHAR(100) NOT NULL, token_key VARCHAR(8) NOT NULL, digest VARCHAR(64) NOT NULL UNIQUE, created TEXT NOT NULL, expiry TEXT NULL, last_used TEXT NULL, UNIQUE (user_id, name))"
	if (i == 4): return c"CREATE INDEX auth_api_token_user_id_idx ON auth_api_token (user_id)"
	if (i == 5): return c"CREATE INDEX auth_api_token_token_key_idx ON auth_api_token (token_key)"
	return 0


char* sess_postgres_ddl(int i):
	if (i == 0): return c"CREATE TABLE auth_session (id BIGSERIAL PRIMARY KEY, session_key VARCHAR(64) NOT NULL UNIQUE, user_id BIGINT NULL REFERENCES auth_user (id) ON DELETE CASCADE, session_data TEXT NOT NULL, expire_date TIMESTAMP NOT NULL, created TIMESTAMP NOT NULL)"
	if (i == 1): return c"CREATE INDEX auth_session_user_id_idx ON auth_session (user_id)"
	if (i == 2): return c"CREATE INDEX auth_session_expire_date_idx ON auth_session (expire_date)"
	if (i == 3): return c"CREATE TABLE auth_api_token (id BIGSERIAL PRIMARY KEY, user_id BIGINT NOT NULL REFERENCES auth_user (id) ON DELETE CASCADE, name VARCHAR(100) NOT NULL, token_key VARCHAR(8) NOT NULL, digest VARCHAR(64) NOT NULL UNIQUE, created TIMESTAMP NOT NULL, expiry TIMESTAMP NULL, last_used TIMESTAMP NULL, UNIQUE (user_id, name))"
	if (i == 4): return c"CREATE INDEX auth_api_token_user_id_idx ON auth_api_token (user_id)"
	if (i == 5): return c"CREATE INDEX auth_api_token_token_key_idx ON auth_api_token (token_key)"
	return 0


int sess_create_schema(orm_db* db):
	if (auth_create_schema(db) == 0): return 0
	int i = 0
	while (1):
		char* ddl = 0
		if (db.dialect.id == ORM_DIALECT_POSTGRES): ddl = sess_postgres_ddl(i)
		else: ddl = sess_sqlite_ddl(i)
		if (ddl == 0): return 1
		if (orm_db_exec_sql(db, ddl) == 0): return 0
		i = i + 1
	return 1


int sess_drop_schema(orm_db* db):
	int ok = orm_db_exec_sql(db, c"DROP TABLE IF EXISTS auth_api_token")
	ok = ok && orm_db_exec_sql(db, c"DROP TABLE IF EXISTS auth_session")
	return ok && auth_drop_schema(db)


# The stored row of session id (not counted).
Session* sess_row(orm_db* db, int id):
	orm_result* r = Session_objects(db).filter(q_eq_int(c"id", id)).all()
	sess_check(db, r != 0)
	__sess_mark = db.query_count
	if (r.rows.length != 1):
		orm_result_free(r)
		return 0
	orm_model_desc* m = Session_desc()
	Session* out = Session_new()
	for orm_field_desc* fd in m.fields: orm_copy_field(m, fd, out, Session_rows(r)[0])
	orm_result_free(r)
	return out


int sess_count(orm_db* db):
	int n = Session_objects(db).count()
	__sess_mark = db.query_count
	return n


void sess_case_sessions(orm_db* db):
	__sess_t = sess_t0()
	auth_session_settings* st = session_settings()
	st.max_age = 3600
	st.refresh_after = 300

	# create: one INSERT; only the digest is stored.
	auth_session* s = session_create(db, 0)
	sess_check(db, s != 0)
	sess_expect_queries(db, 1)
	assert1(s.id > 0)
	assert_equal(43, strlen(s.key))
	assert_equal(0, s.user_id)
	assert_equal(sess_t0() + 3600, s.expires_at)
	Session* row = sess_row(db, s.id)
	char* digest = auth_token_digest(s.key)
	assert_strings_equal(digest, row.session_key)
	assert_equal(64, strlen(row.session_key))
	assert1(strcmp(row.session_key, s.key) != 0)
	assert_strings_equal(c"{}", row.session_data)
	assert1(starts_with_at(row.expire_date, c"2026-10-19 11:00:00", 0))
	assert1(starts_with_at(row.created, c"2026-10-19 10:00:00", 0))
	assert_equal(0, index_of(row.session_data, s.key) >= 0)
	free(digest)
	Session_free(row)

	# Cookie flags.
	char* hdr = session_cookie_header(s)
	assert1(starts_with_at(hdr, c"sessionid=", 0))
	assert1(starts_with_at(hdr, s.key, 10))
	assert1(ends_with(hdr, c"; Path=/; Max-Age=3600; Secure; HttpOnly; SameSite=Lax"))
	free(hdr)
	hdr = session_cookie_delete_header()
	assert_strings_equal(c"sessionid=; Path=/; Max-Age=0; Secure; HttpOnly; SameSite=Lax", hdr)
	free(hdr)
	string_builder* req = string_new()
	string_append(req, c"theme=dark; sessionid=")
	string_append(req, s.key)
	char* back = session_cookie_value(req.data)
	assert_strings_equal(s.key, back)
	free(back)
	string_free(req)
	assert1(session_cookie_value(c"theme=dark") == 0)

	# Data: save writes once; an unmodified save runs nothing.
	session_set(s, c"cart", c"3")
	session_set(s, c"note", c"quote \" and \\ slash")
	assert_equal(1, s.modified)
	sess_check(db, session_save(db, s))
	sess_expect_queries(db, 1)
	assert_equal(0, s.modified)
	sess_check(db, session_save(db, s))
	session_set(s, c"cart", c"3")
	sess_check(db, session_save(db, s))
	sess_expect_queries(db, 0)

	# load: one SELECT while the refresh is not due.
	__sess_t = sess_t0() + 100
	auth_session* l = session_load(db, s.key)
	sess_check(db, l != 0)
	sess_expect_queries(db, 1)
	assert_equal(s.id, l.id)
	assert_strings_equal(c"3", session_get(l, c"cart"))
	assert_strings_equal(c"quote \" and \\ slash", session_get(l, c"note"))
	assert1(session_get(l, c"missing") == 0)
	assert_equal(sess_t0() + 3600, l.expires_at)
	assert_equal(3500, session_remaining(l))
	session_remove(l, c"note")
	assert_equal(0, session_has(l, c"note"))
	assert_equal(1, session_has(l, c"cart"))
	sess_check(db, session_save(db, l))
	sess_expect_queries(db, 1)
	# That save pushed the expiry to t0+100+3600.
	assert_equal(sess_t0() + 3700, l.expires_at)
	auth_session_free(l)

	# Sliding refresh: a load >= refresh_after since the last write adds one
	# UPDATE of expire_date.
	__sess_t = sess_t0() + 500
	l = session_load(db, s.key)
	sess_check(db, l != 0)
	sess_expect_queries(db, 2)
	assert_equal(sess_t0() + 500 + 3600, l.expires_at)
	assert_equal(0, session_has(l, c"note"))
	auth_session_free(l)
	row = sess_row(db, s.id)
	assert1(starts_with_at(row.expire_date, c"2026-10-19 11:08:20", 0))
	Session_free(row)
	st.refresh_after = -1
	__sess_t = sess_t0() + 3000
	l = session_load(db, s.key)
	sess_check(db, l != 0)
	sess_expect_queries(db, 1)
	auth_session_free(l)
	st.refresh_after = 300

	# Expiry: past expire_date the key no longer loads (no error).
	__sess_t = sess_t0() + 500 + 3600
	assert1(session_load(db, s.key) == 0)
	sess_expect_queries(db, 1)
	assert_strings_equal(c"", orm_db_error(db))
	# Unknown and malformed keys.
	__sess_t = sess_t0() + 600
	assert1(session_load(db, c"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA") == 0)
	sess_expect_queries(db, 1)
	assert1(session_load(db, c"short") == 0)
	assert1(session_load(db, c"has spaces and;semicolons=====") == 0)
	assert1(session_load(db, 0) == 0)
	sess_expect_queries(db, 0)

	# rotate: new key, same row and data; the old key stops working.
	char* old_key = strclone(s.key)
	int old_id = s.id
	sess_check(db, session_rotate(db, s))
	sess_expect_queries(db, 1)
	assert1(strcmp(old_key, s.key) != 0)
	assert_equal(old_id, s.id)
	assert1(session_load(db, old_key) == 0)
	sess_expect_queries(db, 1)
	l = session_load(db, s.key)
	sess_check(db, l != 0)
	sess_expect_queries(db, 1)
	assert_strings_equal(c"3", session_get(l, c"cart"))
	auth_session_free(l)
	free(old_key)

	# login on an anonymous session: rotates the key, writes user_id, keeps
	# the cart, drops the CSRF secret. One UPDATE.
	User* ada = create_user(db, c"ada", 0, c"pw-ada")
	User* bob = create_user(db, c"bob", 0, c"pw-bob")
	sess_check(db, ada != 0 && bob != 0)
	__sess_mark = db.query_count
	char* secret = strclone(csrf_get_secret(s))
	assert_equal(32, strlen(secret))
	old_key = strclone(s.key)
	auth_session* li = session_login(db, s, ada)
	sess_check(db, li == s)
	sess_expect_queries(db, 1)
	assert_equal(ada.id, s.user_id)
	assert_equal(old_id, s.id)
	assert1(strcmp(old_key, s.key) != 0)
	assert_strings_equal(c"3", session_get(s, c"cart"))
	assert1(csrf_session_secret(s) == 0)
	assert1(session_load(db, old_key) == 0)
	sess_expect_queries(db, 1)
	free(old_key)
	free(secret)
	User* who = session_user(db, s)
	sess_check(db, who != 0)
	sess_expect_queries(db, 1)
	assert_equal(ada.id, who.id)
	User_free(who)
	l = session_load(db, s.key)
	sess_check(db, l != 0)
	assert_equal(ada.id, l.user_id)
	auth_session_free(l)
	__sess_mark = db.query_count

	# login as another user: the old session is flushed and a new one made.
	auth_session* b = session_login(db, s, bob)
	sess_check(db, b != 0)
	sess_expect_queries(db, 2)
	assert1(b != s)
	assert1(b.id != old_id)
	assert_equal(bob.id, b.user_id)
	assert1(session_get(b, c"cart") == 0)
	assert_equal(0, s.id)
	assert1(s.key == 0)
	assert1(session_get(s, c"cart") == 0)
	assert1(session_cookie_header(s) == 0)
	assert1(sess_row(db, old_id) == 0)
	auth_session_free(s)
	# login with no session creates one.
	auth_session* a2 = session_login(db, 0, ada)
	sess_check(db, a2 != 0)
	sess_expect_queries(db, 1)
	assert_equal(ada.id, a2.user_id)
	assert1(session_login(db, a2, 0) == 0)
	sess_expect_queries(db, 0)
	# An inactive user's session yields no user.
	bob.is_active = 0
	sess_check(db, User_save(db, bob))
	__sess_mark = db.query_count
	assert1(session_user(db, b) == 0)
	sess_expect_queries(db, 1)
	assert1(session_user(db, 0) == 0)
	auth_session* anon = session_create(db, 0)
	sess_check(db, anon != 0)
	sess_expect_queries(db, 1)
	assert1(session_user(db, anon) == 0)
	sess_expect_queries(db, 0)

	# logout = flush: one DELETE, then the key is dead; a second flush and a
	# save of a flushed session do nothing / fail cleanly.
	char* bkey = strclone(b.key)
	sess_check(db, session_logout(db, b))
	sess_expect_queries(db, 1)
	assert1(session_load(db, bkey) == 0)
	sess_expect_queries(db, 1)
	sess_check(db, session_flush(db, b))
	sess_expect_queries(db, 0)
	session_set(b, c"x", c"y")
	assert_equal(0, session_save(db, b))
	assert_strings_equal(c"auth: the session was flushed", orm_db_error(db))
	sess_expect_queries(db, 0)
	free(bkey)
	auth_session_free(b)

	# flush_user and clear_expired.
	auth_session* a3 = session_create(db, ada.id)
	sess_check(db, a3 != 0)
	sess_expect_queries(db, 1)
	assert_equal(3, sess_count(db))
	assert_equal(2, session_flush_user(db, ada.id))
	sess_expect_queries(db, 1)
	assert_equal(1, sess_count(db))
	__sess_t = sess_t0() + 1000
	auth_session* late = session_create(db, 0)
	sess_check(db, late != 0)
	__sess_t = sess_t0() + 600 + 3600
	assert_equal(1, session_clear_expired(db))
	assert1(session_load(db, anon.key) == 0)
	l = session_load(db, late.key)
	sess_check(db, l != 0)
	auth_session_free(l)
	assert_equal(1, sess_count(db))
	auth_session_free(a2)
	auth_session_free(a3)
	auth_session_free(anon)
	auth_session_free(late)

	# Corrupt stored data loads as an empty map.
	auth_session* c = session_create(db, 0)
	sess_check(db, c != 0)
	sess_check(db, Session_objects(db).filter(q_eq_int(c"id", c.id)).update(c"session_data", val(c"{not json")) == 1)
	sess_check(db, Session_objects(db).filter(q_eq_int(c"id", c.id)).update(c"session_data", val(c"{\"a\":\"1\",\"n\":5}")) == 1)
	l = session_load(db, c.key)
	sess_check(db, l != 0)
	assert_strings_equal(c"1", session_get(l, c"a"))
	assert1(session_get(l, c"n") == 0)
	auth_session_free(l)
	sess_check(db, Session_objects(db).filter(q_eq_int(c"id", c.id)).update(c"session_data", val(c"{not json")) == 1)
	l = session_load(db, c.key)
	sess_check(db, l != 0)
	assert1(session_get(l, c"a") == 0)
	auth_session_free(l)
	auth_session_free(c)

	# Cookie settings are honoured.
	st.secure = 0
	st.cookie_name = c"sid"
	st.cookie_domain = c"example.com"
	st.same_site = c"Strict"
	hdr = session_cookie_delete_header()
	assert_strings_equal(c"sid=; Path=/; Domain=example.com; Max-Age=0; HttpOnly; SameSite=Strict", hdr)
	free(hdr)
	st.secure = 1
	st.cookie_name = c"sessionid"
	st.cookie_domain = 0
	st.same_site = c"Lax"
	__sess_mark = db.query_count
	User_free(ada)
	User_free(bob)


void sess_case_tokens(orm_db* db):
	__sess_t = sess_t0()
	User* ada = user_get_by_username(db, c"ada")
	User* bob = user_get_by_username(db, c"bob")
	sess_check(db, ada != 0 && bob != 0)
	bob.is_active = 1
	sess_check(db, User_save(db, bob))
	__sess_mark = db.query_count
	token_set_touch_interval(60)

	ApiToken* row = 0
	char* ci = token_create_row(db, ada.id, c"ci", 0, &row)
	sess_check(db, ci != 0)
	sess_expect_queries(db, 1)
	assert_equal(43, strlen(ci))
	assert_equal(ada.id, row.user_id)
	assert_strings_equal(c"ci", row.name)
	assert_equal(8, strlen(row.token_key))
	assert1(starts_with_at(ci, row.token_key, 0))
	char* digest = auth_token_digest(ci)
	assert_strings_equal(digest, row.digest)
	free(digest)
	assert1(row.expiry == 0)
	assert1(row.last_used == 0)
	ApiToken_free(row)
	char* laptop = token_create(db, ada.id, c"laptop", 600)
	sess_check(db, laptop != 0)
	sess_expect_queries(db, 1)
	char* bobs = token_create(db, bob.id, c"ci", 0)
	sess_check(db, bobs != 0)
	sess_expect_queries(db, 1)
	# Names are unique per user.
	assert1(token_create(db, ada.id, c"ci", 0) == 0)
	assert1(strlen(orm_db_error(db)) > 0)
	sess_expect_queries(db, 1)
	assert1(token_create(db, ada.id, c"", 0) == 0)
	assert1(token_create(db, 0, c"x", 0) == 0)
	sess_expect_queries(db, 0)

	# authenticate_token: SELECT token, UPDATE last_used, SELECT user.
	User* who = authenticate_token(db, ci)
	sess_check(db, who != 0)
	sess_expect_queries(db, 3)
	assert_equal(ada.id, who.id)
	User_free(who)
	# Within the touch interval: no last_used write.
	__sess_t = sess_t0() + 30
	who = authenticate_token(db, ci)
	sess_check(db, who != 0)
	sess_expect_queries(db, 2)
	User_free(who)
	__sess_t = sess_t0() + 90
	who = authenticate_token(db, ci)
	sess_check(db, who != 0)
	sess_expect_queries(db, 3)
	User_free(who)
	orm_result* r = token_list(db, ada.id)
	sess_check(db, r != 0)
	sess_expect_queries(db, 1)
	assert_equal(2, r.rows.length)
	assert_strings_equal(c"ci", ApiToken_rows(r)[0].name)
	assert1(starts_with_at(ApiToken_rows(r)[0].last_used, c"2026-10-19 10:01:30", 0))
	assert_strings_equal(c"laptop", ApiToken_rows(r)[1].name)
	assert1(starts_with_at(ApiToken_rows(r)[1].expiry, c"2026-10-19 10:10:00", 0))
	assert1(ApiToken_rows(r)[1].last_used == 0)
	orm_result_free(r)
	who = authenticate_token(db, bobs)
	sess_check(db, who != 0)
	sess_expect_queries(db, 3)
	assert_equal(bob.id, who.id)
	User_free(who)

	# Rejections: garbage (no query), right prefix + wrong rest, expired.
	assert1(authenticate_token(db, c"nope") == 0)
	assert_strings_equal(AUTH_INVALID_TOKEN(), orm_db_error(db))
	assert1(authenticate_token(db, 0) == 0)
	sess_expect_queries(db, 0)
	char* forged = strclone(ci)
	if (forged[20] == 'A'): forged[20] = 'B'
	else: forged[20] = 'A'
	assert1(authenticate_token(db, forged) == 0)
	assert_strings_equal(AUTH_INVALID_TOKEN(), orm_db_error(db))
	sess_expect_queries(db, 1)
	free(forged)
	who = authenticate_token(db, laptop)
	sess_check(db, who != 0)
	User_free(who)
	__sess_t = sess_t0() + 600
	__sess_mark = db.query_count
	assert1(authenticate_token(db, laptop) == 0)
	assert_strings_equal(AUTH_INVALID_TOKEN(), orm_db_error(db))
	sess_expect_queries(db, 1)
	# Inactive owner.
	bob.is_active = 0
	sess_check(db, User_save(db, bob))
	__sess_mark = db.query_count
	assert1(authenticate_token(db, bobs) == 0)
	assert_strings_equal(AUTH_INVALID_TOKEN(), orm_db_error(db))
	sess_expect_queries(db, 3)

	# Revoke by name, by raw token, all; clear expired.
	assert_equal(1, token_clear_expired(db))
	sess_expect_queries(db, 1)
	assert_equal(1, token_revoke(db, ada.id, c"ci"))
	sess_expect_queries(db, 1)
	assert1(authenticate_token(db, ci) == 0)
	assert_strings_equal(AUTH_INVALID_TOKEN(), orm_db_error(db))
	sess_expect_queries(db, 1)
	assert_equal(0, token_revoke(db, ada.id, c"ci"))
	char* t1 = token_create(db, ada.id, c"one", 0)
	char* t2 = token_create(db, ada.id, c"two", 0)
	sess_check(db, t1 != 0 && t2 != 0)
	__sess_mark = db.query_count
	assert_equal(1, token_revoke_raw(db, t1))
	sess_expect_queries(db, 2)
	assert_equal(0, token_revoke_raw(db, t1))
	assert1(authenticate_token(db, t1) == 0)
	who = authenticate_token(db, t2)
	sess_check(db, who != 0)
	User_free(who)
	assert_equal(1, token_revoke_all(db, ada.id))
	assert1(authenticate_token(db, t2) == 0)
	assert_equal(1, token_revoke_all(db, bob.id))
	assert_equal(0, ApiToken_objects(db).count())
	__sess_mark = db.query_count
	free(t1)
	free(t2)
	free(ci)
	free(laptop)
	free(bobs)
	User_free(ada)
	User_free(bob)


list[char*] sess_trusted():
	list[char*] t = new list[char*]
	t.push(c"https://app.example.org")
	t.push(c"https://*.example.net")
	return t


void sess_case_csrf():
	# Django's mask: cipher[i] = secret[i] + mask[i] (mod 62). Vector computed
	# with django.middleware.csrf._mask_cipher_secret's formula.
	char* secret = c"Zx9QwErTyUiOpAsDfGhJkLzXcVbNm012"
	char* masked = c"abcdefghijklmnopqrstuvwxyzABCDEFZybTAJx0G3sZBNGSvXz2E6VkAkBeOtvx"
	char* plain = csrf_unmask(masked)
	assert_strings_equal(secret, plain)
	free(plain)
	assert_equal(1, csrf_token_matches(secret, masked))
	assert_equal(1, csrf_token_matches(secret, secret))
	char* m1 = csrf_mask(secret)
	char* m2 = csrf_mask(secret)
	assert_equal(64, strlen(m1))
	assert1(strcmp(m1, m2) != 0)
	assert_equal(1, csrf_token_matches(secret, m1))
	assert_equal(1, csrf_token_matches(secret, m2))
	m1[40] = m1[40] ^ 1
	assert_equal(0, csrf_token_matches(secret, m1))
	free(m1)
	free(m2)
	assert1(csrf_mask(c"short") == 0)
	assert_equal(0, csrf_token_matches(0, masked))

	# Methods.
	assert_equal(1, csrf_method_is_safe(c"GET"))
	assert_equal(1, csrf_method_is_safe(c"HEAD"))
	assert_equal(1, csrf_method_is_safe(c"OPTIONS"))
	assert_equal(1, csrf_method_is_safe(c"TRACE"))
	assert_equal(1, csrf_method_needs_check(c"POST"))
	assert_equal(1, csrf_method_needs_check(c"PUT"))
	assert_equal(1, csrf_method_needs_check(c"PATCH"))
	assert_equal(1, csrf_method_needs_check(c"DELETE"))
	assert_equal(1, csrf_method_needs_check(c"get"))

	# Session secret: created lazily, masked tokens differ but all match.
	auth_session* s = auth_session_new()
	assert1(csrf_session_secret(s) == 0)
	char* tok = csrf_token(s)
	char* sec = csrf_session_secret(s)
	assert_equal(32, strlen(sec))
	assert_equal(1, s.modified)
	assert_equal(1, csrf_token_matches(sec, tok))
	char* tok2 = csrf_token(s)
	assert1(strcmp(tok, tok2) != 0)
	assert1(csrf_session_secret(s) == sec)

	list[char*] trusted = sess_trusted()
	csrf_request* r = csrf_request_new(c"GET", c"example.com", 1)
	assert1(csrf_check_session(s, r, trusted) == 0)
	assert1(csrf_check_session(0, r, trusted) == 0)
	# Same-origin POST with the token.
	r.method = c"POST"
	r.origin = c"https://example.com"
	r.token = tok
	assert1(csrf_check_session(s, r, trusted) == 0)
	r.token = tok2
	assert1(csrf_check_session(s, r, trusted) == 0)
	r.origin = c"HTTPS://Example.COM"
	assert1(csrf_check_session(s, r, trusted) == 0)
	# Token problems.
	r.origin = c"https://example.com"
	r.token = 0
	assert_strings_equal(CSRF_REASON_TOKEN_MISSING(), csrf_check_session(s, r, trusted))
	r.token = c""
	assert_strings_equal(CSRF_REASON_TOKEN_MISSING(), csrf_check_session(s, r, trusted))
	r.token = c"abc"
	assert_strings_equal(CSRF_REASON_TOKEN_LENGTH(), csrf_check_session(s, r, trusted))
	r.token = c"abcdefghijklmnopqrstuvwxyzABCDE!"
	assert_strings_equal(CSRF_REASON_TOKEN_CHARS(), csrf_check_session(s, r, trusted))
	r.token = masked
	assert_strings_equal(CSRF_REASON_TOKEN_INCORRECT(), csrf_check_session(s, r, trusted))
	r.token = sec
	assert1(csrf_check_session(s, r, trusted) == 0)
	r.token = tok
	assert_strings_equal(CSRF_REASON_NO_SECRET(), csrf_check_session(0, r, trusted))
	auth_session* fresh = auth_session_new()
	assert_strings_equal(CSRF_REASON_NO_SECRET(), csrf_check_session(fresh, r, trusted))
	auth_session_free(fresh)
	# Origin checks.
	r.origin = c"https://evil.example"
	assert_strings_equal(CSRF_REASON_BAD_ORIGIN(), csrf_check_session(s, r, trusted))
	r.origin = c"http://example.com"
	assert_strings_equal(CSRF_REASON_BAD_ORIGIN(), csrf_check_session(s, r, trusted))
	r.origin = c"null"
	assert_strings_equal(CSRF_REASON_BAD_ORIGIN(), csrf_check_session(s, r, trusted))
	r.origin = c"https://example.com.evil.example"
	assert_strings_equal(CSRF_REASON_BAD_ORIGIN(), csrf_check_session(s, r, trusted))
	r.origin = c"https://app.example.org"
	assert1(csrf_check_session(s, r, trusted) == 0)
	r.origin = c"https://api.example.net"
	assert1(csrf_check_session(s, r, trusted) == 0)
	r.origin = c"https://example.net"
	assert1(csrf_check_session(s, r, trusted) == 0)
	r.origin = c"http://api.example.net"
	assert_strings_equal(CSRF_REASON_BAD_ORIGIN(), csrf_check_session(s, r, trusted))
	r.origin = c"https://badexample.net"
	assert_strings_equal(CSRF_REASON_BAD_ORIGIN(), csrf_check_session(s, r, trusted))
	r.origin = c"https://example.com"
	assert1(csrf_check_session(s, r, 0) == 0)
	# Plain HTTP: the origin must say http.
	r.is_secure = 0
	assert_strings_equal(CSRF_REASON_BAD_ORIGIN(), csrf_check_session(s, r, trusted))
	r.origin = c"http://example.com"
	assert1(csrf_check_session(s, r, trusted) == 0)
	# No Origin over HTTP: no Referer check, token only.
	r.origin = 0
	assert1(csrf_check_session(s, r, trusted) == 0)
	# No Origin over HTTPS: the Referer must be https on a good host.
	r.is_secure = 1
	assert_strings_equal(CSRF_REASON_NO_REFERER(), csrf_check_session(s, r, trusted))
	r.referer = c"not a url"
	assert_strings_equal(CSRF_REASON_MALFORMED_REFERER(), csrf_check_session(s, r, trusted))
	r.referer = c"http://example.com/form"
	assert_strings_equal(CSRF_REASON_INSECURE_REFERER(), csrf_check_session(s, r, trusted))
	r.referer = c"https://evil.example/form"
	assert_strings_equal(CSRF_REASON_BAD_REFERER(), csrf_check_session(s, r, trusted))
	r.referer = c"https://example.com/form?x=1"
	assert1(csrf_check_session(s, r, trusted) == 0)
	r.referer = c"https://shop.example.net/cart"
	assert1(csrf_check_session(s, r, trusted) == 0)
	r.referer = c"https://app.example.org/"
	assert1(csrf_check_session(s, r, trusted) == 0)
	# Host with a port.
	r.host = c"example.com:8443"
	r.referer = c"https://example.com:8443/form"
	assert1(csrf_check_session(s, r, trusted) == 0)
	r.referer = c"https://example.com/form"
	assert_strings_equal(CSRF_REASON_BAD_REFERER(), csrf_check_session(s, r, trusted))
	r.origin = c"https://example.com:8443"
	assert1(csrf_check_session(s, r, trusted) == 0)

	# Rotation invalidates old tokens.
	r.origin = c"https://example.com:8443"
	r.token = tok
	char* old_secret = strclone(sec)
	csrf_rotate(s)
	assert1(strcmp(old_secret, csrf_session_secret(s)) != 0)
	free(old_secret)
	assert_strings_equal(CSRF_REASON_TOKEN_INCORRECT(), csrf_check_session(s, r, trusted))
	char* tok3 = csrf_token(s)
	r.token = tok3
	assert1(csrf_check_session(s, r, trusted) == 0)
	free(tok)
	free(tok2)
	free(tok3)
	free(cast(char*, r))
	trusted.free()
	auth_session_free(s)


void sess_case_throttle(orm_db* db):
	__sess_t = sess_t0()
	User* ada = user_get_by_username(db, c"ada")
	sess_check(db, ada != 0)
	ada.is_active = 1
	sess_check(db, User_save(db, ada))
	User_free(ada)
	__sess_mark = db.query_count

	# Plain fixed-window throttle.
	auth_throttle* t = throttle_new(2, 60)
	assert_equal(1, throttle_allowed(t, c"k"))
	assert_equal(1, throttle_fail(t, c"k"))
	assert_equal(1, throttle_allowed(t, c"k"))
	assert_equal(2, throttle_fail(t, c"k"))
	assert_equal(0, throttle_allowed(t, c"k"))
	assert_equal(2, throttle_failures(t, c"k"))
	assert_equal(60, throttle_retry_after(t, c"k"))
	__sess_t = sess_t0() + 45
	assert_equal(15, throttle_retry_after(t, c"k"))
	assert_equal(1, throttle_allowed(t, c"other"))
	__sess_t = sess_t0() + 60
	assert_equal(1, throttle_allowed(t, c"k"))
	assert_equal(0, throttle_failures(t, c"k"))
	assert_equal(1, throttle_fail(t, c"k"))
	throttle_reset(t, c"k")
	assert_equal(0, throttle_failures(t, c"k"))
	throttle_reset(t, c"never")
	throttle_fail(t, c"a")
	__sess_t = sess_t0() + 200
	throttle_fail(t, c"b")
	throttle_prune(t)
	assert_equal(1, t.entries.length)
	throttle_clear(t)
	assert_equal(0, t.entries.length)
	throttle_free(t)
	auth_throttle* open = throttle_new(0, 60)
	throttle_fail(open, c"k")
	throttle_fail(open, c"k")
	assert_equal(1, throttle_allowed(open, c"k"))
	throttle_free(open)

	# Login throttle: 3 per username, 5 per address, 300 s windows.
	__sess_t = sess_t0()
	auth_login_throttle* lt = login_throttle_new(3, 5, 300)
	for i in range(3):
		assert1(authenticate_throttled(db, lt, c"ada", c"wrong", c"10.0.0.1") == 0)
		assert_strings_equal(AUTH_INVALID_LOGIN(), orm_db_error(db))
		sess_expect_queries(db, 1)
	# Locked: even the right password is refused, with no query.
	assert1(authenticate_throttled(db, lt, c"ada", c"pw-ada", c"10.0.0.2") == 0)
	assert_equal(1, login_throttle_is_locked(db))
	sess_expect_queries(db, 0)
	assert_equal(300, login_throttle_retry_after(lt, c"ada", c"10.0.0.2"))
	assert_equal(3, throttle_failures(lt.by_addr, c"10.0.0.1"))
	# Other users from another address are fine.
	User* who = authenticate_throttled(db, lt, c"bob", c"pw-bob", c"10.0.0.2")
	assert1(who == 0)
	assert_strings_equal(AUTH_INVALID_LOGIN(), orm_db_error(db))
	sess_expect_queries(db, 1)
	# After the window the username may try again; success clears it.
	__sess_t = sess_t0() + 300
	assert_equal(0, login_throttle_retry_after(lt, c"ada", c"10.0.0.2"))
	assert1(authenticate_throttled(db, lt, c"ada", c"wrong", c"10.0.0.3") == 0)
	assert_equal(1, throttle_failures(lt.by_user, c"ada"))
	__sess_mark = db.query_count
	who = authenticate_throttled(db, lt, c"ada", c"pw-ada", c"10.0.0.3")
	sess_check(db, who != 0)
	sess_expect_queries(db, 2)
	User_free(who)
	assert_equal(0, throttle_failures(lt.by_user, c"ada"))
	assert_equal(1, throttle_failures(lt.by_addr, c"10.0.0.3"))

	# Address lockout: one address spraying usernames.
	for i in range(5):
		string_builder* name = string_new()
		string_append(name, c"nobody")
		string_append_int(name, i)
		assert1(authenticate_throttled(db, lt, name.data, c"x", c"10.9.9.9") == 0)
		string_free(name)
	__sess_mark = db.query_count
	assert1(authenticate_throttled(db, lt, c"ada", c"pw-ada", c"10.9.9.9") == 0)
	assert_equal(1, login_throttle_is_locked(db))
	sess_expect_queries(db, 0)
	# ada herself is not locked from elsewhere.
	who = authenticate_throttled(db, lt, c"ada", c"pw-ada", c"10.0.0.4")
	sess_check(db, who != 0)
	User_free(who)
	# An administrator's reset unlocks the address.
	login_throttle_reset(lt, 0, c"10.9.9.9")
	who = authenticate_throttled(db, lt, c"ada", c"pw-ada", c"10.9.9.9")
	sess_check(db, who != 0)
	User_free(who)
	__sess_mark = db.query_count
	# A database error is not counted as a failure.
	sess_check(db, orm_db_exec_sql(db, c"ALTER TABLE auth_user RENAME TO auth_user_gone"))
	__sess_mark = db.query_count
	assert1(authenticate_throttled(db, lt, c"carol", c"x", c"10.1.1.1") == 0)
	assert1(strcmp(orm_db_error(db), AUTH_INVALID_LOGIN()) != 0)
	assert_equal(0, throttle_failures(lt.by_user, c"carol"))
	sess_check(db, orm_db_exec_sql(db, c"ALTER TABLE auth_user_gone RENAME TO auth_user"))
	__sess_mark = db.query_count
	login_throttle_free(lt)


# session.orm's `user` is a cross-file FK to auth's User (H1): an
# anonymous session stores NULL, and deleting the user (through the ORM
# collector or plain SQL) deletes its sessions and tokens.
void sess_case_user_fk(orm_db* db):
	orm_field_desc* fk = orm_model_field(Session_desc(), c"user")
	assert_equal(ORM_FK, fk.kind)
	assert1(orm_field_target(fk) == User_desc())
	assert_equal(ORM_CASCADE, orm_model_field(ApiToken_desc(), c"user").on_delete)
	auth_session* anon = session_create(db, 0)
	sess_check(db, anon != 0)
	assert_equal(1, Session_objects(db).filter(q_and(q_eq_int(c"id", anon.id), q_isnull(c"user", 1))).count())
	User* u = create_user(db, c"fk_user", c"fk@example.com", c"pw")
	sess_check(db, u != 0)
	auth_session* s = session_create(db, u.id)
	sess_check(db, s != 0)
	char* t = token_create(db, u.id, c"fk", 0)
	sess_check(db, t != 0)
	assert_equal(1, Session_objects(db).filter(q_eq_int(c"user", u.id)).count())
	sess_check(db, User_delete(db, u))
	assert_equal(0, Session_objects(db).filter(q_eq_int(c"id", s.id)).count())
	assert_equal(0, ApiToken_objects(db).filter(q_eq_int(c"user", u.id)).count())
	assert_equal(1, Session_objects(db).filter(q_eq_int(c"id", anon.id)).count())
	free(t)
	User_free(u)
	auth_session_free(s)
	auth_session_free(anon)
	__sess_mark = db.query_count


void orm_session_run(orm_db* db):
	auth_register()
	session_register()
	auth_password_set_iterations(1000)
	auth_set_clock(sess_clock)
	__sess_mark = db.query_count
	sess_check(db, sess_create_schema(db))
	__sess_mark = db.query_count
	sess_case_sessions(db)
	sess_case_tokens(db)
	sess_case_csrf()
	sess_case_throttle(db)
	sess_case_user_fk(db)
	auth_set_clock(0)
	auth_password_set_iterations(0)
