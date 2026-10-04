/*
Instance-owned clocks: a status-checked reading interface with a real
(clock_gettime) implementation and a virtual one for deterministic
tests (docs/projects/simulation.md, issue #514 stage W4).

A reading returns an IO_* status (lib/io.w) and writes the value through
an out pointer, so a failed read can never be mistaken for a time:

	wtime now
	if (wclock_monotonic(c, &now) != IO_OK): ...

Two time lines are kept apart on purpose:

- monotonic: seconds since an arbitrary origin (boot for the real
  clock, 0 for a fresh virtual clock). Never goes backwards. Use it for
  every duration, timeout and deadline.
- wall: seconds since the Unix epoch (CLOCK_REALTIME). It can jump
  forwards or backwards at any time (NTP steps, an operator, a VM
  resume), independently of monotonic time. Use it only for labels that
  leave the process (log stamps, file metadata) - never for deadlines.

Units. wtime {sec, nsec} is the portable full-range reading: two words,
nsec normalized to 0..999999999. On 32-bit x86 sec is a 32-bit word,
which covers ~68 years of monotonic uptime; real wall seconds overflow
it in 2038 (the i386 clock_gettime ABI has a 32-bit time_t;
clock_gettime64 is the future fix, as for lib/time.w's time_now).

Scalar conveniences:
- wclock_monotonic_ns / wclock_wall_ms / wclock_wall_ns return the value
  as one word when it fits the target's int (always for realistic values
  on 64-bit targets, where int is 64 bits) and IO_UNSUPPORTED when it
  does not (on 32-bit x86 a nanosecond count overflows after ~2.1 s and
  epoch milliseconds never fit) - never a silently truncated value.
- wclock_monotonic_ms keeps lib/time.w's time_monotonic_ms contract
  exactly: sec * 1000 + nsec / 1000000 computed in word arithmetic,
  which WRAPS a 32-bit int after ~24.8 days on x86. Such values are
  serial numbers: compare them only through differences (b - a), as
  libs/standard/distributed/monotime.w and lib/event_loop.w do; a raw
  `<` is wrong near the wrap point.

Clocks are plain heap objects passed to whoever needs them (an event
loop, a simulated node); there is no process-global hook, so workers on
different threads never share mutable clock state by accident. A virtual
clock is not internally synchronized: one owner advances it.

Hybrid logical clocks (libs/standard/distributed/clock.w) encode
causality on top of a wall reading; they do not bound physical clock
uncertainty, and nothing here does either.
*/
import lib.lib
import lib.assert
import lib.io


const int WCLOCK_MONOTONIC = 1
const int WCLOCK_WALL = 2

const int WCLOCK_NS_PER_SEC = 1000000000

# Kernel clock ids (Linux, every arch).
const int WCLOCK_ID_REALTIME = 0
const int WCLOCK_ID_MONOTONIC = 1


struct wtime:
	int sec     # seconds; 32-bit on x86 (see header)
	int nsec    # 0..999999999


# self, WCLOCK_MONOTONIC or WCLOCK_WALL, out -> IO_* status. The value
# in out is only meaningful when the status is IO_OK.
type wclock_read_fn = fn(void*, int, wtime*) -> int


struct wclock:
	wclock_read_fn* read
	void* self              # passed to read; the clock itself for the built-ins
	int is_virtual
	# virtual clock state (unused by the real clock)
	int mono_sec
	int mono_nsec
	int wall_sec
	int wall_nsec
	int mono_fail           # IO_* status forced on monotonic reads; IO_OK = none
	int wall_fail
	int reads               # readings served (both time lines), for tests


/* wtime arithmetic. */

void wtime_set(wtime* t, int sec, int nsec):
	t.sec = sec
	t.nsec = nsec


# Brings nsec into 0..999999999 after an add of at most a second either way.
void wtime_normalize(wtime* t):
	while (t.nsec >= WCLOCK_NS_PER_SEC):
		t.nsec = t.nsec - WCLOCK_NS_PER_SEC
		t.sec = t.sec + 1
	while (t.nsec < 0):
		t.nsec = t.nsec + WCLOCK_NS_PER_SEC
		t.sec = t.sec - 1


# t += ms (either sign).
void wtime_add_ms(wtime* t, int ms):
	t.sec = t.sec + ms / 1000
	t.nsec = t.nsec + (ms % 1000) * 1000000
	wtime_normalize(t)


# t += ns (either sign; |ns| is bounded by the target's int).
void wtime_add_ns(wtime* t, int ns):
	t.sec = t.sec + ns / WCLOCK_NS_PER_SEC
	t.nsec = t.nsec + ns % WCLOCK_NS_PER_SEC
	wtime_normalize(t)


