# wbuild: x64
# Offline tests for libs/standard/web/retry.w (issue #202). Everything
# here is pure computation - retryability, exponential backoff and its
# cap, full-jitter bounds, Retry-After in both delta-seconds and
# HTTP-date forms (with an injected clock), and the HTTP-date parser -
# so no server or network is involved.
import lib.testing
import libs.standard.web.retry
import libs.standard.web.http_client


# An http_response carrying just a status (and optionally a transport
# error), built the way the client would so http_response_free is clean.
http_response* retry_test_resp(int status, int error):
	http_response* resp = http_response_new()
	resp.status = status
	resp.error = error
	return resp


# Adds a header the way the parser stores them (lowercased name; the map
# clones the key, http_response_free frees the value).
void retry_test_set_header(http_response* resp, char* name, char* value):
	resp.headers[name] = strclone(value)


void test_retry_retryable_default():
	assert_equal(1, retry_retryable_default(429))
	assert_equal(1, retry_retryable_default(500))
	assert_equal(1, retry_retryable_default(503))
	assert_equal(1, retry_retryable_default(529))
	assert_equal(1, retry_retryable_default(599))
	assert_equal(0, retry_retryable_default(400))
	assert_equal(0, retry_retryable_default(404))
	assert_equal(0, retry_retryable_default(200))
	assert_equal(0, retry_retryable_default(301))
	assert_equal(0, retry_retryable_default(499))


void test_retry_should_retry_statuses():
	retry_policy* p = retry_policy_default()

	# Retryable statuses within the attempt budget.
	http_response* r429 = retry_test_resp(429, 0)
	assert_equal(1, retry_should_retry(p, 0, r429))
	http_response_free(r429)

	http_response* r503 = retry_test_resp(503, 0)
	assert_equal(1, retry_should_retry(p, 0, r503))
	http_response_free(r503)

	http_response* r529 = retry_test_resp(529, 0)
	assert_equal(1, retry_should_retry(p, 0, r529))
	http_response_free(r529)

	# Non-retryable statuses.
	http_response* r404 = retry_test_resp(404, 0)
	assert_equal(0, retry_should_retry(p, 0, r404))
	http_response_free(r404)

	http_response* r200 = retry_test_resp(200, 0)
	assert_equal(0, retry_should_retry(p, 0, r200))
	http_response_free(r200)

	# A transport error (status 0) is always retryable.
	http_response* rerr = retry_test_resp(0, http_error_connect())
	assert_equal(1, retry_should_retry(p, 0, rerr))
	http_response_free(rerr)

	retry_policy_free(p)


void test_retry_attempt_exhaustion():
	retry_policy* p = retry_policy_default()
	p.max_attempts = 3
	http_response* r503 = retry_test_resp(503, 0)
	# attempt is 0-based: 0 and 1 have budget, 2 is the last attempt.
	assert_equal(1, retry_should_retry(p, 0, r503))
	assert_equal(1, retry_should_retry(p, 1, r503))
	assert_equal(0, retry_should_retry(p, 2, r503))
	assert_equal(0, retry_should_retry(p, 3, r503))
	http_response_free(r503)
	retry_policy_free(p)


void test_retry_backoff_growth_and_cap():
	retry_policy* p = retry_policy_default()
	p.base_delay_ms = 1000
	p.max_delay_ms = 32000
	assert_equal(1000, retry_backoff_ms(p, 0))
	assert_equal(2000, retry_backoff_ms(p, 1))
	assert_equal(4000, retry_backoff_ms(p, 2))
	assert_equal(8000, retry_backoff_ms(p, 3))
	assert_equal(16000, retry_backoff_ms(p, 4))
	assert_equal(32000, retry_backoff_ms(p, 5))
	# Past the cap it stays clamped.
	assert_equal(32000, retry_backoff_ms(p, 6))
	assert_equal(32000, retry_backoff_ms(p, 20))
	retry_policy_free(p)


void test_retry_delay_no_jitter_equals_backoff():
	retry_policy* p = retry_policy_default()
	p.jitter = 0
	# No response -> pure backoff.
	assert_equal(1000, retry_delay_ms_at(p, 0, 0, 0))
	assert_equal(4000, retry_delay_ms_at(p, 2, 0, 0))
	assert_equal(32000, retry_delay_ms_at(p, 9, 0, 0))
	retry_policy_free(p)


void test_retry_full_jitter_bounds():
	retry_policy* p = retry_policy_default()
	p.jitter = 1
	p.base_delay_ms = 1000
	p.max_delay_ms = 32000
	int attempt = 2
	int computed = retry_backoff_ms(p, attempt)
	assert_equal(4000, computed)
	int lo = computed
	int hi = 0
	int i = 0
	while (i < 300):
		int d = retry_delay_ms_at(p, attempt, 0, 0)
		asserts(c"jitter below 0", d >= 0)
		asserts(c"jitter above computed", d <= computed)
		if (d < lo):
			lo = d
		if (d > hi):
			hi = d
		i = i + 1
	# Over 300 draws we should see real spread, not a constant.
	asserts(c"jitter produced no spread", hi > lo)
	asserts(c"jitter never near top", hi > (computed / 2))
	retry_policy_free(p)


