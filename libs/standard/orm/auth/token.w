# Named API tokens for w-orm (issue #754, unit U3.2;
# docs/projects/orm/u3_2.md), after django-rest-knox rather than DRF's one
# plain token per user: a user has any number of tokens, each with a
# unique name per user, an optional expiry and a last_used time.
#
#   char* raw = token_create(db, u.id, c"ci", 86400 * 30)   # shown once
#   User* who = authenticate_token(db, raw)                  # 0 = rejected
#   token_revoke(db, u.id, c"ci")
#
# A raw token is 43 urlsafe characters (32 CSPRNG bytes). The table keeps
# its first 8 characters in token_key (indexed, the lookup prefix that may
# be shown in a UI) and the SHA-256 hex of the whole token in digest;
# candidates sharing the prefix are compared with secrets_compare_digest.
# Session and clock helpers come from session.w.
import libs.standard.orm.auth.session


const int AUTH_TOKEN_KEY_LENGTH = 8


# The error authenticate_token leaves for an unknown, malformed, revoked
# or expired token, or a token whose user is gone or inactive.
char* AUTH_INVALID_TOKEN():
	return c"auth: invalid token"


int __auth_token_touch_interval
int __auth_token_touch_interval_set


# last_used is rewritten only when it is at least this many seconds old
# (default 60, knox's MIN_REFRESH_INTERVAL idea), so a busy client does
# not write on every request. 0 = on every use.
void token_set_touch_interval(int seconds):
	__auth_token_touch_interval = seconds
	__auth_token_touch_interval_set = 1


int token_touch_interval():
	if (__auth_token_touch_interval_set == 0): return 60
	return __auth_token_touch_interval


# The lookup prefix of a raw token (owned), or 0 when it is too short.
char* token_prefix(char* raw):
	if (raw == 0 || strlen(raw) < AUTH_TOKEN_KEY_LENGTH): return 0
	return str_copy_range(raw, 0, AUTH_TOKEN_KEY_LENGTH)


# Creates token `name` for user_id, expiring ttl seconds from now (ttl <= 0
# = never). One INSERT. Returns the raw token (owned; it cannot be
# recovered later), or 0 with orm_db_error (a duplicate name per user
# fails on the unique constraint). When row_out is not 0 it receives the
# saved row (ApiToken_free).
char* token_create_row(orm_db* db, int user_id, char* name, int ttl, ApiToken** row_out):
	if (row_out != 0): row_out[0] = 0
	if (user_id == 0 || name == 0 || name[0] == 0):
		orm_db_set_error(db, c"auth: a token needs a user and a name")
		return 0
	char* raw = secrets_token_urlsafe(32)
	if (raw == 0):
		orm_db_set_error(db, c"auth: could not generate a token")
		return 0
	orm_model_desc* m = ApiToken_desc()
	ApiToken* row = ApiToken_new()
	int now = auth_now()
	row.user_id = user_id
	row.name = orm_row_own(m, row, strclone(name))
	row.token_key = orm_row_own(m, row, token_prefix(raw))
	row.digest = orm_row_own(m, row, auth_token_digest(raw))
	row.created = orm_row_own(m, row, auth_time_text(now))
	if (ttl > 0): row.expiry = orm_row_own(m, row, auth_time_text(now + ttl))
	if (ApiToken_save(db, row) == 0):
		ApiToken_free(row)
		secrets_wipe(raw, strlen(raw))
		free(raw)
		return 0
	if (row_out != 0): row_out[0] = row
	else: ApiToken_free(row)
	return raw


char* token_create(orm_db* db, int user_id, char* name, int ttl):
	return token_create_row(db, user_id, name, ttl, 0)


# 1 when row has an expiry at or before now.
int token_is_expired(ApiToken* row, int now):
	if (row.expiry == 0): return 0
	int t = auth_parse_time(row.expiry)
	return t < 0 || t <= now


