# wbuild: arch_only=x64
# wbuild: deps=tests/orm/templates/
# U4.3 templates and routing without a database (docs/projects/orm/u4_3.md):
# escaping, filters, if / for / include / extends, dotted lookups on maps
# and on ORM rows (heap rows of the library fixture), syntax errors,
# directory loading and caching; path converters, 404 / 405, reverse(),
# includes and mounts.
import tests.orm.fixtures.library_orm_api
import libs.standard.orm.web.middleware
import lib.assert


void expect_text(char* want, char* got):
	if (got == 0 || strcmp(want, got) != 0):
		print(c"want: ")
		println(want)
		print(c"got:  ")
		if (got == 0): println(c"(null)")
		else: println(got)
	assert_strings_equal(want, got)
	free(got)


char* render(orm_tpl_engine* e, char* source, orm_tpl_ctx* ctx):
	char* out = orm_tpl_render_string(e, source, ctx)
	if (out == 0): println(orm_tpl_error(e))
	return out


void test_escaping_and_filters():
	orm_tpl_engine* e = orm_tpl_engine_new(0)
	orm_tpl_ctx* ctx = orm_tpl_ctx_new()
	orm_tpl_set_str(ctx, c"name", c"<b>\"Tom\" & 'Jerry'</b>")
	orm_tpl_set(ctx, c"trusted", orm_tpl_safe(ctx, c"<em>hi</em>"))
	orm_tpl_set_int(ctx, c"n", 42)
	orm_tpl_set_str(ctx, c"empty", c"")
	orm_tpl_set_str(ctx, c"multi", c"a<b\nc")
	orm_tpl_value* l = orm_tpl_list(ctx)
	orm_tpl_push(l, orm_tpl_str(ctx, c"x<y"))
	orm_tpl_push(l, orm_tpl_str(ctx, c"z"))
	orm_tpl_set(ctx, c"items", l)
	expect_text(c"&lt;b&gt;&quot;Tom&quot; &amp; &#x27;Jerry&#x27;&lt;/b&gt;", render(e, c"{{ name }}", ctx))
	expect_text(c"<b>\"Tom\" & 'Jerry'</b>", render(e, c"{{ name|safe }}", ctx))
	expect_text(c"<em>hi</em>|&lt;EM&gt;HI&lt;/EM&gt;", render(e, c"{{ trusted }}|{{ trusted|upper|escape }}", ctx))
	expect_text(c"42 none 2 5", render(e, c"{{ n }} {{ empty|default:\"none\" }} {{ items|length }} {{ \"hello\"|length }}", ctx))
	expect_text(c"x&lt;y, z", render(e, c"{{ items|join:\", \" }}", ctx))
	expect_text(c"a&lt;b<br>c", render(e, c"{{ multi|linebreaksbr }}", ctx))
	expect_text(c"Hello World|hello|a%20b/c", render(e, c"{{ \"hello world\"|title }}|{{ \"HeLLo\"|lower }}|{{ \"a b/c\"|urlencode }}", ctx))
	expect_text(c"abc\xe2\x80\xa6|ab", render(e, c"{{ \"abcdef\"|truncatechars:4 }}|{{ \"ab\"|truncatechars:4 }}", ctx))
	expect_text(c"yes no maybe", render(e, c"{{ n|yesno:\"yes,no,maybe\" }} {{ empty|yesno:\"yes,no,maybe\" }} {{ missing|yesno:\"yes,no,maybe\" }}", ctx))
	expect_text(c"[] [42]", render(e, c"[{{ missing }}] [{{ missing|default:n }}]", ctx))
	orm_tpl_ctx_free(ctx)
	orm_tpl_engine_free(e)


