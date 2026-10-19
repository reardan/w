# End-to-end auth scenarios (unit U3.1, docs/projects/orm/u3_1.md), shared
# by libs/standard/orm/auth/orm_auth_test.w (SQLite) and
# orm_auth_postgres_test.w. Every database step asserts how many statements
# it ran.
import libs.standard.orm.auth.perms
import tests.orm.fixtures.auth_schema
import tests.orm.fixtures.library_orm
import lib.assert


int __auth_mark


void auth_expect_queries(orm_db* db, int n):
	if (db.query_count - __auth_mark != n):
		print(c"expected queries: ")
		println(itoa(n))
		print(c"got: ")
		println(itoa(db.query_count - __auth_mark))
		print(c"last error: ")
		println(orm_db_error(db))
	assert_equal(n, db.query_count - __auth_mark)
	__auth_mark = db.query_count


void auth_check(orm_db* db, int ok):
	asserts(orm_db_error(db), ok)


# Reads one user straight from the database (not counted).
User* auth_reload(orm_db* db, int id):
	User* u = user_get(db, id)
	auth_check(db, u != 0)
	__auth_mark = db.query_count
	return u


void auth_case_users(orm_db* db):
	orm_set_now(c"2026-10-19 10:00:00")
	User* ada = create_user(db, c"ada", c"Ada.Lovelace@Example.COM", c"s3cret")
	auth_check(db, ada != 0)
	auth_expect_queries(db, 1)
	assert1(ada.id > 0)
	assert_strings_equal(c"ada", ada.username)
	assert_strings_equal(c"Ada.Lovelace@example.com", ada.email)
	assert_strings_equal(c"", ada.first_name)
	assert_strings_equal(c"", ada.last_name)
	assert_equal(1, ada.is_active)
	assert_equal(0, ada.is_staff)
	assert_equal(0, ada.is_superuser)
	assert1(ada.last_login == 0)
	assert1(starts_with_at(ada.date_joined, c"2026-10-19 10:00:00", 0))
	assert1(starts_with_at(ada.password, c"pbkdf2_sha256$1000$", 0))
	assert_equal(1, check_password(c"s3cret", ada.password))
	User* again = auth_reload(db, ada.id)
	assert_strings_equal(ada.password, again.password)
	assert_strings_equal(c"Ada.Lovelace@example.com", again.email)
	assert_equal(1, again.is_active)
	assert1(again.last_login == 0)
	User_free(again)

	# Duplicate usernames fail on the unique constraint.
	User* dup = create_user(db, c"ada", 0, c"x")
	assert1(dup == 0)
	assert1(strlen(orm_db_error(db)) > 0)
	auth_expect_queries(db, 1)
	assert1(create_user(db, c"", 0, c"x") == 0)
	assert_strings_equal(c"auth: the given username must be set", orm_db_error(db))
	auth_expect_queries(db, 0)

	# No email: the database default ''. No password: unusable.
	User* bob = create_user(db, c"bob", 0, 0)
	auth_check(db, bob != 0)
	auth_expect_queries(db, 1)
	assert_strings_equal(c"", bob.email)
	assert_equal(0, user_has_usable_password(bob))
	assert1(authenticate(db, c"bob", c"") == 0)
	auth_expect_queries(db, 1)

	User* root = create_superuser(db, c"root", c"root@example.com", c"toor")
	auth_check(db, root != 0)
	auth_expect_queries(db, 1)
	assert_equal(1, root.is_staff)
	assert_equal(1, root.is_superuser)
	assert_equal(1, root.is_active)

	# authenticate: success sets last_login (one SELECT + one UPDATE).
	orm_set_now(c"2026-10-19 11:30:00")
	User* who = authenticate(db, c"ada", c"s3cret")
	auth_check(db, who != 0)
	auth_expect_queries(db, 2)
	assert_equal(ada.id, who.id)
	assert1(starts_with_at(who.last_login, c"2026-10-19 11:30:00", 0))
	User_free(who)
	User* stored = auth_reload(db, ada.id)
	assert1(starts_with_at(stored.last_login, c"2026-10-19 11:30:00", 0))
	User_free(stored)

	# Rejections: wrong password, unknown user (still hashes), inactive.
	assert1(authenticate(db, c"ada", c"wrong") == 0)
	assert_strings_equal(AUTH_INVALID_LOGIN(), orm_db_error(db))
	auth_expect_queries(db, 1)
	assert1(authenticate(db, c"nobody", c"s3cret") == 0)
	assert_strings_equal(AUTH_INVALID_LOGIN(), orm_db_error(db))
	auth_expect_queries(db, 1)
	assert1(authenticate(db, c"ADA", c"s3cret") == 0)
	auth_expect_queries(db, 1)
	assert1(authenticate(db, 0, c"s3cret") == 0)
	assert1(authenticate(db, c"ada", 0) == 0)
	auth_expect_queries(db, 0)

	bob.is_active = 0
	auth_check(db, set_password(bob, c"pw"))
	auth_check(db, User_save(db, bob))
	auth_expect_queries(db, 1)
	assert1(authenticate(db, c"bob", c"pw") == 0)
	assert_strings_equal(AUTH_INVALID_LOGIN(), orm_db_error(db))
	auth_expect_queries(db, 1)
	assert_equal(0, user_can_authenticate(bob))

	# Raising the iteration setting upgrades the hash on the next login,
	# in the same UPDATE as last_login.
	auth_password_set_iterations(1500)
	who = authenticate(db, c"ada", c"s3cret")
	auth_check(db, who != 0)
	auth_expect_queries(db, 2)
	assert1(starts_with_at(who.password, c"pbkdf2_sha256$1500$", 0))
	User_free(who)
	stored = auth_reload(db, ada.id)
	assert1(starts_with_at(stored.password, c"pbkdf2_sha256$1500$", 0))
	assert_equal(1, check_password(c"s3cret", stored.password))
	assert_equal(0, password_needs_rehash(stored.password))
	User_free(stored)
	# No upgrade needed now: still two statements (SELECT + last_login).
	who = authenticate(db, c"ada", c"s3cret")
	auth_check(db, who != 0)
	auth_expect_queries(db, 2)
	User_free(who)

	# An inactive user's stale hash is still upgraded (Django's setter
	# runs before the is_active check), but the login is refused.
	auth_password_set_iterations(1600)
	assert1(authenticate(db, c"bob", c"pw") == 0)
	auth_expect_queries(db, 2)
	stored = auth_reload(db, bob.id)
	assert1(starts_with_at(stored.password, c"pbkdf2_sha256$1600$", 0))
	User_free(stored)

	# user_check_password upgrades too.
	auth_password_set_iterations(1700)
	stored = auth_reload(db, ada.id)
	assert_equal(0, user_check_password(db, stored, c"nope"))
	auth_expect_queries(db, 0)
	assert_equal(1, user_check_password(db, stored, c"s3cret"))
	auth_expect_queries(db, 1)
	User_free(stored)
	stored = auth_reload(db, ada.id)
	assert1(starts_with_at(stored.password, c"pbkdf2_sha256$1700$", 0))
	User_free(stored)
	auth_password_set_iterations(1000)

	User_free(ada)
	User_free(bob)
	User_free(root)


