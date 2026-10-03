/*
Bounded service diagnostics (docs/projects/budgets_transport.md, issue
#514 stage W5): named counters and gauges, an optional log2 latency
histogram and an optional ring of structured events. Every structure is
sized once at creation; nothing here grows with traffic, and no
external metrics dependency is involved.

	metrics* m = metrics_new(16)              # standard ids + 10 custom
	metrics_enable_latency(m)                 # io_latency_us histogram
	metrics_enable_events(m, 64)              # newest 64 events kept
	metrics_add(m, METRIC_ALLOC_FAILURES, 1)
	metrics_set(m, METRIC_JOBS_QUEUED, queue.length)
	int t0 = metrics_now_us()
	... I/O ...
	metrics_observe_since(m, t0)
	metrics_event(m, 3, status, c"accept failed")
	metrics_write_fd(m, 2)                    # or metrics_format(m, buf, cap)

The standard ids (METRIC_*) cover the counters the reliable-services
design asks for: pending tasks, queued jobs and bytes, blocked workers,
allocation failures and open descriptors; I/O latency is the histogram.
Producers set them: task_dump_fd's scheduler counts (lib/task.w,
active_count and ready.length) feed METRIC_TASKS_PENDING, a bounded
executor feeds the queue and worker gauges, arena/mem_budget failure
counters (lib/arena.w) feed METRIC_ALLOC_FAILURES, and
metrics_sample_open_fds reads /proc/self/fd. lib/transport.w can time
every read/write into the histogram (transport_set_metrics).

Counters saturate at the largest int instead of wrapping. The event
ring keeps the newest events, overwriting the oldest and counting each
overwrite in events_dropped; event text is copied (truncated to
METRICS_EVENT_TEXT - 1 bytes), so callers may pass temporary strings.
Not internally locked: keep one metrics per worker thread (tasks on one
scheduler are cooperative) or guard it with a wmutex.
*/
import lib.lib
import lib.memory
import lib.time
import lib.dir


const int METRICS_KIND_COUNTER = 1
const int METRICS_KIND_GAUGE = 2


# Standard ids, registered by metrics_new in this order.
const int METRIC_TASKS_PENDING = 0
const int METRIC_JOBS_QUEUED = 1
const int METRIC_BYTES_QUEUED = 2
const int METRIC_WORKERS_BLOCKED = 3
const int METRIC_ALLOC_FAILURES = 4
const int METRIC_FDS_OPEN = 5
const int METRICS_STANDARD_COUNT = 6


# Histogram bucket 0 holds values <= 0; bucket k (1..30) holds
# 2^(k-1) <= v < 2^k; bucket 31 holds everything >= 2^30.
const int METRICS_HIST_BUCKETS = 32
const int METRICS_EVENT_TEXT = 48


struct metrics_histogram:
	int* buckets   # METRICS_HIST_BUCKETS counts
	int count
	int sum        # saturating
	int min
	int max


struct metrics_event_record:
	int seq        # 1, 2, ... in push order; gaps never occur
	int time_ms    # time_monotonic_ms at push
	int kind       # caller-defined
	int value      # caller-defined (a status, a byte count, ...)
	char* text     # points into the ring's text area


struct metrics_event_ring:
	metrics_event_record* slots
	char* text_area   # capacity * METRICS_EVENT_TEXT bytes
	int capacity
	int start         # index of the oldest kept event
	int count         # events kept (<= capacity)
	int next_seq
	int dropped       # events overwritten before anyone read them


struct metrics:
	int capacity
	int count
	char** names      # owned copies
	int* kinds
	int* values
	metrics_histogram* latency      # 0 until metrics_enable_latency
	metrics_event_ring* events      # 0 until metrics_enable_events


int metrics_int_max():
	return ~(1 << (__word_size__ * 8 - 1))


# a + b clamped to [-(max), max] instead of wrapping.
int metrics_saturating_add(int a, int b):
	if ((b > 0) && (a > metrics_int_max() - b)): return metrics_int_max()
	if ((b < 0) && (a < (0 - metrics_int_max()) - b)): return 0 - metrics_int_max()
	return a + b


/* Histogram. */

void metrics_histogram_clear(metrics_histogram* h):
	for i in range(METRICS_HIST_BUCKETS): h.buckets[i] = 0
	h.count = 0
	h.sum = 0
	h.min = 0
	h.max = 0


void metrics_histogram_init(metrics_histogram* h):
	h.buckets = cast(int*, malloc(METRICS_HIST_BUCKETS * __word_size__))
	metrics_histogram_clear(h)


