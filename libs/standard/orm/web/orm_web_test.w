# wbuild: arch_only=x64
# wbuild: deps=tests/orm/templates/
# U4.3 end to end on SQLite in memory (docs/projects/orm/u4_3.md): the
# library app of orm_web_cases.w through the in-process client, with
# per-request statement counts, then one real request over a loopback
# socket through http_server.
import libs.standard.orm.web.orm_web_cases
import libs.standard.net.testing
import libs.standard.web.testing


# GET /books/ over a real socket: a forked child serves one connection
# with orm_web_app_server_handler.
void test_over_socket(webapp* w):
	ServerContext* s = server_context_new(c"127.0.0.1", 0, orm_web_app_server_handler, cast(void*, w.app))
	s.timeout_ms = 60000
	asserts(c"server bind", server_context_bind(s) != 0)
	int port = server_context_port(s)
	int pid = fork()
	asserts(c"fork failed", pid >= 0)
	if (pid == 0):
		server_context_accept_loop(s, 1)
		exit(0)
	server_context_close(s)
	server_context_free(s)
	char* target = net_test_url(c"http", port, c"/books/1/")
	http_req* req = http_req_new(c"GET", target)
	http_req_add_header(req, c"Connection", c"close")
	http_response* resp = http_request(req)
	assert_equal(0, resp.error)
	assert_equal(200, resp.status)
	assert_contains(resp.body, c"<h1>Dune Messiah</h1>")
	assert_strings_equal(c"DENY", http_response_header(resp, c"x-frame-options"))
	http_response_free(resp)
	http_req_free(req)
	free(target)
	web_test_finish(pid, -1)


int main():
	if (sql_sqlite_available() == 0):
		println(c"orm_web: SKIP (libsqlite3.so.0 unavailable)")
		return 0
	orm_db* db = orm_open_sqlite(c":memory:")
	asserts(orm_db_error(db), orm_is_open(db))
	db.log_queries = 1
	webapp* w = webapp_new(db, orm_web_db_source_shared(db), 1)
	orm_web_run(w)
	test_over_socket(w)
	assert1(w.src.commits > 10 && w.src.opened == w.app.requests)
	orm_close(db)
	println(c"orm_web_test: OK")
	return 0