# A row written by Django (its hash format, short legacy salt) logs in and
# is upgraded to a W hash with a full-length salt.
void auth_case_django_row(orm_db* db):
	auth_check(db, orm_db_exec_sql(db, c"INSERT INTO auth_user (password, is_superuser, username, first_name, last_name, email, is_staff, is_active, date_joined) VALUES ('pbkdf2_sha256$1000$seasalt$JgZryXe2Ga8ysg6XbzkLpTdyPQrHqsinbL9BnnhgX4A=', FALSE, 'django', 'Dj', 'Ango', 'dj@example.com', TRUE, TRUE, '2020-01-01 00:00:00')"))
	auth_expect_queries(db, 1)
	User* u = authenticate(db, c"django", c"l\xc3\xa8tmein")
	auth_check(db, u != 0)
	auth_expect_queries(db, 2)
	assert_strings_equal(c"Dj", u.first_name)
	assert_equal(1, u.is_staff)
	auth_password_parts* p = auth_password_decode(u.password)
	assert_equal(1000, p.iterations)
	assert_equal(22, strlen(p.salt))
	auth_password_parts_free(p)
	User_free(u)


int auth_count(orm_db* db, orm_queryset* qs):
	int n = qs.count()
	__auth_mark = db.query_count
	return n


void auth_case_model_permissions(orm_db* db):
	assert_strings_equal(c"content type", auth_verbose_name(c"ContentType"))
	assert_strings_equal(c"http log", auth_verbose_name(c"HTTPLog"))
	assert_strings_equal(c"book", auth_verbose_name(c"Book"))
	assert_strings_equal(c"library", orm_auth_model_app_label(Book_desc()))
	assert_strings_equal(c"auth", orm_auth_model_app_label(User_desc()))
	assert1(orm_auth_model_app_label(ContentType_desc()) == 0)

	assert_equal(16, orm_auth_create_auth_permissions(db))
	auth_expect_queries(db, 12)
	assert_equal(0, orm_auth_create_auth_permissions(db))
	auth_expect_queries(db, 8)
	assert_equal(4, auth_count(db, ContentType_objects(db)))
	assert_equal(16, auth_count(db, Permission_objects(db)))

	assert_equal(4, orm_auth_create_model_permissions(db, Book_desc()))
	auth_expect_queries(db, 3)
	assert_equal(4, orm_auth_create_model_permissions(db, Author_desc()))
	auth_expect_queries(db, 3)
	assert_equal(-1, orm_auth_create_model_permissions(db, ContentType_desc()))
	auth_expect_queries(db, 0)

	Permission* p = permission_get(db, c"library.change_book")
	auth_check(db, p != 0)
	auth_expect_queries(db, 1)
	assert_strings_equal(c"Can change book", p.name)
	assert_strings_equal(c"change_book", p.codename)
	Permission_free(p)
	p = permission_get(db, c"contenttypes.view_contenttype")
	auth_check(db, p != 0)
	assert_strings_equal(c"Can view content type", p.name)
	Permission_free(p)
	assert1(permission_get(db, c"library.fly_book") == 0)
	assert_equal(1, orm_error_is_does_not_exist(db))
	assert1(permission_get(db, c"nodot") == 0)
	auth_expect_queries(db, 2)