# -1, 0 or 1 as a is before, equal to or after b.
int wtime_compare(wtime* a, wtime* b):
	if (a.sec != b.sec):
		if (a.sec < b.sec): return -1
		return 1
	if (a.nsec < b.nsec): return -1
	if (a.nsec > b.nsec): return 1
	return 0


# Whole milliseconds from b to a (a - b, truncated toward zero). The
# caller keeps the distance within the target's int (~24.8 days on x86).
int wtime_diff_ms(wtime* a, wtime* b):
	int sec = a.sec - b.sec
	int ns = a.nsec - b.nsec
	# Give both parts the sign of the whole so the division truncates
	# the total, not just the nanosecond part.
	if ((sec > 0) && (ns < 0)):
		sec = sec - 1
		ns = ns + WCLOCK_NS_PER_SEC
	else if ((sec < 0) && (ns > 0)):
		sec = sec + 1
		ns = ns - WCLOCK_NS_PER_SEC
	return sec * 1000 + ns / 1000000


/* Readings. */

int wclock_monotonic(wclock* c, wtime* out):
	return c.read(c.self, WCLOCK_MONOTONIC, out)


int wclock_wall(wclock* c, wtime* out):
	return c.read(c.self, WCLOCK_WALL, out)


# Largest positive int on this target.
int wclock_word_max():
	int q = 1 << (__word_size__ * 8 - 2)
	return (q - 1) + q


# Converts t to one word in units per second; IO_UNSUPPORTED (out = 0)
# when the value does not fit this target's int.
int wclock_scalar(wtime* t, int units_per_sec, int* out):
	int limit = wclock_word_max() / units_per_sec - 1
	if ((t.sec > limit) || (t.sec < 0 - limit)):
		out[0] = 0
		return IO_UNSUPPORTED
	out[0] = t.sec * units_per_sec + t.nsec / (WCLOCK_NS_PER_SEC / units_per_sec)
	return IO_OK


# Monotonic milliseconds with time_monotonic_ms's wrapping contract
# (header): never IO_UNSUPPORTED, compare only by difference.
int wclock_monotonic_ms(wclock* c, int* out):
	wtime t
	int status = wclock_monotonic(c, &t)
	if (status != IO_OK):
		out[0] = 0
		return status
	out[0] = t.sec * 1000 + t.nsec / 1000000
	return IO_OK


# Monotonic nanoseconds as one word, or IO_UNSUPPORTED when it does not
# fit (32-bit targets after ~2.1 s): use wclock_monotonic there.
int wclock_monotonic_ns(wclock* c, int* out):
	wtime t
	int status = wclock_monotonic(c, &t)
	if (status != IO_OK):
		out[0] = 0
		return status
	return wclock_scalar(&t, WCLOCK_NS_PER_SEC, out)


# Wall milliseconds since the epoch as one word, or IO_UNSUPPORTED when
# it does not fit (always the case for real dates on 32-bit targets).
int wclock_wall_ms(wclock* c, int* out):
	wtime t
	int status = wclock_wall(c, &t)
	if (status != IO_OK):
		out[0] = 0
		return status
	return wclock_scalar(&t, 1000, out)


int wclock_wall_ns(wclock* c, int* out):
	wtime t
	int status = wclock_wall(c, &t)
	if (status != IO_OK):
		out[0] = 0
		return status
	return wclock_scalar(&t, WCLOCK_NS_PER_SEC, out)


/* Construction. */

wclock* wclock_alloc(wclock_read_fn* read, void* self):
	wclock* c = new wclock()
	c.read = read
	c.self = self
	c.is_virtual = 0
	c.mono_sec = 0
	c.mono_nsec = 0
	c.wall_sec = 0
	c.wall_nsec = 0
	c.mono_fail = IO_OK
	c.wall_fail = IO_OK
	c.reads = 0
	return c


# A clock backed by any read function (a simulator, a recorded trace).
wclock* wclock_custom_new(wclock_read_fn* read, void* self):
	return wclock_alloc(read, self)


void wclock_free(wclock* c):
	free(c)


# The real clock: CLOCK_MONOTONIC and CLOCK_REALTIME via clock_gettime.
# The kernel's timespec is two words on every Linux target, the same
# shape as wtime.
int wclock_real_read(void* self, int which, wtime* out):
	wclock* c = cast(wclock*, self)
	int id = WCLOCK_ID_MONOTONIC
	if (which == WCLOCK_WALL): id = WCLOCK_ID_REALTIME
	int err = sys_clock_gettime(id, cast(int, out))
	if (err < 0):
		out.sec = 0
		out.nsec = 0
		return io_status_from_errno(0 - err)
	c.reads = c.reads + 1
	return IO_OK


