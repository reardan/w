# Users and authentication for w-orm (issue #754, unit U3.1;
# docs/projects/orm/u3_1.md). Django's UserManager.create_user /
# create_superuser, User.set_password / check_password and
# ModelBackend.authenticate over the generated auth models
# (libs/standard/orm/auth/auth.orm).
#
#   User* u = create_user(db, c"ada", c"ada@Example.COM", c"s3cret")
#   User_free(u)
#   User* who = authenticate(db, c"ada", c"s3cret")   # 0 when rejected
#   if (who != 0): ... User_free(who)
#
# Every User* returned here is a heap row (User_new) the caller frees with
# User_free; strings this module stores into a row are owned by it.
import libs.standard.orm.auth.auth_orm_api
import libs.standard.orm.auth.password


# The error authenticate() leaves in orm_db_error for a rejected login
# (unknown user, wrong password, inactive user alike, so callers cannot
# leak which one it was).
char* AUTH_INVALID_LOGIN():
	return c"auth: invalid username or password"


# Django's BaseUserManager.normalize_email: the domain part lower-cased.
# Owned copy; 0 stays 0.
char* auth_normalize_email(char* email):
	if (email == 0): return 0
	char* out = strclone(email)
	int at = rindex_of(out, c"@")
	if (at < 0): return out
	int i = at + 1
	while (out[i] != 0):
		out[i] = tolower(out[i])
		i = i + 1
	return out


# A heap copy of a loaded user (column fields only; relation lists empty).
User* auth_user_copy(User* src):
	orm_model_desc* m = User_desc()
	User* u = User_new()
	for orm_field_desc* fd in m.fields: orm_copy_field(m, fd, u, src)
	return u


User* auth_user_from_result(orm_result* r):
	if (r == 0): return 0
	User* u = 0
	if (r.rows.length > 0): u = auth_user_copy(User_rows(r)[0])
	orm_result_free(r)
	return u


# The user with this pk, or 0 (orm_error_is_does_not_exist tells a missing
# user from a database error). One query.
User* user_get(orm_db* db, int id):
	return auth_user_from_result(User_objects(db).get(q_eq_int(c"id", id)))


# The user with exactly this username (case-sensitive, as Django), or 0.
User* user_get_by_username(orm_db* db, char* username):
	if (username == 0):
		orm_db_set_error(db, c"auth: username is required")
		return 0
	return auth_user_from_result(User_objects(db).get(q_eq(c"username", username)))


# Django's User.set_password: hashes raw at the current iteration setting
# (raw 0 = an unusable password). Does not save. Returns 1, 0 when the
# CSPRNG failed.
int set_password(User* u, char* raw):
	char* enc = make_password(raw)
	if (enc == 0): return 0
	u.password = orm_row_own(User_desc(), u, enc)
	return 1


int set_unusable_password(User* u):
	return set_password(u, 0)


int user_has_usable_password(User* u):
	return u.password != 0 && is_password_usable(u.password)


# Django's User.check_password: 1 when raw matches. A matching hash that
# password_needs_rehash() is re-hashed and saved (one UPDATE of password).
int user_check_password(orm_db* db, User* u, char* raw):
	if (check_password(raw, u.password) == 0): return 0
	if (password_needs_rehash(u.password) && u.id != 0 && set_password(u, raw)):
		list[char*] fields = new list[char*]
		fields.push(c"password")
		orm_save_fields(db, User_desc(), u, fields)
		fields.free()
	return 1


int user_is_active(User* u):
	return u != 0 && u.is_active != 0


# Django's ModelBackend.user_can_authenticate: inactive users are rejected.
int user_can_authenticate(User* u):
	return user_is_active(u)


User* auth_user_create(orm_db* db, char* username, char* email, char* password, int staff, int superuser):
	if (username == 0 || username[0] == 0):
		orm_db_set_error(db, c"auth: the given username must be set")
		return 0
	User* u = User_new()
	u.username = orm_row_own(User_desc(), u, strclone(username))
	char* norm = auth_normalize_email(email)
	if (norm != 0): u.email = orm_row_own(User_desc(), u, norm)
	u.is_active = 1
	u.is_staff = staff
	u.is_superuser = superuser
	if (set_password(u, password) == 0):
		User_free(u)
		orm_db_set_error(db, c"auth: could not generate a password salt")
		return 0
	if (User_save(db, u) == 0):
		User_free(u)
		return 0
	return u


# Django's UserManager.create_user: saves an active, non-staff user with a
# hashed password (password 0 = unusable) and a domain-normalized email
# (email 0 = ''). Returns the saved row (User_free), or 0 with orm_db_error
# (a duplicate username fails on the unique constraint).
User* create_user(orm_db* db, char* username, char* email, char* password):
	return auth_user_create(db, username, email, password, 0, 0)


# create_user with is_staff and is_superuser set.
User* create_superuser(orm_db* db, char* username, char* email, char* password):
	return auth_user_create(db, username, email, password, 1, 1)


# Django's authenticate() with the ModelBackend: the active user whose
# password matches, with last_login set to now, or 0. A matching hash that
# needs a rehash is upgraded in the same UPDATE (even for an inactive user,
# as Django does). An unknown username still runs one password hash so its
# timing resembles a wrong password. Rejections leave AUTH_INVALID_LOGIN()
# in orm_db_error; a database failure leaves its own error. Queries: one
# SELECT, plus one UPDATE on success or upgrade.
User* authenticate(orm_db* db, char* username, char* password):
	if (username == 0 || password == 0):
		orm_db_set_error(db, AUTH_INVALID_LOGIN())
		return 0
	User* u = user_get_by_username(db, username)
	if (u == 0):
		if (orm_error_is_does_not_exist(db) == 0): return 0
		char* burn = make_password(password)
		if (burn != 0): free(burn)
		orm_db_set_error(db, AUTH_INVALID_LOGIN())
		return 0
	if (check_password(password, u.password) == 0):
		User_free(u)
		orm_db_set_error(db, AUTH_INVALID_LOGIN())
		return 0
	list[char*] fields = new list[char*]
	if (password_needs_rehash(u.password) && set_password(u, password)): fields.push(c"password")
	int active = user_can_authenticate(u)
	if (active):
		u.last_login = orm_row_own(User_desc(), u, orm_now_text())
		fields.push(c"last_login")
	int saved = 1
	if (fields.length > 0): saved = orm_save_fields(db, User_desc(), u, fields)
	fields.free()
	if (saved == 0 || active == 0):
		User_free(u)
		if (saved): orm_db_set_error(db, AUTH_INVALID_LOGIN())
		return 0
	return u
