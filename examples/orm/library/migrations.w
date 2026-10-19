# The example app's migration list (issue #754, unit U5.2): the auth and
# session tables (libs/standard/orm/auth) and the library tables, each
# app's migrations written by makemigrations.w under migrations/<app>/ and
# applied in this order by the U2.4 applier.
import examples.orm.library.migrations.auth.auth_migrations
import examples.orm.library.migrations.session.session_migrations
import examples.orm.library.migrations.library.library_migrations


void library_app_append(list[orm_migration*] out, list[orm_migration*] part):
	for orm_migration* m in part: out.push(m)
	part.free()


# Every migration of the app, in apply order (a new list of shared
# migration objects).
list[orm_migration*] library_app_migrations():
	list[orm_migration*] ms = new list[orm_migration*]
	library_app_append(ms, auth_migrations())
	library_app_append(ms, session_migrations())
	library_app_append(ms, library_migrations())
	return ms


# Every migration of the other apps plus the first `count` of `app`'s
# (count < 0: all of them), in apply order: what a deploy that has
# shipped only that far applies. library_app_migrations_upto(c"library",
# 1) is release 1 (before the page_count rename).
list[orm_migration*] library_app_migrations_upto(char* app, int count):
	list[orm_migration*] ms = new list[orm_migration*]
	int n = 0
	for orm_migration* m in library_app_migrations():
		if (strcmp(m.app, app) != 0):
			ms.push(m)
			continue
		if (count >= 0 && n >= count): continue
		ms.push(m)
		n = n + 1
	return ms
