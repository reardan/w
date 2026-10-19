# In-process test client for w-orm web apps (unit U4.3,
# docs/projects/orm/u4_3.md): builds http_server ServerRequests, runs them
# through orm_web_app_handle without a socket, and keeps cookies between
# requests like a browser (Set-Cookie with Max-Age <= 0 deletes).
#
#   orm_web_client* c = orm_web_client_new(app)
#   ServerResponse* resp = orm_web_client_get(c, c"/books/")
#   assert_equal(200, resp.status)
#   server_response_free(resp)
import libs.standard.orm.web.middleware


struct orm_web_client:
	orm_web_app* app
	map[char*, char*] cookies      # name -> value (owned)
	char* host                     # Host header ("testserver")
	list[char*] headers            # extra request headers: name, value, name, value ...


orm_web_client* orm_web_client_new(orm_web_app* app):
	orm_web_client* c = new orm_web_client()
	c.app = app
	c.cookies = new map[char*, char*]
	c.host = c"testserver"
	c.headers = new list[char*]
	return c


void orm_web_client_clear_headers(orm_web_client* c):
	for char* s in c.headers: free(s)
	c.headers.free()
	c.headers = new list[char*]


# Adds a header to every following request (until cleared).
void orm_web_client_header(orm_web_client* c, char* name, char* value):
	c.headers.push(strclone(name))
	c.headers.push(strclone(value))


void orm_web_client_free(orm_web_client* c):
	for char* k, char* v in c.cookies: free(v)
	map_free[char*, char*](c.cookies)
	for char* s in c.headers: free(s)
	c.headers.free()
	free(cast(void*, c))


# The client's value of cookie name (borrowed), or 0.
char* orm_web_client_cookie(orm_web_client* c, char* name):
	return c.cookies.get(name, 0)


void orm_web_client_set_cookie(orm_web_client* c, char* name, char* value):
	if (name in c.cookies):
		free(c.cookies[name])
		c.cookies.remove(name)
	if (value != 0): c.cookies[name] = strclone(value)


void orm_web_client_put_header(ServerRequest* req, char* name, char* value):
	char* lower = strclone(name)
	int i = 0
	while (lower[i] != 0):
		lower[i] = tolower(lower[i])
		i = i + 1
	if (lower in req.headers):
		free(req.headers[lower])
		req.headers.remove(lower)
	req.headers[lower] = strclone(value)
	free(lower)


void orm_web_client_store_cookies(orm_web_client* c, ServerResponse* resp):
	for http_header* h in resp.headers:
		if (http_str_ieq(h.name, c"set-cookie") == 0): continue
		Cookie* ck = cookie_parse_set_cookie(h.value)
		if (ck == 0): continue
		if (ck.has_max_age && ck.max_age <= 0): orm_web_client_set_cookie(c, ck.name, 0)
		else: orm_web_client_set_cookie(c, ck.name, ck.value)
		cookie_free(ck)


# Runs one request. target is "/path?query"; body may be 0. headers is an
# optional name, value, ... list for this request only. Returns the
# response (free with server_response_free).
ServerResponse* orm_web_client_request(orm_web_client* c, char* method, char* target, char* content_type, char* body, int body_len, list[char*] headers):
	ServerRequest* req = server_request_new()
	req.method = strclone(method)
	req.target = strclone(target)
	int q = index_of(target, c"?")
	if (q >= 0):
		req.path = substring(target, 0, q)
		req.query = strclone(target + q + 1)
	else:
		req.path = strclone(target)
		req.query = strclone(c"")
	orm_web_client_put_header(req, c"host", c.host)
	if (c.cookies.length > 0):
		string_builder* ck = string_new()
		int first = 1
		for char* k, char* v in c.cookies:
			if (first == 0): string_append(ck, c"; ")
			first = 0
			string_append(ck, k)
			string_append_char(ck, '=')
			string_append(ck, v)
		orm_web_client_put_header(req, c"cookie", ck.data)
		string_free(ck)
	for k2 in range(c.headers.length / 2): orm_web_client_put_header(req, c.headers[k2 * 2], c.headers[k2 * 2 + 1])
	if (headers != 0):
		for j in range(headers.length / 2): orm_web_client_put_header(req, headers[j * 2], headers[j * 2 + 1])
	if (body != 0):
		free(req.body)
		req.body = cast(char*, malloc(body_len + 1))
		for i in range(body_len): req.body[i] = body[i]
		req.body[body_len] = 0
		req.body_len = body_len
		char* len_text = itoa(body_len)
		orm_web_client_put_header(req, c"content-length", len_text)
		free(len_text)
	if (content_type != 0): orm_web_client_put_header(req, c"content-type", content_type)
	ServerResponse* resp = orm_web_app_handle(c.app, req)
	server_request_free(req)
	orm_web_client_store_cookies(c, resp)
	return resp


ServerResponse* orm_web_client_get(orm_web_client* c, char* target):
	return orm_web_client_request(c, c"GET", target, 0, 0, 0, 0)


# POSTs an application/x-www-form-urlencoded body ("a=1&b=x%20y").
ServerResponse* orm_web_client_post_form(orm_web_client* c, char* target, char* urlencoded):
	return orm_web_client_request(c, c"POST", target, c"application/x-www-form-urlencoded", urlencoded, strlen(urlencoded), 0)


# The response body as text (borrowed).
char* orm_web_client_body(ServerResponse* resp):
	if (resp.body == 0): return c""
	return resp.body