wclock* wclock_real_new():
	wclock* c = wclock_alloc(wclock_real_read, 0)
	c.self = cast(void*, c)
	return c


/* Virtual clock: time moves only when the owner says so. */

int wclock_virtual_read(void* self, int which, wtime* out):
	wclock* c = cast(wclock*, self)
	if (which == WCLOCK_WALL):
		if (c.wall_fail != IO_OK):
			wtime_set(out, 0, 0)
			return c.wall_fail
		wtime_set(out, c.wall_sec, c.wall_nsec)
	else:
		if (c.mono_fail != IO_OK):
			wtime_set(out, 0, 0)
			return c.mono_fail
		wtime_set(out, c.mono_sec, c.mono_nsec)
	c.reads = c.reads + 1
	return IO_OK


# Monotonic time starts at 0; wall time at wall_sec seconds after the
# epoch.
wclock* wclock_virtual_new(int wall_sec):
	wclock* c = wclock_alloc(wclock_virtual_read, 0)
	c.self = cast(void*, c)
	c.is_virtual = 1
	c.wall_sec = wall_sec
	return c


void wclock_virtual_store(wclock* c, wtime* mono, wtime* wall):
	c.mono_sec = mono.sec
	c.mono_nsec = mono.nsec
	c.wall_sec = wall.sec
	c.wall_nsec = wall.nsec


void wclock_virtual_load(wclock* c, wtime* mono, wtime* wall):
	wtime_set(mono, c.mono_sec, c.mono_nsec)
	wtime_set(wall, c.wall_sec, c.wall_nsec)


# Moves both time lines forward by ns (>= 0): real time passing.
void wclock_virtual_advance_ns(wclock* c, int ns):
	asserts(c"wclock_virtual_advance_ns: virtual clock required", c.is_virtual)
	asserts(c"wclock_virtual_advance_ns: time never runs backwards", ns >= 0)
	wtime mono
	wtime wall
	wclock_virtual_load(c, &mono, &wall)
	wtime_add_ns(&mono, ns)
	wtime_add_ns(&wall, ns)
	wclock_virtual_store(c, &mono, &wall)


void wclock_virtual_advance_ms(wclock* c, int ms):
	asserts(c"wclock_virtual_advance_ms: virtual clock required", c.is_virtual)
	asserts(c"wclock_virtual_advance_ms: time never runs backwards", ms >= 0)
	wtime mono
	wtime wall
	wclock_virtual_load(c, &mono, &wall)
	wtime_add_ms(&mono, ms)
	wtime_add_ms(&wall, ms)
	wclock_virtual_store(c, &mono, &wall)


# Advances to monotonic time target (no-op when target is not later):
# how a simulator jumps straight to the next deadline instead of sleeping.
void wclock_virtual_advance_to(wclock* c, wtime* target):
	asserts(c"wclock_virtual_advance_to: virtual clock required", c.is_virtual)
	wtime mono
	wtime wall
	wclock_virtual_load(c, &mono, &wall)
	if (wtime_compare(target, &mono) <= 0): return
	int sec = target.sec - mono.sec
	int nsec = target.nsec - mono.nsec
	wall.sec = wall.sec + sec
	wall.nsec = wall.nsec + nsec
	wtime_normalize(&wall)
	wclock_virtual_store(c, target, &wall)


# Steps wall time by ms (either sign) without touching monotonic time:
# an NTP step or an operator resetting the date.
void wclock_virtual_jump_wall_ms(wclock* c, int ms):
	asserts(c"wclock_virtual_jump_wall_ms: virtual clock required", c.is_virtual)
	wtime wall
	wtime_set(&wall, c.wall_sec, c.wall_nsec)
	wtime_add_ms(&wall, ms)
	c.wall_sec = wall.sec
	c.wall_nsec = wall.nsec


void wclock_virtual_set_wall(wclock* c, int sec, int nsec):
	asserts(c"wclock_virtual_set_wall: virtual clock required", c.is_virtual)
	c.wall_sec = sec
	c.wall_nsec = nsec


# Forces every following reading of which (WCLOCK_MONOTONIC or
# WCLOCK_WALL) to fail with status until called again with IO_OK.
void wclock_virtual_fail(wclock* c, int which, int status):
	asserts(c"wclock_virtual_fail: virtual clock required", c.is_virtual)
	if (which == WCLOCK_WALL): c.wall_fail = status
	else: c.mono_fail = status
