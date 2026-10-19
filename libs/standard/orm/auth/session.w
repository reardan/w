# Database sessions for w-orm (issue #754, unit U3.2;
# docs/projects/orm/u3_2.md): Django's SessionBase / db backend with the
# raw key never stored.
#
#   auth_session* s = session_create(db, 0)          # anonymous, one INSERT
#   session_set(s, c"cart", c"3")
#   session_save(db, s)                              # one UPDATE
#   char* hdr = session_cookie_header(s)             # Set-Cookie value
#   ...next request, cookie value `raw`:
#   auth_session* s = session_load(db, raw)          # 0 = missing/expired
#   session_login(db, s, user)                       # rotates the key
#   session_logout(db, s)                            # deletes the row
#   auth_session_free(s)
#
# The cookie carries a 43-character urlsafe token (32 CSPRNG bytes); the
# table holds only its SHA-256 hex digest in session_key, so a leaked
# table cannot be replayed as cookies. session_data is a JSON object of
# string values. Times are Unix seconds from auth_now(), which tests
# replace with auth_set_clock().
import libs.standard.orm.auth.session_orm_api
import libs.standard.orm.auth.user
import libs.standard.crypto.secrets
import libs.standard.web.cookies
import structures.json
import lib.sha256


# ---------------------------------------------------------------------------
# Clock

type auth_clock_fn = fn() -> int

auth_clock_fn* __auth_clock


# Replaces the clock sessions, tokens and throttles read (tests); 0
# restores the real UTC clock.
void auth_set_clock(auth_clock_fn* clock):
	__auth_clock = clock


# Unix seconds now.
int auth_now():
	if (__auth_clock != 0): return __auth_clock()
	return time_now()


# Owned "YYYY-MM-DD HH:MM:SS" UTC text for Unix seconds t.
char* auth_time_text(int t):
	return time_format_unix_utc(t)


int auth_digits(char* s, int at, int n, int* ok):
	int v = 0
	for i in range(n):
		int c = s[at + i]
		if (c < '0' || c > '9'):
			ok[0] = 0
			return 0
		v = v * 10 + (c - '0')
	return v


# Unix seconds of a stored datetime ("YYYY-MM-DD HH:MM:SS" or with 'T';
# a fraction or "+00" suffix is ignored), or -1 when it does not parse.
int auth_parse_time(char* s):
	if (s == 0 || strlen(s) < 19): return -1
	int ok = 1
	date_time dt
	dt.year = auth_digits(s, 0, 4, &ok)
	dt.month = auth_digits(s, 5, 2, &ok)
	dt.day = auth_digits(s, 8, 2, &ok)
	dt.hour = auth_digits(s, 11, 2, &ok)
	dt.minute = auth_digits(s, 14, 2, &ok)
	dt.second = auth_digits(s, 17, 2, &ok)
	if (ok == 0 || s[4] != '-' || s[7] != '-' || s[13] != ':' || s[16] != ':'): return -1
	return time_unix_from_utc(&dt)


# ---------------------------------------------------------------------------
# Token digests

# Owned lower-case hex SHA-256 of raw (64 characters).
char* auth_token_digest(char* raw):
	char* out = cast(char*, malloc(32))
	sha256(raw, strlen(raw), out)
	char* hex = hex_encode(out, 32)
	secrets_wipe(out, 32)
	free(out)
	return hex


# 1 when raw looks like a token this module issued: 20..128 characters of
# [A-Za-z0-9_-]. Anything else is rejected before touching the database.
int auth_token_shape_ok(char* raw):
	if (raw == 0): return 0
	int n = strlen(raw)
	if (n < 20 || n > 128): return 0
	for i in range(n):
		int c = raw[i]
		int good = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_'
		if (good == 0): return 0
	return 1


# ---------------------------------------------------------------------------
# Settings

struct auth_session_settings:
	int max_age          # lifetime in seconds (Django's SESSION_COOKIE_AGE, 2 weeks)
	int refresh_after    # sliding expiry: a load at least this many seconds after the last write extends the expiry (-1 = never)
	char* cookie_name    # "sessionid"
	char* cookie_path    # "/"
	char* cookie_domain  # 0 = host-only
	int secure           # Secure attribute (default 1)
	int http_only        # HttpOnly attribute (default 1)
	char* same_site      # "Lax"


