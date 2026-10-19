# Login attempt limiting for w-orm (issue #754, unit U3.2;
# docs/projects/orm/u3_2.md): what django-axes does, in memory.
#
#   auth_login_throttle* t = login_throttle_new(5, 20, 900)
#   User* u = authenticate_throttled(db, t, username, password, client_ip)
#   if (u == 0 && login_throttle_is_locked(db)): ...429, retry later
#
# Fixed windows per key: the first failure opens a window of `window`
# seconds; once `limit` failures fall inside it the key is locked until
# the window ends, and then counting starts over. Keys are kept per
# username and per client address, each with its own limit, so one
# address cannot spray many usernames and many addresses cannot hammer
# one username. A success clears the username's counter (not the
# address's, so a valid account cannot launder an address's failures).
# The state is per process; the clock is session.w's auth_now(), which
# tests replace with auth_set_clock().
import libs.standard.orm.auth.session


struct auth_throttle_entry:
	int count
	int window_start


struct auth_throttle:
	int limit            # failures per window before lockout (<= 0 = no limit)
	int window           # seconds
	map[char*, auth_throttle_entry*] entries   # owned entries (the map copies its keys)


auth_throttle* throttle_new(int limit, int window):
	auth_throttle* t = new auth_throttle()
	t.limit = limit
	t.window = window
	t.entries = new map[char*, auth_throttle_entry*]
	return t


void throttle_clear(auth_throttle* t):
	for char* k, auth_throttle_entry* e in t.entries: free(cast(char*, e))
	map_free[char*, auth_throttle_entry*](t.entries)
	t.entries = new map[char*, auth_throttle_entry*]


void throttle_free(auth_throttle* t):
	if (t == 0): return
	throttle_clear(t)
	map_free[char*, auth_throttle_entry*](t.entries)
	free(cast(char*, t))


# The live entry for key (its window not over), or 0.
auth_throttle_entry* throttle_entry(auth_throttle* t, char* key, int now):
	auth_throttle_entry* e = t.entries.get(key, 0)
	if (e == 0): return 0
	if (now - e.window_start >= t.window): return 0
	return e


# Removes key's entry (a success, or an administrator's reset).
void throttle_reset(auth_throttle* t, char* key):
	if (key == 0 || (key in t.entries) == 0): return
	auth_throttle_entry* e = t.entries[key]
	t.entries.remove(key)
	free(cast(char*, e))


# Drops every entry whose window is over (bounds memory).
void throttle_prune(auth_throttle* t):
	int now = auth_now()
	list[char*] dead = new list[char*]
	for char* k, auth_throttle_entry* e in t.entries:
		if (now - e.window_start >= t.window): dead.push(strclone(k))
	for char* k in dead:
		throttle_reset(t, k)
		free(k)
	dead.free()


# 1 when key may try again now.
int throttle_allowed(auth_throttle* t, char* key):
	if (t == 0 || key == 0 || t.limit <= 0): return 1
	auth_throttle_entry* e = throttle_entry(t, key, auth_now())
	return e == 0 || e.count < t.limit


# Failures recorded for key in its current window.
int throttle_failures(auth_throttle* t, char* key):
	if (t == 0 || key == 0): return 0
	auth_throttle_entry* e = throttle_entry(t, key, auth_now())
	if (e == 0): return 0
	return e.count


# Seconds until key may try again (0 = now).
int throttle_retry_after(auth_throttle* t, char* key):
	if (throttle_allowed(t, key)): return 0
	auth_throttle_entry* e = t.entries[key]
	return e.window_start + t.window - auth_now()


# Records one failure for key. Returns the count in the current window.
int throttle_fail(auth_throttle* t, char* key):
	if (t == 0 || key == 0): return 0
	int now = auth_now()
	auth_throttle_entry* e = t.entries.get(key, 0)
	if (e == 0):
		if (t.entries.length >= 4096): throttle_prune(t)
		e = new auth_throttle_entry()
		e.window_start = now
		t.entries[key] = e
	else if (now - e.window_start >= t.window):
		e.count = 0
		e.window_start = now
	e.count = e.count + 1
	return e.count


# ---------------------------------------------------------------------------
# Login

struct auth_login_throttle:
	auth_throttle* by_user
	auth_throttle* by_addr


# user_limit failures per username and addr_limit per client address
# within `window` seconds (django-axes' FAILURE_LIMIT / COOLOFF_TIME).
auth_login_throttle* login_throttle_new(int user_limit, int addr_limit, int window):
	auth_login_throttle* t = new auth_login_throttle()
	t.by_user = throttle_new(user_limit, window)
	t.by_addr = throttle_new(addr_limit, window)
	return t


void login_throttle_free(auth_login_throttle* t):
	if (t == 0): return
	throttle_free(t.by_user)
	throttle_free(t.by_addr)
	free(cast(char*, t))


# The error authenticate_throttled leaves when a key is locked out.
char* AUTH_THROTTLED():
	return c"auth: too many failed login attempts"


int login_throttle_is_locked(orm_db* db):
	return strcmp(orm_db_error(db), AUTH_THROTTLED()) == 0


# 1 when neither username nor addr (either may be 0) is locked out.
int login_throttle_allowed(auth_login_throttle* t, char* username, char* addr):
	return throttle_allowed(t.by_user, username) && throttle_allowed(t.by_addr, addr)


# Seconds until both keys may try again.
int login_throttle_retry_after(auth_login_throttle* t, char* username, char* addr):
	int a = throttle_retry_after(t.by_user, username)
	int b = throttle_retry_after(t.by_addr, addr)
	if (b > a): return b
	return a


# Clears both counters (an administrator's unlock).
void login_throttle_reset(auth_login_throttle* t, char* username, char* addr):
	throttle_reset(t.by_user, username)
	throttle_reset(t.by_addr, addr)


# U3.1's authenticate behind the throttle. A locked username or address
# is refused with AUTH_THROTTLED() before any query or hash. A rejected
# login (AUTH_INVALID_LOGIN, not a database error) counts one failure for
# each key; a success clears the username's counter. Queries are
# authenticate's.
User* authenticate_throttled(orm_db* db, auth_login_throttle* t, char* username, char* password, char* addr):
	if (login_throttle_allowed(t, username, addr) == 0):
		orm_db_set_error(db, AUTH_THROTTLED())
		return 0
	User* u = authenticate(db, username, password)
	if (u != 0):
		throttle_reset(t.by_user, username)
		return u
	if (strcmp(orm_db_error(db), AUTH_INVALID_LOGIN()) == 0):
		throttle_fail(t.by_user, username)
		throttle_fail(t.by_addr, addr)
	return 0