metrics_histogram* metrics_histogram_new():
	metrics_histogram* h = cast(metrics_histogram*, malloc(sizeof(metrics_histogram)))
	metrics_histogram_init(h)
	return h


void metrics_histogram_free(metrics_histogram* h):
	if (cast(int, h) == 0): return
	free(cast(char*, h.buckets))
	free(cast(char*, h))


int metrics_histogram_bucket(int value):
	if (value <= 0): return 0
	int k = 0
	while ((value != 0) && (k < METRICS_HIST_BUCKETS - 1)):
		value = value >> 1
		k = k + 1
	return k


# Smallest value that falls past bucket k (its exclusive upper bound);
# the largest int for the open-ended last bucket.
int metrics_histogram_bucket_limit(int k):
	if (k <= 0): return 1
	if (k >= METRICS_HIST_BUCKETS - 1): return metrics_int_max()
	return 1 << k


void metrics_histogram_observe(metrics_histogram* h, int value):
	int k = metrics_histogram_bucket(value)
	h.buckets[k] = metrics_saturating_add(h.buckets[k], 1)
	if ((h.count == 0) || (value < h.min)): h.min = value
	if ((h.count == 0) || (value > h.max)): h.max = value
	h.count = metrics_saturating_add(h.count, 1)
	h.sum = metrics_saturating_add(h.sum, value)


# Upper bound of the bucket holding the permille-th sample (500 = median,
# 990 = p99), capped at the observed max; 0 when empty.
int metrics_histogram_quantile(metrics_histogram* h, int permille):
	if (h.count == 0): return 0
	if (permille < 0): permille = 0
	if (permille > 1000): permille = 1000
	# rank = ceil(count * permille / 1000) without overflowing count * 1000.
	int rank = (h.count / 1000) * permille + ((h.count % 1000) * permille + 999) / 1000
	if (rank < 1): rank = 1
	int seen = 0
	for k in range(METRICS_HIST_BUCKETS):
		seen = seen + h.buckets[k]
		if (seen >= rank):
			if (k == 0): return h.min
			int limit = metrics_histogram_bucket_limit(k) - 1
			if (limit > h.max): limit = h.max
			return limit
	return h.max


/* Event ring. */

metrics_event_ring* metrics_event_ring_new(int capacity):
	if (capacity < 1): capacity = 1
	metrics_event_ring* r = cast(metrics_event_ring*, malloc(sizeof(metrics_event_ring)))
	r.slots = cast(metrics_event_record*, malloc(capacity * sizeof(metrics_event_record)))
	r.text_area = malloc(capacity * METRICS_EVENT_TEXT)
	r.capacity = capacity
	r.start = 0
	r.count = 0
	r.next_seq = 1
	r.dropped = 0
	for i in range(capacity):
		metrics_event_record* e = &r.slots[i]
		e.text = r.text_area + i * METRICS_EVENT_TEXT
		e.text[0] = 0
	return r


void metrics_event_ring_free(metrics_event_ring* r):
	if (cast(int, r) == 0): return
	free(cast(char*, r.slots))
	free(r.text_area)
	free(cast(char*, r))


# Appends an event, overwriting (and counting) the oldest when full.
void metrics_event_ring_push(metrics_event_ring* r, int kind, int value, char* text):
	int index = 0
	if (r.count < r.capacity):
		index = (r.start + r.count) % r.capacity
		r.count = r.count + 1
	else:
		index = r.start
		r.start = (r.start + 1) % r.capacity
		r.dropped = metrics_saturating_add(r.dropped, 1)
	metrics_event_record* e = &r.slots[index]
	e.seq = r.next_seq
	r.next_seq = r.next_seq + 1
	e.time_ms = time_monotonic_ms()
	e.kind = kind
	e.value = value
	int n = 0
	if (cast(int, text) != 0):
		while ((n < METRICS_EVENT_TEXT - 1) && (text[n] != 0)):
			e.text[n] = text[n]
			n = n + 1
	e.text[n] = 0


# The i-th kept event, oldest first (0 <= i < count); 0 when out of range.
metrics_event_record* metrics_event_ring_at(metrics_event_ring* r, int i):
	if ((i < 0) || (i >= r.count)): return 0
	return &r.slots[(r.start + i) % r.capacity]


/* Registry. */

int metrics_register(metrics* m, char* name, int kind);


