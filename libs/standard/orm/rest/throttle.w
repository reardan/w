# w-orm REST throttling (unit U4.1, docs/projects/orm/u4_1.md): DRF's
# AnonRateThrottle / UserRateThrottle as in-memory token buckets.
#
#   orm_throttle* t = orm_throttle_parse(c"100/min")      # 100 per minute, burst 100
#   orm_throttle_burst(t, 10)                             # at most 10 back to back
#   orm_viewset_throttle(vs, t)
#
# Each key (a user id or a client address, chosen by the viewset from the
# throttle's scope) owns a bucket of `burst` tokens refilled at `rate`
# tokens per `period_ms`. A request takes one token; an empty bucket
# answers with the milliseconds until the next token. Levels are kept
# exactly in integers (one token = period_ms units, refilled by `rate`
# units per millisecond). The clock is injectable per throttle (tests).
# State is per process and per throttle object, so a throttle attached
# to one viewset limits that view only.
import lib.lib
import lib.container
import lib.str
import lib.time


const int ORM_THROTTLE_USER = 1   # every request: key = user id, or client address when anonymous
const int ORM_THROTTLE_ANON = 2   # anonymous requests only, keyed by client address

# () -> milliseconds (any origin; only differences are used).
type orm_throttle_clock_fn = fn() -> int


struct orm_bucket:
	int level        # tokens * period_ms
	int stamp        # clock reading of the last refill


struct orm_throttle:
	int scope        # ORM_THROTTLE_*
	int rate         # tokens per period
	int period_ms
	int burst        # bucket capacity in tokens
	int max_keys     # buckets kept before full ones are pruned (default 4096)
	map[char*, orm_bucket*] buckets   # owned buckets (the map copies its keys)
	orm_throttle_clock_fn* clock      # 0 = time_monotonic_ms


# `rate` requests per `period_seconds`, burst = rate, scope USER.
orm_throttle* orm_throttle_new(int rate, int period_seconds):
	orm_throttle* t = new orm_throttle()
	if (rate <= 0): rate = 1
	if (period_seconds <= 0): period_seconds = 1
	t.scope = ORM_THROTTLE_USER
	t.rate = rate
	t.period_ms = period_seconds * 1000
	t.burst = rate
	t.max_keys = 4096
	t.buckets = new map[char*, orm_bucket*]
	return t


# DRF's rate text "N/unit": unit s/sec/second, m/min/minute, h/hour,
# d/day (only the first letter counts, as DRF). 0 for malformed text.
orm_throttle* orm_throttle_parse(char* rate):
	if (rate == 0): return 0
	int slash = index_of(rate, c"/")
	if (slash <= 0): return 0
	char* num = substring(rate, 0, slash)
	int n = 0
	int ok = 1
	for i in range(strlen(num)):
		if (num[i] < '0' || num[i] > '9'): ok = 0
	if (ok): n = atoi(num)
	free(num)
	if (ok == 0 || n <= 0): return 0
	int unit = rate[slash + 1]
	int period = 0
	if (unit == 's'): period = 1
	else if (unit == 'm'): period = 60
	else if (unit == 'h'): period = 3600
	else if (unit == 'd'): period = 86400
	if (period == 0): return 0
	return orm_throttle_new(n, period)


orm_throttle* orm_throttle_burst(orm_throttle* t, int burst):
	if (burst > 0): t.burst = burst
	return t


orm_throttle* orm_throttle_scope(orm_throttle* t, int scope):
	t.scope = scope
	return t


orm_throttle* orm_throttle_set_clock(orm_throttle* t, orm_throttle_clock_fn* clock):
	t.clock = clock
	return t


int orm_throttle_now(orm_throttle* t):
	if (t.clock != 0): return t.clock()
	return time_monotonic_ms()


void orm_throttle_clear(orm_throttle* t):
	for char* k, orm_bucket* b in t.buckets: free(cast(char*, b))
	map_free[char*, orm_bucket*](t.buckets)
	t.buckets = new map[char*, orm_bucket*]


void orm_throttle_free(orm_throttle* t):
	if (t == 0): return
	orm_throttle_clear(t)
	map_free[char*, orm_bucket*](t.buckets)
	free(cast(char*, t))


void orm_throttle_reset(orm_throttle* t, char* key):
	if (key == 0 || (key in t.buckets) == 0): return
	orm_bucket* b = t.buckets[key]
	t.buckets.remove(key)
	free(cast(char*, b))


int orm_throttle_capacity(orm_throttle* t):
	return t.burst * t.period_ms


# Refills b up to now.
void orm_bucket_refill(orm_throttle* t, orm_bucket* b, int now):
	int elapsed = now - b.stamp
	if (elapsed > 0):
		int cap = orm_throttle_capacity(t)
		# Clamp before multiplying so a long idle period cannot overflow.
		if (elapsed > cap): elapsed = cap
		b.level = b.level + elapsed * t.rate
		if (b.level > cap): b.level = cap
	b.stamp = now


# Drops buckets that have refilled completely (they equal a fresh bucket).
void orm_throttle_prune(orm_throttle* t):
	int now = orm_throttle_now(t)
	list[char*] full = new list[char*]
	for char* k, orm_bucket* b in t.buckets:
		orm_bucket_refill(t, b, now)
		if (b.level >= orm_throttle_capacity(t)): full.push(strclone(k))
	for char* k in full:
		orm_throttle_reset(t, k)
		free(k)
	full.free()


# Milliseconds until key's bucket holds one token (0 = now), without
# taking it.
int orm_throttle_wait_ms(orm_throttle* t, char* key):
	orm_bucket* b = t.buckets.get(key, 0)
	if (b == 0): return 0
	orm_bucket_refill(t, b, orm_throttle_now(t))
	if (b.level >= t.period_ms): return 0
	return (t.period_ms - b.level + t.rate - 1) / t.rate


# Takes one token for key. Returns 0 when allowed, else the milliseconds
# to wait (nothing is taken then).
int orm_throttle_take(orm_throttle* t, char* key):
	int now = orm_throttle_now(t)
	orm_bucket* b = t.buckets.get(key, 0)
	if (b == 0):
		if (t.max_keys > 0 && t.buckets.length >= t.max_keys): orm_throttle_prune(t)
		b = new orm_bucket()
		b.level = orm_throttle_capacity(t)
		b.stamp = now
		t.buckets[key] = b
	orm_bucket_refill(t, b, now)
	if (b.level < t.period_ms): return (t.period_ms - b.level + t.rate - 1) / t.rate
	b.level = b.level - t.period_ms
	return 0


# Whole seconds for a Retry-After header (rounded up, at least 1).
int orm_throttle_seconds(int wait_ms):
	int s = (wait_ms + 999) / 1000
	if (s < 1): s = 1
	return s