void test_if_for_and_lookups():
	orm_tpl_engine* e = orm_tpl_engine_new(0)
	orm_tpl_ctx* ctx = orm_tpl_ctx_new()
	orm_tpl_value* user = orm_tpl_map(ctx)
	orm_tpl_put_str(ctx, user, c"name", c"ann")
	orm_tpl_put(user, c"admin", orm_tpl_bool(ctx, 1))
	orm_tpl_value* roles = orm_tpl_list(ctx)
	orm_tpl_push(roles, orm_tpl_str(ctx, c"a"))
	orm_tpl_push(roles, orm_tpl_str(ctx, c"b"))
	orm_tpl_push(roles, orm_tpl_str(ctx, c"c"))
	orm_tpl_put(user, c"roles", roles)
	orm_tpl_set(ctx, c"user", user)
	orm_tpl_set_int(ctx, c"n", 3)
	orm_tpl_set(ctx, c"none", orm_tpl_list(ctx))
	expect_text(c"ann b 3", render(e, c"{{ user.name }} {{ user.roles.1 }} {{ user.roles.length }}", ctx))
	expect_text(c"admin", render(e, c"{% if user.admin and not user.banned %}admin{% elif user %}user{% else %}anon{% endif %}", ctx))
	expect_text(c"user", render(e, c"{% if user.banned or n == 4 %}admin{% elif user.name == \"ann\" %}user{% else %}anon{% endif %}", ctx))
	expect_text(c"anon", render(e, c"{% if nobody %}x{% elif n > 3 %}y{% else %}anon{% endif %}", ctx))
	expect_text(c"ok ok ok", render(e, c"{% if n >= 3 %}ok{% endif %} {% if n != 2 %}ok{% endif %} {% if \"b\" < \"c\" %}ok{% endif %}", ctx))
	expect_text(c"1:a(first) 2:b 3:c(last)", render(e, c"{% for r in user.roles %}{{ forloop.counter }}:{{ r }}{% if forloop.first %}(first){% endif %}{% if forloop.last %}(last){% else %} {% endif %}{% endfor %}", ctx))
	expect_text(c"empty!", render(e, c"{% for r in none %}x{% empty %}empty!{% endfor %}", ctx))
	expect_text(c"a1 a2 b1 b2 ", render(e, c"{% for x in outer %}{% endfor %}{% for a in user.roles %}{% if forloop.counter < 3 %}{% for b in user.roles %}{% if forloop.counter < 3 %}{{ a }}{{ forloop.counter }} {% endif %}{% endfor %}{% endif %}{% endfor %}", ctx))
	orm_tpl_ctx_free(ctx)
	orm_tpl_engine_free(e)


void test_row_lookups():
	library_register()
	orm_tpl_engine* e = orm_tpl_engine_new(0)
	Author* a = Author_new()
	a.id = 7
	a.name = c"Ursula <Le Guin>"
	Tag* t1 = Tag_new()
	t1.id = 1
	t1.name = c"sf"
	Tag* t2 = Tag_new()
	t2.id = 2
	t2.name = c"classic"
	Book* b = Book_new()
	b.id = 3
	b.title = c"Earthsea"
	b.author_id = 7
	b.author = a
	b.status = c"pub"
	b.price = c"9.50"
	b.pages = 0
	b.pages__isnull = 1
	b.tags.push(cast(void*, t1))
	b.tags.push(cast(void*, t2))
	a.books.push(cast(void*, b))
	orm_tpl_ctx* ctx = orm_tpl_ctx_new()
	orm_tpl_set(ctx, c"book", orm_tpl_row(ctx, Book_desc(), b))
	orm_tpl_set(ctx, c"author", orm_tpl_row(ctx, Author_desc(), a))
	expect_text(c"3 3 Earthsea pub 9.50 [] 7", render(e, c"{{ book.id }} {{ book.pk }} {{ book.title }} {{ book.status }} {{ book.price }} [{{ book.pages }}] {{ book.author_id }}", ctx))
	expect_text(c"Ursula &lt;Le Guin&gt; sf,classic 1", render(e, c"{{ book.author.name }} {% for t in book.tags %}{{ t.name }}{% if not forloop.last %},{% endif %}{% endfor %} {{ author.books|length }}", ctx))
	expect_text(c"Book object (3) unknown same", render(e, c"{{ book }} {{ book.pages|default:\"unknown\" }} {% if author.books.0 == book %}same{% endif %}", ctx))
	b.author = 0
	expect_text(c"[] 7 []", render(e, c"[{{ book.author.name }}] {{ book.author_id }} [{{ book.nosuchfield }}]", ctx))
	orm_tpl_ctx_free(ctx)
	b.tags.clear()
	a.books.clear()
	Book_free(b)
	Tag_free(t1)
	Tag_free(t2)
	Author_free(a)
	orm_tpl_engine_free(e)