int __auth_hook_calls


# Grants change_book on the object whose address is the magic value 1001,
# denies everything on 1002, abstains otherwise.
int auth_test_hook(orm_db* db, void* user, char* perm, orm_model_desc* m, void* obj):
	__auth_hook_calls = __auth_hook_calls + 1
	User* u = cast(User*, user)
	if (strcmp(m.name, c"Book") != 0 || u.id == 0): return 0
	if (cast(int, obj) == 1001 && strcmp(perm, c"library.change_book") == 0): return 1
	if (cast(int, obj) == 1002): return -1
	return 0


int auth_test_hook_grant_all(orm_db* db, void* user, char* perm, orm_model_desc* m, void* obj):
	__auth_hook_calls = __auth_hook_calls + 1
	return 1


void auth_case_perms(orm_db* db):
	User* eve = create_user(db, c"eve", c"eve@example.com", c"pw")
	auth_check(db, eve != 0)
	User* root = user_get_by_username(db, c"root")
	auth_check(db, root != 0)
	User* bob = user_get_by_username(db, c"bob")
	auth_check(db, bob != 0)
	__auth_mark = db.query_count
	auth_perm_cache_clear()

	# No permissions yet: the first check loads (2 queries), the next are cached.
	assert_equal(0, user_has_perm(db, eve, c"library.change_book"))
	auth_expect_queries(db, 2)
	assert_equal(0, user_has_perm(db, eve, c"library.add_book"))
	assert_equal(0, user_has_module_perms(db, eve, c"library"))
	auth_expect_queries(db, 0)

	Permission* change_book = permission_get(db, c"library.change_book")
	Permission* view_book = permission_get(db, c"library.view_book")
	Permission* add_author = permission_get(db, c"library.add_author")
	auth_check(db, change_book != 0 && view_book != 0 && add_author != 0)
	__auth_mark = db.query_count

	# Direct user permission.
	assert_equal(1, user_add_permission(db, eve, change_book))
	auth_expect_queries(db, 1)
	assert_equal(0, user_add_permission(db, eve, change_book))
	auth_expect_queries(db, 1)
	assert_equal(1, user_has_perm(db, eve, c"library.change_book"))
	auth_expect_queries(db, 2)
	assert_equal(0, user_has_perm(db, eve, c"library.view_book"))
	assert_equal(1, user_has_module_perms(db, eve, c"library"))
	assert_equal(0, user_has_module_perms(db, eve, c"lib"))
	assert_equal(0, user_has_module_perms(db, eve, c"auth"))
	auth_expect_queries(db, 0)

	# Group permission.
	Group* editors = group_get_or_create(db, c"editors")
	auth_check(db, editors != 0)
	auth_expect_queries(db, 2)
	Group* same = group_get_or_create(db, c"editors")
	auth_check(db, same != 0)
	auth_expect_queries(db, 1)
	assert_equal(editors.id, same.id)
	Group_free(same)
	assert_equal(1, group_add_permission(db, editors, view_book))
	assert_equal(1, group_add_permission(db, editors, change_book))
	auth_expect_queries(db, 2)
	assert_equal(0, user_has_perm(db, eve, c"library.view_book"))
	auth_expect_queries(db, 2)
	assert_equal(1, user_add_group(db, eve, editors))
	auth_expect_queries(db, 1)
	assert_equal(1, user_has_perm(db, eve, c"library.view_book"))
	auth_expect_queries(db, 2)
	list[char*] want = new list[char*]
	want.push(c"library.view_book")
	want.push(c"library.change_book")
	assert_equal(1, user_has_perms(db, eve, want))
	want.push(c"library.add_author")
	assert_equal(0, user_has_perms(db, eve, want))
	assert_equal(1, user_has_perms(db, eve, new list[char*]))
	auth_expect_queries(db, 0)

	list[char*] all = user_get_all_permissions(db, eve)
	auth_expect_queries(db, 0)
	assert_equal(2, all.length)
	assert_strings_equal(c"library.change_book", all[0])
	assert_strings_equal(c"library.view_book", all[1])
	auth_perm_list_free(all)

	# A group permission change reaches members (whole cache invalidated).
	assert_equal(1, group_add_permission(db, editors, add_author))
	auth_expect_queries(db, 1)
	assert_equal(1, user_has_perm(db, eve, c"library.add_author"))
	auth_expect_queries(db, 2)
	assert_equal(1, group_remove_permission(db, editors, add_author))
	assert_equal(0, user_has_perm(db, eve, c"library.add_author"))
	auth_expect_queries(db, 3)

	# Removing the direct permission keeps the group grant.
	assert_equal(1, user_remove_permission(db, eve, change_book))
	assert_equal(1, user_has_perm(db, eve, c"library.change_book"))
	auth_expect_queries(db, 3)
	assert_equal(1, user_remove_group(db, eve, editors))
	assert_equal(0, user_has_perm(db, eve, c"library.change_book"))
	assert_equal(0, user_has_perm(db, eve, c"library.view_book"))
	auth_expect_queries(db, 3)
	assert_equal(1, user_add_group(db, eve, editors))
	auth_expect_queries(db, 1)

	# Inactive users have nothing (no query); superusers everything.
	eve.is_active = 0
	assert_equal(0, user_has_perm(db, eve, c"library.view_book"))
	assert_equal(0, user_has_module_perms(db, eve, c"library"))
	list[char*] none = user_get_all_permissions(db, eve)
	assert_equal(0, none.length)
	auth_perm_list_free(none)
	auth_expect_queries(db, 0)
	eve.is_active = 1
	assert_equal(1, user_has_perm(db, root, c"anything.at_all"))
	assert_equal(1, user_has_module_perms(db, root, c"whatever"))
	auth_expect_queries(db, 0)
	list[char*] every = user_get_all_permissions(db, root)
	auth_expect_queries(db, 1)
	assert_equal(24, every.length)
	auth_perm_list_free(every)
	# Promoting a user is seen without explicit invalidation.
	eve.is_superuser = 1
	list[char*] promoted = user_get_all_permissions(db, eve)
	auth_expect_queries(db, 1)
	assert_equal(24, promoted.length)
	auth_perm_list_free(promoted)
	eve.is_superuser = 0
	assert_equal(0, user_has_perm(db, eve, c"library.add_author"))
	auth_expect_queries(db, 2)

	# Object permissions: only hooks decide (model permissions do not imply
	# object permissions); superusers bypass hooks; obj 0 = model check.
	__auth_hook_calls = 0
	assert_equal(0, user_has_obj_perm(db, eve, c"library.change_book", Book_desc(), cast(void*, 1001)))
	auth_register_object_permission(auth_test_hook)
	assert_equal(1, user_has_obj_perm(db, eve, c"library.change_book", Book_desc(), cast(void*, 1001)))
	assert_equal(0, user_has_obj_perm(db, eve, c"library.delete_book", Book_desc(), cast(void*, 1001)))
	assert_equal(0, user_has_obj_perm(db, eve, c"library.change_book", Book_desc(), cast(void*, 1003)))
	assert_equal(3, __auth_hook_calls)
	auth_register_object_permission(auth_test_hook_grant_all)
	assert_equal(1, user_has_obj_perm(db, eve, c"library.delete_book", Book_desc(), cast(void*, 1001)))
	assert_equal(0, user_has_obj_perm(db, eve, c"library.delete_book", Book_desc(), cast(void*, 1002)))
	assert_equal(6, __auth_hook_calls)
	assert_equal(1, user_has_obj_perm(db, root, c"library.delete_book", Book_desc(), cast(void*, 1002)))
	assert_equal(6, __auth_hook_calls)
	eve.is_active = 0
	assert_equal(0, user_has_obj_perm(db, eve, c"library.change_book", Book_desc(), cast(void*, 1001)))
	assert_equal(6, __auth_hook_calls)
	eve.is_active = 1
	assert_equal(1, user_has_obj_perm(db, eve, c"library.change_book", Book_desc(), 0))
	auth_expect_queries(db, 0)
	auth_clear_object_permissions()
	assert_equal(0, user_has_obj_perm(db, eve, c"library.change_book", Book_desc(), cast(void*, 1001)))

	# Explicit invalidation reloads one user's entry.
	assert1(auth_perm_cache_size() > 0)
	auth_perm_cache_invalidate_user(eve.id)
	assert_equal(1, user_has_perm(db, eve, c"library.view_book"))
	auth_expect_queries(db, 2)
	assert_equal(0, user_has_perm(db, bob, c"library.view_book"))
	auth_expect_queries(db, 0)

	# Deleting a user cascades its links.
	assert_equal(1, User_delete(db, eve))
	auth_expect_queries(db, 1)

	Permission_free(change_book)
	Permission_free(view_book)
	Permission_free(add_author)
	Group_free(editors)
	User_free(eve)
	User_free(root)
	User_free(bob)


void orm_auth_run(orm_db* db):
	auth_register()
	library_register()
	auth_password_set_iterations(1000)
	__auth_mark = db.query_count
	auth_check(db, auth_create_schema(db))
	__auth_mark = db.query_count
	auth_case_users(db)
	auth_case_django_row(db)
	auth_case_model_permissions(db)
	auth_case_perms(db)
	auth_password_set_iterations(0)
	orm_set_now(0)