# The live token row matching raw (a heap copy, ApiToken_free), or 0 with
# AUTH_INVALID_TOKEN() / a database error. One SELECT by prefix.
ApiToken* token_lookup(orm_db* db, char* raw):
	orm_clear_error(db)
	if (auth_token_shape_ok(raw) == 0):
		orm_db_set_error(db, AUTH_INVALID_TOKEN())
		return 0
	char* prefix = token_prefix(raw)
	orm_result* r = ApiToken_objects(db).filter(q_eq(c"token_key", prefix)).all()
	free(prefix)
	if (r == 0): return 0
	char* digest = auth_token_digest(raw)
	int now = auth_now()
	ApiToken* found = 0
	for ApiToken* row in ApiToken_rows(r):
		# Compare every candidate so the time does not say which matched.
		int same = secrets_compare_digest_str(row.digest, digest)
		if (same && found == 0 && token_is_expired(row, now) == 0):
			orm_model_desc* m = ApiToken_desc()
			found = ApiToken_new()
			for orm_field_desc* fd in m.fields: orm_copy_field(m, fd, found, row)
	free(digest)
	orm_result_free(r)
	if (found == 0): orm_db_set_error(db, AUTH_INVALID_TOKEN())
	return found


# DRF/knox TokenAuthentication: the active user owning raw, or 0 with
# AUTH_INVALID_TOKEN() (or a database error). Queries: one SELECT of the
# token, one UPDATE of last_used when it is older than
# token_touch_interval(), one SELECT of the user.
User* authenticate_token(orm_db* db, char* raw):
	ApiToken* tok = token_lookup(db, raw)
	if (tok == 0): return 0
	int now = auth_now()
	int last = -1
	if (tok.last_used != 0): last = auth_parse_time(tok.last_used)
	if (last < 0 || now - last >= token_touch_interval()):
		char* when = auth_time_text(now)
		int n = ApiToken_objects(db).filter(q_eq_int(c"id", tok.id)).update(c"last_used", val(when))
		free(when)
		if (n < 0):
			ApiToken_free(tok)
			return 0
	int user_id = tok.user_id
	ApiToken_free(tok)
	User* u = user_get(db, user_id)
	if (u == 0):
		if (orm_error_is_does_not_exist(db)): orm_db_set_error(db, AUTH_INVALID_TOKEN())
		return 0
	if (user_is_active(u) == 0):
		User_free(u)
		orm_db_set_error(db, AUTH_INVALID_TOKEN())
		return 0
	return u


# The tokens of user_id ordered by name (a result of ApiToken rows; free
# with orm_result_free). One SELECT.
orm_result* token_list(orm_db* db, int user_id):
	return ApiToken_objects(db).filter(q_eq_int(c"user", user_id)).order_by(c"name").all()


# Deletes user_id's token `name`. Returns the count (0 or 1), -1 on error.
int token_revoke(orm_db* db, int user_id, char* name):
	return ApiToken_objects(db).filter(q_and(q_eq_int(c"user", user_id), q_eq(c"name", name))).delete()


# Deletes the token raw identifies (knox's logout). Returns the count,
# -1 on error. One SELECT + one DELETE.
int token_revoke_raw(orm_db* db, char* raw):
	ApiToken* tok = token_lookup(db, raw)
	if (tok == 0):
		if (strcmp(orm_db_error(db), AUTH_INVALID_TOKEN()) == 0): return 0
		return -1
	int n = ApiToken_objects(db).filter(q_eq_int(c"id", tok.id)).delete()
	ApiToken_free(tok)
	return n


# Deletes every token of user_id (knox's logoutall). Count, -1 on error.
int token_revoke_all(orm_db* db, int user_id):
	return ApiToken_objects(db).filter(q_eq_int(c"user", user_id)).delete()


# Deletes tokens whose expiry is at or before now. Count, -1 on error.
int token_clear_expired(orm_db* db):
	char* now = auth_time_text(auth_now())
	int n = ApiToken_objects(db).filter(q_lte(c"expiry", now)).delete()
	free(now)
	return n