char* fake_url(void* ctx, char* name, map[char*, char*] params):
	if (strcmp(name, c"login") == 0): return strclone(c"/login/")
	if (strcmp(name, c"book_detail") != 0): return 0
	return orm_tpl_concat3(c"/books/", params.get(c"id", c"?"), c"/")


char* fake_csrf(void* ctx):
	return c"tok\"en"


void test_url_and_csrf_hooks():
	orm_tpl_engine* e = orm_tpl_engine_new(0)
	orm_tpl_ctx* ctx = orm_tpl_ctx_new()
	orm_tpl_set_int(ctx, c"id", 5)
	assert1(render(e, c"{% url \"book_detail\" id=id %}", ctx) == 0)
	assert_contains(orm_tpl_error(e), c"no url resolver")
	orm_tpl_set_url(ctx, fake_url, 0)
	orm_tpl_set_csrf(ctx, fake_csrf, 0)
	expect_text(c"/books/5/ <input type=\"hidden\" name=\"csrfmiddlewaretoken\" value=\"tok&quot;en\"> tok&quot;en", render(e, c"{% url \"book_detail\" id=id %} {% csrf_token %} {{ csrf_token }}", ctx))
	assert1(render(e, c"{% url \"nope\" %}", ctx) == 0)
	assert_contains(orm_tpl_error(e), c"no route matches nope")
	orm_tpl_ctx_free(ctx)
	orm_tpl_engine_free(e)


void expect_error(orm_tpl_engine* e, char* source, char* want):
	orm_tpl_ctx* ctx = orm_tpl_ctx_new()
	char* out = orm_tpl_render_string(e, source, ctx)
	if (out != 0): println(out)
	assert1(out == 0)
	if (contains(orm_tpl_error(e), want) == 0):
		print(c"want error: ")
		println(want)
		print(c"got: ")
		println(orm_tpl_error(e))
	assert_contains(orm_tpl_error(e), want)
	orm_tpl_ctx_free(ctx)


void test_syntax_errors():
	orm_tpl_engine* e = orm_tpl_engine_new(0)
	expect_error(e, c"a\n{% if x %}\nb", c"<string>:2: unclosed if")
	expect_error(e, c"{% for x %}{% endfor %}", c"<string>:1: for needs 'for name in value'")
	expect_error(e, c"\n\n{{ x|nope }}", c"<string>:3: unknown filter: nope")
	expect_error(e, c"{% frobnicate %}", c"unknown or unexpected tag: frobnicate")
	expect_error(e, c"{% endif %}", c"unexpected tag: endif")
	expect_error(e, c"{{ x ", c"unclosed variable")
	expect_error(e, c"{% block a %}{% endblock %}{% block a %}{% endblock %}", c"block defined twice: a")
	expect_error(e, c"x{% extends \"base.html\" %}", c"extends must be the first tag")
	expect_error(e, c"{{ x|default }}", c"filter needs an argument: default")
	expect_error(e, c"{% include \"missing.html\" %}", c"template not found: missing.html")
	orm_tpl_engine_free(e)