auth_session_settings* __auth_session_settings


# The process-wide session settings; tests and apps change the fields.
auth_session_settings* session_settings():
	if (__auth_session_settings != 0): return __auth_session_settings
	auth_session_settings* st = new auth_session_settings()
	st.max_age = 1209600
	st.refresh_after = 300
	st.cookie_name = c"sessionid"
	st.cookie_path = c"/"
	st.secure = 1
	st.http_only = 1
	st.same_site = c"Lax"
	__auth_session_settings = st
	return st


# ---------------------------------------------------------------------------
# Sessions

struct auth_session:
	int id               # auth_session.id, 0 once flushed
	char* key            # raw token (the cookie value), owned; 0 once flushed
	int user_id          # 0 = anonymous
	int expires_at       # Unix seconds
	map[char*, char*] data   # owned values (the map copies its keys)
	int modified         # data changed since the last write


map[char*, char*] auth_session_data_new():
	return new map[char*, char*]


void auth_session_data_clear(auth_session* s):
	for char* k, char* v in s.data: free(v)
	map_free[char*, char*](s.data)
	s.data = auth_session_data_new()


void auth_session_free(auth_session* s):
	if (s == 0): return
	for char* k, char* v in s.data: free(v)
	map_free[char*, char*](s.data)
	if (s.key != 0): free(s.key)
	free(cast(char*, s))


# The value stored under key (borrowed), or 0.
char* session_get(auth_session* s, char* key):
	return s.data.get(key, 0)


# Stores a copy of value under key (value 0 removes it). Saved by
# session_save.
void session_set(auth_session* s, char* key, char* value):
	if (key in s.data):
		char* old = s.data[key]
		if (value != 0 && strcmp(old, value) == 0): return
		s.data.remove(key)
		free(old)
	else if (value == 0):
		return
	if (value != 0): s.data[key] = strclone(value)
	s.modified = 1


void session_remove(auth_session* s, char* key):
	session_set(s, key, 0)


int session_has(auth_session* s, char* key):
	return key in s.data


# Owned JSON object text of the data map.
char* auth_session_encode(auth_session* s):
	json_value* o = json_object()
	for char* k, char* v in s.data: json_object_set(o, k, json_string(v))
	char* text = json_stringify(o)
	json_free(o)
	return text


# Loads JSON object text into s.data; non-string members are skipped and
# text that does not parse leaves the map empty (Django drops corrupt
# session data the same way).
void auth_session_decode(auth_session* s, char* text):
	if (text == 0): return
	json_value* o = json_parse(text)
	if (o == 0): return
	if (o.type == json_type_object()):
		for char* k, json_value* v in o.object_values:
			if (v.type == json_type_string()): s.data[k] = strclone(v.string_value)
	json_free(o)


auth_session* auth_session_new():
	auth_session* s = new auth_session()
	s.data = auth_session_data_new()
	return s


# A fresh raw key, or 0 when the CSPRNG failed (error set on db).
char* auth_session_new_key(orm_db* db):
	char* raw = secrets_token_urlsafe(32)
	if (raw == 0): orm_db_set_error(db, c"auth: could not generate a session key")
	return raw


# Django's SessionBase.create: a new session row for user_id (0 =
# anonymous) expiring max_age from now. One INSERT. Returns 0 with
# orm_db_error on failure.
auth_session* session_create(orm_db* db, int user_id):
	char* raw = auth_session_new_key(db)
	if (raw == 0): return 0
	auth_session* s = auth_session_new()
	s.key = raw
	s.user_id = user_id
	int now = auth_now()
	s.expires_at = now + session_settings().max_age
	orm_model_desc* m = Session_desc()
	Session* row = Session_new()
	row.session_key = orm_row_own(m, row, auth_token_digest(raw))
	row.user_id = user_id
	row.session_data = orm_row_own(m, row, auth_session_encode(s))
	row.expire_date = orm_row_own(m, row, auth_time_text(s.expires_at))
	row.created = orm_row_own(m, row, auth_time_text(now))
	int ok = Session_save(db, row)
	s.id = row.id
	Session_free(row)
	if (ok == 0):
		auth_session_free(s)
		return 0
	return s