# capacity is the total number of ids, standard ones included (raised to
# METRICS_STANDARD_COUNT when smaller).
metrics* metrics_new(int capacity):
	if (capacity < METRICS_STANDARD_COUNT): capacity = METRICS_STANDARD_COUNT
	metrics* m = cast(metrics*, malloc(sizeof(metrics)))
	m.capacity = capacity
	m.count = 0
	m.names = cast(char**, malloc(capacity * __word_size__))
	m.kinds = cast(int*, malloc(capacity * __word_size__))
	m.values = cast(int*, malloc(capacity * __word_size__))
	m.latency = 0
	m.events = 0
	metrics_register(m, c"tasks_pending", METRICS_KIND_GAUGE)
	metrics_register(m, c"jobs_queued", METRICS_KIND_GAUGE)
	metrics_register(m, c"bytes_queued", METRICS_KIND_GAUGE)
	metrics_register(m, c"workers_blocked", METRICS_KIND_GAUGE)
	metrics_register(m, c"alloc_failures", METRICS_KIND_COUNTER)
	metrics_register(m, c"fds_open", METRICS_KIND_GAUGE)
	return m


void metrics_free(metrics* m):
	if (cast(int, m) == 0): return
	for i in range(m.count): free(m.names[i])
	free(cast(char*, m.names))
	free(cast(char*, m.kinds))
	free(cast(char*, m.values))
	metrics_histogram_free(m.latency)
	metrics_event_ring_free(m.events)
	free(cast(char*, m))


# Id of the metric called name, registering it (value 0) on first use;
# -1 when the registry is full or kind conflicts with the existing entry.
int metrics_register(metrics* m, char* name, int kind):
	for i in range(m.count):
		if (strcmp(m.names[i], name) == 0):
			if (m.kinds[i] != kind): return -1
			return i
	if (m.count >= m.capacity): return -1
	int id = m.count
	m.names[id] = strclone(name)
	m.kinds[id] = kind
	m.values[id] = 0
	m.count = m.count + 1
	return id


int metrics_counter(metrics* m, char* name):
	return metrics_register(m, name, METRICS_KIND_COUNTER)


int metrics_gauge(metrics* m, char* name):
	return metrics_register(m, name, METRICS_KIND_GAUGE)


int metrics_valid_id(metrics* m, int id):
	return (id >= 0) && (id < m.count)


# Saturating add; ignored for an invalid id (a -1 from a full registry).
void metrics_add(metrics* m, int id, int delta):
	if (metrics_valid_id(m, id) == 0): return
	m.values[id] = metrics_saturating_add(m.values[id], delta)


void metrics_set(metrics* m, int id, int value):
	if (metrics_valid_id(m, id) == 0): return
	m.values[id] = value


# 0 for an invalid id.
int metrics_get(metrics* m, int id):
	if (metrics_valid_id(m, id) == 0): return 0
	return m.values[id]


# Copies up to capacity values (in id order) into out; returns how many.
int metrics_snapshot(metrics* m, int* out, int capacity):
	int n = m.count
	if (n > capacity): n = capacity
	for i in range(n): out[i] = m.values[i]
	return n


void metrics_enable_latency(metrics* m):
	if (cast(int, m.latency) == 0): m.latency = metrics_histogram_new()


void metrics_enable_events(metrics* m, int capacity):
	if (cast(int, m.events) == 0): m.events = metrics_event_ring_new(capacity)


# No-op until metrics_enable_latency.
void metrics_observe_latency(metrics* m, int micros):
	if (cast(int, m.latency) != 0): metrics_histogram_observe(m.latency, micros)


# No-op until metrics_enable_events.
void metrics_event(metrics* m, int kind, int value, char* text):
	if (cast(int, m.events) != 0): metrics_event_ring_push(m.events, kind, value, text)


/* Clock and sampling. */

# Monotonic microseconds. Wraps (after ~35 minutes on 32-bit targets), so
# use it only for differences: metrics_elapsed_us handles the wrap.
int metrics_now_us():
	timespec ts
	int err = sys_clock_gettime(clock_monotonic, cast(int, &ts))
	if (err < 0): return 0
	return ts.seconds * 1000000 + ts.nanoseconds / 1000


int metrics_elapsed_us(int start_us):
	int d = metrics_now_us() - start_us
	if (d < 0): return 0
	return d


void metrics_observe_since(metrics* m, int start_us):
	metrics_observe_latency(m, metrics_elapsed_us(start_us))