void test_directory_loading():
	orm_tpl_engine* e = orm_tpl_engine_new(c"tests/orm/templates")
	orm_tpl_ctx* ctx = orm_tpl_ctx_new()
	orm_tpl_set_url(ctx, fake_url, 0)
	orm_tpl_set_str(ctx, c"name", c"<x>")
	char* out = orm_tpl_render(e, c"page.html", ctx)
	asserts(orm_tpl_error(e), out != 0)
	assert_contains(out, c"<title>Layout</title>")
	assert_contains(out, c"<main>[page inner &lt;x&gt;]</main>")
	assert_contains(out, c"Log in")
	free(out)
	assert_equal(3, e.loads)
	out = orm_tpl_render(e, c"page.html", ctx)
	free(out)
	assert_equal(3, e.loads)
	assert1(orm_tpl_render(e, c"../fixtures/library.orm", ctx) == 0)
	assert_contains(orm_tpl_error(e), c"escapes the template directory")
	assert1(orm_tpl_render(e, c"bad_syntax.html", ctx) == 0)
	assert_strings_equal(c"bad_syntax.html:3: unknown filter: nosuchfilter", orm_tpl_error(e))
	assert1(orm_tpl_render(e, c"nope.html", ctx) == 0)
	assert_strings_equal(c"template not found: nope.html", orm_tpl_error(e))
	orm_tpl_engine_clear(e)
	out = orm_tpl_render(e, c"page.html", ctx)
	free(out)
	assert_equal(7, e.loads)
	orm_tpl_ctx_free(ctx)
	orm_tpl_engine_free(e)


# ---------------------------------------------------------------------------
# Routing

ServerResponse* h_named(orm_web_request* r, void* ctx):
	string_builder* s = string_new()
	string_append(s, cast(char*, ctx))
	for char* k, char* v in r.params:
		string_append_char(s, ' ')
		string_append(s, k)
		string_append_char(s, '=')
		string_append(s, v)
	ServerResponse* resp = orm_web_text(200, s.data)
	string_free(s)
	return resp


ServerResponse* h_mount(void* target, orm_web_request* r, char* tail):
	char* body = orm_tpl_concat3(cast(char*, target), c":", tail)
	ServerResponse* resp = orm_web_text(200, body)
	free(body)
	return resp


ServerResponse* h_raw(void* target, ServerRequest* req, char* tail):
	char* body = orm_tpl_concat3(req.method, c" raw:", tail)
	ServerResponse* resp = orm_web_text(200, body)
	free(body)
	return resp


ServerResponse* call(orm_router* rt, char* method, char* path):
	ServerRequest* req = server_request_new()
	req.method = strclone(method)
	req.path = strclone(path)
	req.target = strclone(path)
	orm_web_request* r = orm_web_request_new(req)
	ServerResponse* resp = orm_router_dispatch(rt, r)
	orm_web_request_free(r)
	server_request_free(req)
	return resp


void expect_route(orm_router* rt, char* method, char* path, int status, char* body):
	ServerResponse* resp = call(rt, method, path)
	if (resp.status != status || (body != 0 && strcmp(body, resp.body) != 0)):
		print(method)
		print(c" ")
		print(path)
		print(c" -> ")
		println(itoa(resp.status))
		println(resp.body)
	assert_equal(status, resp.status)
	if (body != 0): assert_strings_equal(body, resp.body)
	server_response_free(resp)