# Writes the given columns of s (session_key, user_id, session_data,
# expire_date as flagged) by id. Returns 1, or 0 with orm_db_error (a row
# that vanished counts as a failure).
int auth_session_write(orm_db* db, auth_session* s, int with_key, int with_user, int with_data, int with_expiry):
	if (s.id == 0):
		orm_db_set_error(db, c"auth: the session was flushed")
		return 0
	list[orm_assignment*] sets = new list[orm_assignment*]
	list[char*] scratch = new list[char*]
	if (with_key):
		char* digest = auth_token_digest(s.key)
		scratch.push(digest)
		sets.push(orm_set_text(c"session_key", digest))
	if (with_user): sets.push(orm_set(c"user_id", val_int(s.user_id)))
	if (with_data):
		char* text = auth_session_encode(s)
		scratch.push(text)
		sets.push(orm_set_text(c"session_data", text))
	if (with_expiry):
		char* when = auth_time_text(s.expires_at)
		scratch.push(when)
		sets.push(orm_set_text(c"expire_date", when))
	int n = Session_objects(db).filter(q_eq_int(c"id", s.id)).update_many(sets)
	sets.free()
	for char* p in scratch: free(p)
	scratch.free()
	if (n < 0): return 0
	if (n == 0):
		orm_db_set_error(db, c"auth: the session no longer exists")
		return 0
	if (with_data): s.modified = 0
	return 1


# Django's SessionStore.load for a cookie value: the live session whose
# key digest matches, or 0 (unknown, malformed or expired key; no error
# for those, a database failure sets orm_db_error). One SELECT, plus one
# UPDATE of expire_date when the sliding refresh is due (at least
# refresh_after seconds since the expiry was last written).
auth_session* session_load(orm_db* db, char* raw):
	orm_clear_error(db)
	if (auth_token_shape_ok(raw) == 0): return 0
	char* digest = auth_token_digest(raw)
	orm_result* r = Session_objects(db).filter(q_eq(c"session_key", digest)).all()
	free(digest)
	if (r == 0): return 0
	if (r.rows.length != 1):
		orm_result_free(r)
		return 0
	Session* row = Session_rows(r)[0]
	int now = auth_now()
	int expires = auth_parse_time(row.expire_date)
	if (expires <= now):
		orm_result_free(r)
		return 0
	auth_session* s = auth_session_new()
	s.id = row.id
	s.key = strclone(raw)
	s.user_id = row.user_id
	s.expires_at = expires
	auth_session_decode(s, row.session_data)
	orm_result_free(r)
	auth_session_settings* st = session_settings()
	if (st.refresh_after >= 0 && now - (expires - st.max_age) >= st.refresh_after):
		s.expires_at = now + st.max_age
		if (auth_session_write(db, s, 0, 0, 0, 1) == 0):
			auth_session_free(s)
			return 0
	return s


# Django's SessionBase.save: writes the data (when modified) and pushes
# the expiry to max_age from now in one UPDATE. Unmodified sessions run
# nothing. Returns 1, or 0 with orm_db_error.
int session_save(orm_db* db, auth_session* s):
	if (s.modified == 0): return 1
	s.expires_at = auth_now() + session_settings().max_age
	return auth_session_write(db, s, 0, 0, 1, 1)


# Django's cycle_key: a new raw key for the same row and data (the old
# cookie stops working). One UPDATE.
int session_rotate(orm_db* db, auth_session* s):
	char* raw = auth_session_new_key(db)
	if (raw == 0): return 0
	char* old = s.key
	s.key = raw
	s.expires_at = auth_now() + session_settings().max_age
	if (auth_session_write(db, s, 1, 0, 1, 1) == 0):
		s.key = old
		free(raw)
		return 0
	if (old != 0): free(old)
	return 1


# Django's SessionBase.flush: deletes the row and empties s (key 0, id 0,
# anonymous). One DELETE (none when already flushed). Send
# session_cookie_delete_header() with the response.
int session_flush(orm_db* db, auth_session* s):
	int ok = 1
	if (s.id != 0): ok = Session_objects(db).filter(q_eq_int(c"id", s.id)).delete() >= 0
	auth_session_data_clear(s)
	if (s.key != 0): free(s.key)
	s.key = 0
	s.id = 0
	s.user_id = 0
	s.modified = 0
	return ok


# The session key under which login() keeps the CSRF secret; login
# drops it so csrf.w issues a new one (Django's rotate_token).
char* AUTH_SESSION_CSRF_KEY():
	return c"_csrftoken"