# Open descriptors of this process from /proc/self/fd (the listing's own
# descriptor excluded), or -1 where /proc is unavailable.
int metrics_count_open_fds():
	list[char*] names = new list[char*]
	list[int] kinds = new list[int]
	int n = -1
	if (dir_platform_read(c"/proc/self/fd", names, kinds) == 0):
		n = 0
		for char* name in names:
			if ((strcmp(name, c".") != 0) && (strcmp(name, c"..") != 0)): n = n + 1
		if (n > 0): n = n - 1
	for char* doomed in names: free(doomed)
	list_free[char*](names)
	list_free[int](kinds)
	return n


# Sets METRIC_FDS_OPEN (left unchanged when unavailable); returns the count.
int metrics_sample_open_fds(metrics* m):
	int n = metrics_count_open_fds()
	if (n >= 0): metrics_set(m, METRIC_FDS_OPEN, n)
	return n


/* Text snapshot. */

# Output sink: a descriptor (fd >= 0) or a bounded buffer.
struct metrics_sink:
	int fd
	char* buf
	int cap
	int len        # bytes produced (may exceed cap - 1: truncated)


void metrics_sink_put(metrics_sink* s, char* text):
	if (s.fd >= 0):
		write(s.fd, text, strlen(text))
		return
	int i = 0
	while (text[i] != 0):
		if (s.len < s.cap - 1): s.buf[s.len] = text[i]
		s.len = s.len + 1
		i = i + 1


void metrics_sink_int(metrics_sink* s, int v):
	char* text = itoa(v)
	metrics_sink_put(s, text)
	free(text)


void metrics_emit(metrics* m, metrics_sink* s):
	for i in range(m.count):
		metrics_sink_put(s, m.names[i])
		metrics_sink_put(s, c" ")
		metrics_sink_int(s, m.values[i])
		metrics_sink_put(s, c"\x0a")
	metrics_histogram* h = m.latency
	if (cast(int, h) != 0):
		metrics_sink_put(s, c"io_latency_us count=")
		metrics_sink_int(s, h.count)
		metrics_sink_put(s, c" sum=")
		metrics_sink_int(s, h.sum)
		metrics_sink_put(s, c" min=")
		metrics_sink_int(s, h.min)
		metrics_sink_put(s, c" max=")
		metrics_sink_int(s, h.max)
		metrics_sink_put(s, c" p50<=")
		metrics_sink_int(s, metrics_histogram_quantile(h, 500))
		metrics_sink_put(s, c" p99<=")
		metrics_sink_int(s, metrics_histogram_quantile(h, 990))
		metrics_sink_put(s, c"\x0a")
		for k in range(METRICS_HIST_BUCKETS):
			if (h.buckets[k] != 0):
				metrics_sink_put(s, c"  lt ")
				metrics_sink_int(s, metrics_histogram_bucket_limit(k))
				metrics_sink_put(s, c": ")
				metrics_sink_int(s, h.buckets[k])
				metrics_sink_put(s, c"\x0a")
	metrics_event_ring* r = m.events
	if (cast(int, r) != 0):
		metrics_sink_put(s, c"events kept=")
		metrics_sink_int(s, r.count)
		metrics_sink_put(s, c" dropped=")
		metrics_sink_int(s, r.dropped)
		metrics_sink_put(s, c"\x0a")
		for i in range(r.count):
			metrics_event_record* e = metrics_event_ring_at(r, i)
			metrics_sink_put(s, c"  #")
			metrics_sink_int(s, e.seq)
			metrics_sink_put(s, c" kind=")
			metrics_sink_int(s, e.kind)
			metrics_sink_put(s, c" value=")
			metrics_sink_int(s, e.value)
			metrics_sink_put(s, c" ")
			metrics_sink_put(s, e.text)
			metrics_sink_put(s, c"\x0a")


# One "name value" line per metric, then the histogram and events.
void metrics_write_fd(metrics* m, int fd):
	metrics_sink s
	s.fd = fd
	s.buf = 0
	s.cap = 0
	s.len = 0
	metrics_emit(m, &s)


# Formats the same text into buf (always NUL-terminated when cap > 0).
# Returns the full length; a result >= cap means the text was truncated.
int metrics_format(metrics* m, char* buf, int cap):
	metrics_sink s
	s.fd = -1
	s.buf = buf
	s.cap = cap
	s.len = 0
	metrics_emit(m, &s)
	if (cap > 0):
		if (s.len < cap): buf[s.len] = 0
		else: buf[cap - 1] = 0
	return s.len
