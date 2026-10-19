# wbuild: arch_only=x64
# U4.1 viewsets, routing, permissions and throttling on SQLite in memory
# (docs/projects/orm/u4_1.md): the shared scenarios in
# tests/orm/orm_rest_cases.w through the in-process router, then the same
# router mounted on a real http_server over loopback.
import tests.orm.orm_rest_cases
import libs.standard.web.http_client
import libs.standard.web.testing


ServerResponse* rest_unused_handler(ServerRequest* req, void* context):
	return server_response_new(500)


http_response* rest_http(int port, char* method, char* path, char* body, char* token):
	char* target = net_test_url(c"http", port, path)
	http_req* req = http_req_new(method, target)
	http_req_add_header(req, c"Connection", c"close")
	if (token != 0):
		char* v = orm_rest_concat(c"Token ", token)
		http_req_add_header(req, c"Authorization", v)
	if (body != 0):
		http_req_add_header(req, c"Content-Type", c"application/json")
		req.body = body
		req.body_len = strlen(body)
	http_response* resp = http_request(req)
	http_req_free(req)
	free(target)
	return resp


# The router mounted on http_server: three requests over loopback.
void rest_case_loopback():
	ServerContext* s = server_context_new(c"127.0.0.1", 0, rest_unused_handler, 0)
	s.timeout_ms = 60000
	asserts(c"server bind", server_context_bind(s) != 0)
	int port = server_context_port(s)
	orm_rest_router_mount(__rest_rt, s)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		server_context_accept_loop(s, 4)
		exit(0)
	server_context_close(s)
	server_context_free(s)
	char* p1 = rest_f(c"/api/books/@1/")
	http_response* r1 = rest_http(port, c"GET", p1, 0, 0)
	assert_equal(0, r1.error)
	assert_equal(200, r1.status)
	assert_strings_equal(rest_f(c"{\"id\":@1,\"title\":\"Alpha\",\"author\":@4,\"status\":\"pub\",\"price\":\"10.00\",\"pages\":null,\"author_name\":\"Alice A.\"}"), r1.body)
	assert_strings_equal(c"application/json", http_response_header(r1, c"content-type"))
	assert_strings_equal(c"GET, PUT, PATCH, DELETE, HEAD, OPTIONS", http_response_header(r1, c"allow"))
	http_response_free(r1)
	http_response* r2 = rest_http(port, c"POST", c"/api/books/", c"{\"title\":\"Wire\"}", 0)
	assert_equal(401, r2.status)
	assert_strings_equal(c"Token", http_response_header(r2, c"www-authenticate"))
	http_response_free(r2)
	char* body = rest_f(c"{\"title\":\"Wire\",\"author\":@4,\"price\":\"3.00\"}")
	http_response* r3 = rest_http(port, c"POST", c"/api/books", body, __rest.alice_tok)
	assert_equal(201, r3.status)
	assert_contains(r3.body, c"\"title\":\"Wire\"")
	http_response_free(r3)
	http_response* r4 = rest_http(port, c"GET", c"/openapi.json", 0, 0)
	assert_equal(200, r4.status)
	assert_contains(r4.body, c"\"/api/tags/{id}/\"")
	http_response_free(r4)
	free(p1)
	free(body)
	web_test_finish(pid, -1)


int main():
	if (sql_sqlite_available() == 0):
		println(c"orm_rest: SKIP (libsqlite3.so.0 unavailable)")
		return 0
	orm_db* db = orm_open_sqlite(c":memory:")
	asserts(orm_db_error(db), orm_is_open(db))
	rest_run_cases(db)
	rest_case_loopback()
	orm_rest_teardown()
	orm_close(db)
	println(c"orm_rest_test: OK")
	return 0