# Django's auth.login for session s (0 = no session yet): a session that
# belonged to another user is flushed and replaced (one DELETE + one
# INSERT); otherwise the key is rotated and the user id written (one
# UPDATE), keeping anonymous data such as a cart. Either way the CSRF
# secret is dropped. Returns the session to use (s itself, or a new one
# when s was 0 or flushed; free the old one only if it differs), or 0
# with orm_db_error.
auth_session* session_login(orm_db* db, auth_session* s, User* u):
	if (u == 0 || u.id == 0):
		orm_db_set_error(db, c"auth: login needs a saved user")
		return 0
	if (s != 0 && s.id != 0 && s.user_id != 0 && s.user_id != u.id):
		if (session_flush(db, s) == 0): return 0
	if (s == 0 || s.id == 0):
		auth_session* fresh = session_create(db, u.id)
		return fresh
	session_remove(s, AUTH_SESSION_CSRF_KEY())
	char* raw = auth_session_new_key(db)
	if (raw == 0): return 0
	char* old = s.key
	int old_user = s.user_id
	s.key = raw
	s.user_id = u.id
	s.expires_at = auth_now() + session_settings().max_age
	if (auth_session_write(db, s, 1, 1, 1, 1) == 0):
		s.key = old
		s.user_id = old_user
		free(raw)
		return 0
	if (old != 0): free(old)
	return s


# Django's auth.logout: session_flush.
int session_logout(orm_db* db, auth_session* s):
	return session_flush(db, s)


# The logged-in user of s (User_free), or 0 for an anonymous session or
# a user that no longer exists or is inactive. One SELECT when s has a
# user.
User* session_user(orm_db* db, auth_session* s):
	if (s == 0 || s.user_id == 0): return 0
	User* u = user_get(db, s.user_id)
	if (u != 0 && user_is_active(u) == 0):
		User_free(u)
		return 0
	return u


# Deletes every session of user_id (e.g. after a password change).
# Returns the count, -1 on error.
int session_flush_user(orm_db* db, int user_id):
	return Session_objects(db).filter(q_eq_int(c"user_id", user_id)).delete()


# Django's clearsessions: deletes rows whose expiry is at or before now.
# Returns the count, -1 on error.
int session_clear_expired(orm_db* db):
	char* now = auth_time_text(auth_now())
	int n = Session_objects(db).filter(q_lte(c"expire_date", now)).delete()
	free(now)
	return n


# Seconds until s expires (0 when past).
int session_remaining(auth_session* s):
	int left = s.expires_at - auth_now()
	if (left < 0): return 0
	return left


Cookie* auth_session_cookie(char* value, int max_age):
	auth_session_settings* st = session_settings()
	Cookie* c = cookie_new(st.cookie_name, value)
	cookie_set_path(c, st.cookie_path)
	if (st.cookie_domain != 0): cookie_set_domain(c, st.cookie_domain)
	cookie_set_max_age(c, max_age)
	c.secure = st.secure
	c.http_only = st.http_only
	if (st.same_site != 0): cookie_set_same_site(c, st.same_site)
	return c


# Owned Set-Cookie header value for s: "sessionid=<key>; Path=/;
# Max-Age=<remaining>; Secure; HttpOnly; SameSite=Lax" (per the
# settings). 0 for a flushed session.
char* session_cookie_header(auth_session* s):
	if (s == 0 || s.key == 0): return 0
	Cookie* c = auth_session_cookie(s.key, session_remaining(s))
	char* out = cookie_serialize_set_cookie(c)
	cookie_free(c)
	return out


# Owned Set-Cookie value that deletes the session cookie (Max-Age=0).
char* session_cookie_delete_header():
	Cookie* c = auth_session_cookie(c"", 0)
	char* out = cookie_serialize_set_cookie(c)
	cookie_free(c)
	return out


# An owned copy of the session cookie's value in a request Cookie header,
# or 0.
char* session_cookie_value(char* cookie_header):
	if (cookie_header == 0): return 0
	list[Cookie*] cookies = cookie_parse_header(cookie_header)
	char* v = cookie_list_get(cookies, session_settings().cookie_name)
	char* out = 0
	if (v != 0): out = strclone(v)
	cookie_list_free(cookies)
	return out