void test_retry_after_delta_seconds():
	# Pure parse.
	assert_equal(120, retry_after_seconds(c"120", 1000))
	assert_equal(0, retry_after_seconds(c"0", 1000))
	assert_equal(5, retry_after_seconds(c"  5  ", 1000))
	# Not a delta and not a date.
	assert_equal((-1), retry_after_seconds(c"12x", 1000))
	assert_equal((-1), retry_after_seconds(c"abc", 1000))
	assert_equal((-1), retry_after_seconds(c"", 1000))


void test_retry_delay_honors_retry_after_delta():
	retry_policy* p = retry_policy_default()
	p.jitter = 1
	p.max_delay_ms = 32000
	http_response* resp = retry_test_resp(503, 0)
	retry_test_set_header(resp, c"retry-after", c"5")
	# 5s -> 5000ms, under the cap, and NOT jittered even with jitter on.
	assert_equal(5000, retry_delay_ms_at(p, 0, resp, 0))
	assert_equal(5000, retry_delay_ms_at(p, 4, resp, 0))
	http_response_free(resp)

	# A Retry-After larger than the cap is clamped to max_delay_ms.
	http_response* big = retry_test_resp(503, 0)
	retry_test_set_header(big, c"retry-after", c"120")
	assert_equal(32000, retry_delay_ms_at(p, 0, big, 0))
	http_response_free(big)

	# With a roomy cap the full delta comes through.
	retry_policy* wide = retry_policy_default()
	wide.jitter = 0
	wide.max_delay_ms = 600000
	http_response* resp2 = retry_test_resp(503, 0)
	retry_test_set_header(resp2, c"retry-after", c"120")
	assert_equal(120000, retry_delay_ms_at(wide, 0, resp2, 0))
	http_response_free(resp2)
	retry_policy_free(wide)
	retry_policy_free(p)


void test_http_date_parser_all_forms():
	# RFC 7231's canonical example: all three encodings map to the same
	# instant, 784111777 unix seconds.
	assert_equal(784111777, retry_http_date_to_unix(c"Sun, 06 Nov 1994 08:49:37 GMT"))
	assert_equal(784111777, retry_http_date_to_unix(c"Sunday, 06-Nov-94 08:49:37 GMT"))
	assert_equal(784111777, retry_http_date_to_unix(c"Sun Nov  6 08:49:37 1994"))
	# The Unix epoch itself.
	assert_equal(0, retry_http_date_to_unix(c"Thu, 01 Jan 1970 00:00:00 GMT"))
	# A leap day, exercising the February/leap-year path.
	assert_equal(1582934400, retry_http_date_to_unix(c"Sat, 29 Feb 2020 00:00:00 GMT"))
	# Malformed inputs fail closed.
	assert_equal((-1), retry_http_date_to_unix(c"not a date"))
	assert_equal((-1), retry_http_date_to_unix(c"Sun, 06 Foo 1994 08:49:37 GMT"))
	assert_equal((-1), retry_http_date_to_unix(c"Sun, 06 Nov 1994 08:49 GMT"))


void test_retry_after_http_date_with_injected_now():
	int when = 784111777
	# now 60s before the date -> wait 60s.
	assert_equal(60, retry_after_seconds(c"Sun, 06 Nov 1994 08:49:37 GMT", when - 60))
	# now after the date -> clamped to 0, never negative.
	assert_equal(0, retry_after_seconds(c"Sun, 06 Nov 1994 08:49:37 GMT", when + 500))

	retry_policy* p = retry_policy_default()
	p.jitter = 0
	p.max_delay_ms = 600000
	http_response* resp = retry_test_resp(503, 0)
	retry_test_set_header(resp, c"retry-after", c"Sun, 06 Nov 1994 08:49:37 GMT")
	# now 10s before -> 10000ms.
	assert_equal(10000, retry_delay_ms_at(p, 0, resp, when - 10))
	# now past the date -> 0ms.
	assert_equal(0, retry_delay_ms_at(p, 0, resp, when + 10))
	http_response_free(resp)
	retry_policy_free(p)


void test_retry_delay_default_uses_wall_clock():
	# retry_delay_ms defers to the real clock; with no Retry-After and
	# jitter off it is just the backoff, independent of the clock.
	retry_policy* p = retry_policy_default()
	p.jitter = 0
	http_response* resp = retry_test_resp(503, 0)
	assert_equal(1000, retry_delay_ms(p, 0, resp))
	assert_equal(8000, retry_delay_ms(p, 3, resp))
	http_response_free(resp)
	retry_policy_free(p)
