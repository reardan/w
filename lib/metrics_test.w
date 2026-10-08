# wbuild: x64
import lib.testing
import lib.metrics


void test_metrics_standard_ids_and_custom_registration():
	metrics* m = metrics_new(8)
	assert_equal(METRICS_STANDARD_COUNT, m.count)
	assert_strings_equal(c"tasks_pending", m.names[METRIC_TASKS_PENDING])
	assert_strings_equal(c"fds_open", m.names[METRIC_FDS_OPEN])
	int requests = metrics_counter(m, c"requests")
	int inflight = metrics_gauge(m, c"inflight")
	assert_equal(METRICS_STANDARD_COUNT, requests)
	assert_equal(requests, metrics_counter(m, c"requests"))
	# Kind conflicts and a full registry are refused, not grown.
	assert_equal(-1, metrics_gauge(m, c"requests"))
	assert_equal(-1, metrics_counter(m, c"one_too_many"))
	assert_equal(8, m.count)
	metrics_add(m, requests, 2)
	metrics_add(m, requests, 3)
	metrics_set(m, inflight, 7)
	metrics_add(m, -1, 100)
	metrics_set(m, 99, 100)
	assert_equal(5, metrics_get(m, requests))
	assert_equal(7, metrics_get(m, inflight))
	assert_equal(0, metrics_get(m, -1))
	metrics_add(m, METRIC_ALLOC_FAILURES, metrics_int_max())
	metrics_add(m, METRIC_ALLOC_FAILURES, 1)
	assert_equal(metrics_int_max(), metrics_get(m, METRIC_ALLOC_FAILURES))
	int* snap = cast(int*, malloc(4 * __word_size__))
	assert_equal(4, metrics_snapshot(m, snap, 4))
	metrics_set(m, METRIC_JOBS_QUEUED, 12)
	assert_equal(0, snap[METRIC_JOBS_QUEUED])
	free(cast(char*, snap))
	metrics_free(m)


void test_metrics_histogram_buckets_are_fixed():
	metrics_histogram* h = metrics_histogram_new()
	assert_equal(0, metrics_histogram_bucket(0))
	assert_equal(0, metrics_histogram_bucket(-5))
	assert_equal(1, metrics_histogram_bucket(1))
	assert_equal(2, metrics_histogram_bucket(2))
	assert_equal(2, metrics_histogram_bucket(3))
	assert_equal(11, metrics_histogram_bucket(1024))
	assert_equal(METRICS_HIST_BUCKETS - 1, metrics_histogram_bucket(metrics_int_max()))
	# A million observations change counts, never the footprint.
	int i = 0
	while (i < 1000000):
		metrics_histogram_observe(h, i % 2000)
		i = i + 1
	assert_equal(1000000, h.count)
	assert_equal(0, h.min)
	assert_equal(1999, h.max)
	int total = 0
	for k in range(METRICS_HIST_BUCKETS): total = total + h.buckets[k]
	assert_equal(1000000, total)
	int median = metrics_histogram_quantile(h, 500)
	assert1((median >= 999) && (median <= 1023))
	assert_equal(1999, metrics_histogram_quantile(h, 1000))
	metrics_histogram_clear(h)
	assert_equal(0, h.count)
	assert_equal(0, metrics_histogram_quantile(h, 500))
	metrics_histogram_free(h)


void test_metrics_event_ring_drops_oldest():
	metrics_event_ring* r = metrics_event_ring_new(4)
	for i in range(10): metrics_event_ring_push(r, 1, i, c"tick")
	assert_equal(4, r.count)
	assert_equal(6, r.dropped)
	assert_equal(7, metrics_event_ring_at(r, 0).seq)
	assert_equal(6, metrics_event_ring_at(r, 0).value)
	assert_equal(9, metrics_event_ring_at(r, 3).value)
	assert_equal(0, cast(int, metrics_event_ring_at(r, 4)))
	# Text is copied and truncated, so temporaries are fine.
	char* long_text = cast(char*, malloc(200))
	for i in range(199): long_text[i] = 'x'
	long_text[199] = 0
	metrics_event_ring_push(r, 2, 0, long_text)
	free(long_text)
	char* kept = metrics_event_ring_at(r, 3).text
	assert_equal(METRICS_EVENT_TEXT - 1, strlen(kept))
	metrics_event_ring_free(r)


void test_metrics_format_is_bounded():
	metrics* m = metrics_new(6)
	metrics_enable_latency(m)
	metrics_enable_events(m, 2)
	metrics_set(m, METRIC_TASKS_PENDING, 3)
	metrics_observe_latency(m, 100)
	metrics_observe_latency(m, 300)
	metrics_event(m, 5, -1, c"accept failed")
	char* buf = cast(char*, malloc(4096))
	int n = metrics_format(m, buf, 4096)
	assert1(n < 4096)
	assert_contains(buf, c"tasks_pending 3\x0a")
	assert_contains(buf, c"io_latency_us count=2 sum=400 min=100 max=300")
	assert_contains(buf, c"events kept=1 dropped=0")
	assert_contains(buf, c"kind=5 value=-1 accept failed")
	# A tiny buffer truncates but stays terminated and reports the length.
	assert_equal(n, metrics_format(m, buf, 8))
	assert_equal(7, strlen(buf))
	free(buf)
	metrics_free(m)


void test_metrics_open_fds_and_clock():
	metrics* m = metrics_new(0)
	int before = metrics_sample_open_fds(m)
	assert1(before >= 3)
	assert_equal(before, metrics_get(m, METRIC_FDS_OPEN))
	int fd = open(c"/proc/self/statm", 0, 0)
	assert1(fd >= 0)
	assert_equal(before + 1, metrics_count_open_fds())
	close(fd)
	assert_equal(before, metrics_count_open_fds())
	int t0 = metrics_now_us()
	sleep_ms(2)
	assert1(metrics_elapsed_us(t0) >= 1000)
	metrics_free(m)