void test_router():
	orm_router* accounts = orm_router_new()
	orm_router_add(accounts, c"GET,POST", c"/login/", h_named, c"login", c"login")
	orm_router_get(accounts, c"/<slug:who>/", h_named, c"profile", c"profile")
	orm_router* rt = orm_router_new()
	orm_router_get(rt, c"/books/", h_named, c"list", c"book_list")
	orm_router_get(rt, c"/books/<int:id>/", h_named, c"detail", c"book_detail")
	orm_router_add(rt, c"PUT, DELETE", c"/books/<int:id>/", h_named, c"write", 0)
	orm_router_get(rt, c"/files/<path:rest>", h_named, c"files", c"files")
	orm_router_get(rt, c"/tags/<name>/", h_named, c"tag", c"tag")
	orm_router_include(rt, c"/org/<int:org>/accounts/", accounts, c"accounts")
	orm_router_mount(rt, c"/api/", h_mount, c"api")
	orm_router_mount_raw(rt, c"/raw", h_raw, 0)
	assert1(orm_router_error(rt) == 0)
	expect_route(rt, c"GET", c"/books/", 200, c"list")
	expect_route(rt, c"HEAD", c"/books/", 200, c"")
	expect_route(rt, c"GET", c"/books/12/", 200, c"detail id=12")
	expect_route(rt, c"DELETE", c"/books/12/", 200, c"write id=12")
	expect_route(rt, c"GET", c"/books/x/", 404, 0)
	expect_route(rt, c"GET", c"/books/12", 404, 0)
	expect_route(rt, c"GET", c"/files/a/b%20c.txt", 200, c"files rest=a/b c.txt")
	expect_route(rt, c"GET", c"/tags/s%C3%A9/", 200, c"tag name=s\xc3\xa9")
	expect_route(rt, c"GET", c"/tags/a/b/", 404, 0)
	expect_route(rt, c"GET", c"/org/4/accounts/login/", 200, c"login org=4")
	expect_route(rt, c"GET", c"/org/4/accounts/ann-1/", 200, c"profile who=ann-1 org=4")
	expect_route(rt, c"GET", c"/api/books/3/", 200, c"api:/books/3/")
	expect_route(rt, c"POST", c"/api/", 200, c"api:")
	expect_route(rt, c"PATCH", c"/raw/x/y", 200, c"PATCH raw:/x/y")
	expect_route(rt, c"GET", c"/rawx", 404, 0)
	ServerResponse* resp = call(rt, c"POST", c"/books/12/")
	assert_equal(405, resp.status)
	assert_strings_equal(c"GET, HEAD, PUT, DELETE", server_response_get_header(resp, c"allow"))
	server_response_free(resp)
	resp = call(rt, c"DELETE", c"/org/4/accounts/login/")
	assert_equal(405, resp.status)
	assert_strings_equal(c"GET, HEAD, POST", server_response_get_header(resp, c"allow"))
	server_response_free(resp)

	expect_text(c"/books/", orm_reverse0(rt, c"book_list"))
	expect_text(c"/books/9/", orm_reverse1_int(rt, c"book_detail", c"id", 9))
	assert1(orm_reverse1(rt, c"book_detail", c"id", c"x") == 0)
	assert1(orm_reverse0(rt, c"book_detail") == 0)
	assert1(orm_reverse1(rt, c"book_list", c"id", c"1") == 0)
	expect_text(c"/files/a/b%20c", orm_reverse1(rt, c"files", c"rest", c"a/b c"))
	expect_text(c"/tags/a%20b%3F/", orm_reverse1(rt, c"tag", c"name", c"a b?"))
	assert1(orm_reverse1(rt, c"tag", c"name", c"a/b") == 0)
	expect_text(c"/org/4/accounts/login/", orm_reverse1(rt, c"accounts:login", c"org", c"4"))
	map[char*, char*] p = new map[char*, char*]
	p[c"org"] = c"4"
	p[c"who"] = c"ann"
	expect_text(c"/org/4/accounts/ann/", orm_reverse(rt, c"accounts:profile", p))
	map_free[char*, char*](p)
	assert1(orm_reverse1(rt, c"login", c"org", c"4") == 0)
	assert1(orm_reverse1(rt, c"other:login", c"org", c"4") == 0)

	orm_router* bad = orm_router_new()
	orm_router_get(bad, c"/x/<float:f>/", h_named, 0, 0)
	assert_strings_equal(c"router: unknown converter in /x/<float:f>/", orm_router_error(bad))
	orm_router* bad2 = orm_router_new()
	orm_router_get(bad2, c"/x/<int:a>/<a>/", h_named, 0, 0)
	assert_strings_equal(c"router: parameter used twice in /x/<int:a>/<a>/", orm_router_error(bad2))
	orm_router_free(bad)
	orm_router_free(bad2)
	orm_router_free(rt)
	orm_router_free(accounts)


int main():
	test_escaping_and_filters()
	test_if_for_and_lookups()
	test_row_lookups()
	test_url_and_csrf_hooks()
	test_syntax_errors()
	test_directory_loading()
	test_router()
	println(c"orm_web_template_test: OK")
	return 0
