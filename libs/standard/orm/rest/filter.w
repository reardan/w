# w-orm REST filtering (unit U3.4, docs/projects/orm/u3_4.md): turns
# whitelisted query parameters into a queryset, HTTP-agnostic.
#
#   orm_filter_set* fs = orm_filter_new(Book_desc())
#   orm_filter_allow(fs, c"title", c"exact,icontains")
#   orm_filter_allow(fs, c"price", c"exact,gte,lte")
#   orm_filter_allow(fs, c"tags__name", c"exact,in")
#   orm_filter_ordering(fs, c"price")
#   orm_filter_search(fs, c"title")
#   orm_params* p = orm_params_parse(c"price__gte=10&ordering=-price&search=dune")
#   json_value* errors = 0
#   orm_queryset* qs = orm_filter_apply(fs, Book_objects(db), p, &errors)
#
# ?path=v (exact) and ?path__lookup=v work only for declared paths and
# lookups; ?ordering=-a,b only for declared ordering fields; ?search=
# ORs icontains over the search fields for every term. Anything else is
# an error object {"param": ["message"]}. Values are checked against the
# field kind (integers, booleans, decimals, dates, enum choices) before
# they reach SQL. Paths through M2M/reverse relations make the queryset
# distinct.
import libs.standard.orm.rest.serializer
import libs.standard.web.urlparse


# ---------------------------------------------------------------------------
# Query parameters

struct orm_param:
	char* key
	char* value


struct orm_params:
	list[orm_param*] items
	list[char*] owned          # strings that must live as long as querysets built from these params


orm_params* orm_params_new():
	orm_params* p = new orm_params()
	p.items = new list[orm_param*]
	p.owned = new list[char*]
	return p


# Appends key=value (both copied).
void orm_params_add(orm_params* p, char* key, char* value):
	orm_param* it = new orm_param()
	it.key = strclone(key)
	it.value = strclone(value)
	p.items.push(it)


void orm_params_remove(orm_params* p, char* key):
	int i = 0
	while (i < p.items.length):
		orm_param* it = p.items[i]
		if (strcmp(it.key, key) == 0):
			free(it.key)
			free(it.value)
			free(cast(void*, it))
			p.items.remove(i)
		else: i = i + 1


# Sets key=value in place of the first key=... (appending when absent)
# and drops any other occurrences; value 0 removes the key.
void orm_params_set(orm_params* p, char* key, char* value):
	if (value == 0):
		orm_params_remove(p, key)
		return
	for i in range(p.items.length):
		orm_param* it = p.items[i]
		if (strcmp(it.key, key) == 0):
			char* copy = strclone(value)
			p.items.remove(i)
			orm_params_remove(p, key)
			free(it.value)
			it.value = copy
			p.items.insert(i, it)
			return
	orm_params_add(p, key, value)


# First value of key (borrowed), or 0.
char* orm_params_get(orm_params* p, char* key):
	if (p == 0): return 0
	for orm_param* it in p.items:
		if (strcmp(it.key, key) == 0): return it.value
	return 0


# Keeps s alive (and frees it) with p.
char* orm_params_own(orm_params* p, char* s):
	p.owned.push(s)
	return s


orm_params* orm_params_clone(orm_params* p):
	orm_params* c = orm_params_new()
	if (p == 0): return c
	for orm_param* it in p.items: orm_params_add(c, it.key, it.value)
	return c


void orm_params_free(orm_params* p):
	if (p == 0): return
	for orm_param* it in p.items:
		free(it.key)
		free(it.value)
		free(cast(void*, it))
	p.items.free()
	for char* s in p.owned: free(s)
	p.owned.free()
	free(cast(void*, p))


# Percent-decodes one key or value, '+' meaning space. 0 when invalid.
char* orm_params_decode(char* raw):
	char* spaced = strclone(raw)
	int n = strlen(spaced)
	for i in range(n):
		if (spaced[i] == '+'): spaced[i] = ' '
	char* out = url_unquote(spaced)
	free(spaced)
	return out


# Parses "a=1&b=x%20y" (a leading '?' is skipped). Pairs with invalid
# percent escapes are dropped; a pair without '=' has an empty value.
orm_params* orm_params_parse(char* query):
	orm_params* p = orm_params_new()
	if (query == 0): return p
	if (query[0] == '?'): query = query + 1
	list[char*] pairs = split(query, '&')
	for char* pair in pairs:
		if (pair[0] != 0):
			int eq = index_of(pair, c"=")
			char* kraw = 0
			char* vraw = 0
			if (eq >= 0):
				kraw = substring(pair, 0, eq)
				vraw = strclone(pair + eq + 1)
			else:
				kraw = strclone(pair)
				vraw = strclone(c"")
			char* k = orm_params_decode(kraw)
			char* v = orm_params_decode(vraw)
			if (k != 0 && v != 0):
				orm_param* it = new orm_param()
				it.key = k
				it.value = v
				p.items.push(it)
			else:
				if (k != 0): free(k)
				if (v != 0): free(v)
			free(kraw)
			free(vraw)
		free(pair)
	pairs.free()
	return p


# Owned "a=1&b=x%20y" (values percent-encoded).
char* orm_params_encode(orm_params* p):
	string_builder* s = string_new()
	for i in range(p.items.length):
		orm_param* it = p.items[i]
		if (i > 0): string_append_char(s, '&')
		char* k = url_quote(it.key)
		char* v = url_quote(it.value)
		string_append(s, k)
		string_append_char(s, '=')
		string_append(s, v)
		free(k)
		free(v)
	char* out = s.data
	free(s)
	return out


# Owned "base?params" ("base" alone when there are none).
char* orm_params_url(char* base, orm_params* p):
	if (p == 0 || p.items.length == 0): return strclone(base)
	char* q = orm_params_encode(p)
	char* out = orm_rest_concat3(base, c"?", q)
	free(q)
	return out


# ---------------------------------------------------------------------------
# Filter sets

struct orm_filter_rule:
	char* path
	list[char*] lookups
	orm_field_desc* field      # terminal column field
	int many                   # the path crosses an M2M/reverse relation


struct orm_filter_set:
	orm_model_desc* model
	list[orm_filter_rule*] rules
	list[char*] ordering_fields
	list[char*] search_fields
	int search_many
	list[char*] reserved       # params ignored here (pagination, format, ...)
	char* search_param
	char* ordering_param
	char* error                # first configuration error, or 0
	list[char*] owned


orm_filter_set* orm_filter_new(orm_model_desc* m):
	orm_filter_set* fs = new orm_filter_set()
	fs.model = m
	fs.rules = new list[orm_filter_rule*]
	fs.ordering_fields = new list[char*]
	fs.search_fields = new list[char*]
	fs.reserved = new list[char*]
	fs.search_param = c"search"
	fs.ordering_param = c"ordering"
	fs.owned = new list[char*]
	return fs


void orm_filter_free(orm_filter_set* fs):
	if (fs == 0): return
	for orm_filter_rule* r in fs.rules:
		for char* l in r.lookups: free(l)
		r.lookups.free()
		free(cast(void*, r))
	fs.rules.free()
	fs.ordering_fields.free()
	fs.search_fields.free()
	fs.reserved.free()
	for char* s in fs.owned: free(s)
	fs.owned.free()
	if (fs.error != 0): free(fs.error)
	free(cast(void*, fs))


char* orm_filter_error(orm_filter_set* fs):
	return fs.error


void orm_filter_fail(orm_filter_set* fs, char* a, char* b, char* c):
	if (fs.error != 0): return
	string_builder* s = string_new()
	string_append(s, a)
	string_append(s, b)
	string_append(s, c)
	fs.error = s.data
	free(s)


# The column field at the end of path (following FK, M2M and reverse
# relations), with *many set when a hop is multi-valued; 0 otherwise.
orm_field_desc* orm_rest_path_field(orm_model_desc* m, char* path, int* many):
	many[0] = 0
	list[char*] parts = orm_path_split(path)
	orm_field_desc* out = 0
	for i in range(parts.length):
		if (m == 0): break
		orm_field_desc* fd = orm_model_field(m, parts[i])
		if (fd == 0): break
		if (i == parts.length - 1):
			if (orm_field_has_column(fd)): out = fd
		else if (fd.kind == ORM_FK || fd.kind == ORM_M2M || fd.kind == ORM_REVERSE_FK):
			if (fd.kind != ORM_FK): many[0] = 1
			m = orm_field_target(fd)
		else: m = 0
	for char* p in parts: free(p)
	parts.free()
	return out


# Allows ?path=... and ?path__<lookup>=... for each lookup in the comma
# separated list ("exact,icontains,in"). "exact" covers the bare ?path=.
orm_filter_set* orm_filter_allow(orm_filter_set* fs, char* path, char* lookups):
	int many = 0
	orm_field_desc* fd = orm_rest_path_field(fs.model, path, &many)
	if (fd == 0):
		orm_filter_fail(fs, c"filter: '", path, c"' is not a field path")
		return fs
	orm_filter_rule* r = new orm_filter_rule()
	r.path = path
	r.field = fd
	r.many = many
	r.lookups = split(lookups, ',')
	for char* l in r.lookups:
		if (orm_is_lookup(l) == 0): orm_filter_fail(fs, c"filter: unknown lookup '", l, c"'")
	fs.rules.push(r)
	return fs


# Allows ?ordering=path and ?ordering=-path.
orm_filter_set* orm_filter_ordering(orm_filter_set* fs, char* path):
	int many = 0
	if (orm_rest_path_field(fs.model, path, &many) == 0 || many):
		orm_filter_fail(fs, c"filter: ordering '", path, c"' is not a single-valued field path")
		return fs
	fs.ordering_fields.push(path)
	return fs


# Adds path to the ?search= fields (icontains, ORed).
orm_filter_set* orm_filter_search(orm_filter_set* fs, char* path):
	int many = 0
	orm_field_desc* fd = orm_rest_path_field(fs.model, path, &many)
	if (fd == 0 || orm_field_is_text_backed(fd) == 0):
		orm_filter_fail(fs, c"filter: search field '", path, c"' is not a text field path")
		return fs
	if (many): fs.search_many = 1
	fs.search_fields.push(path)
	return fs


# Parameters this filter set ignores (they belong to pagination etc.).
orm_filter_set* orm_filter_ignore(orm_filter_set* fs, char* param):
	fs.reserved.push(param)
	return fs


int orm_filter_is_reserved(orm_filter_set* fs, char* key):
	for char* r in fs.reserved:
		if (strcmp(r, key) == 0): return 1
	return 0


orm_filter_rule* orm_filter_rule_for(orm_filter_set* fs, char* path):
	for orm_filter_rule* r in fs.rules:
		if (strcmp(r.path, path) == 0): return r
	return 0


int orm_filter_rule_allows(orm_filter_rule* r, char* lookup):
	for char* l in r.lookups:
		if (strcmp(l, lookup) == 0): return 1
	return 0


# Checks one filter value against the field. Returns the value to bind
# (borrowed or owned by params), or 0 with *err set (a literal).
char* orm_filter_value(orm_params* params, orm_field_desc* fd, char* lookup, char* value, char** err):
	err[0] = 0
	int k = fd.kind
	if (strcmp(lookup, c"isnull") == 0):
		int b = 0
		if (sql_parse_bool(value, &b) == 0):
			err[0] = c"Enter a valid boolean."
			return 0
		if (b): return c"1"
		return c"0"
	int text_lookup = strcmp(lookup, c"contains") == 0 || strcmp(lookup, c"icontains") == 0 || strcmp(lookup, c"startswith") == 0
	text_lookup = text_lookup || strcmp(lookup, c"istartswith") == 0 || strcmp(lookup, c"endswith") == 0 || strcmp(lookup, c"iendswith") == 0
	text_lookup = text_lookup || strcmp(lookup, c"iexact") == 0 || strcmp(lookup, c"regex") == 0
	if (text_lookup): return value
	int iv = 0
	if (k == ORM_INT || k == ORM_BIGINT || k == ORM_FK):
		if (sql_parse_int(value, &iv) == 0):
			err[0] = c"Enter a whole number."
			return 0
		return value
	if (k == ORM_BOOL):
		if (sql_parse_bool(value, &iv) == 0):
			err[0] = c"Enter a valid boolean."
			return 0
		if (iv): return c"1"
		return c"0"
	if (k == ORM_DECIMAL || k == ORM_FLOAT):
		if (sql_decimal_valid(value) == 0):
			err[0] = c"Enter a number."
			return 0
		return value
	if (k == ORM_DATETIME):
		datetime dt
		char* norm = orm_params_own(params, orm_ser_datetime_text(value))
		if (sql_parse_datetime(norm, &dt) == 0):
			err[0] = c"Enter a valid date/time."
			return 0
		return norm
	if (k == ORM_DATE):
		date d
		if (sql_parse_date(value, &d) == 0):
			err[0] = c"Enter a valid date."
			return 0
		return value
	if (k == ORM_ENUM):
		for char* choice in fd.enum_values:
			if (strcmp(choice, value) == 0): return value
		err[0] = c"Select a valid choice."
		return 0
	return value


void orm_filter_value_error(json_value* errors, char* key, char* err, char* value):
	if (strcmp(err, c"Select a valid choice.") == 0):
		char* msg = orm_rest_concat3(c"Select a valid choice. ", value, c" is not one of the available choices.")
		orm_rest_error_add(errors, key, msg)
		free(msg)
		return
	orm_rest_error_add(errors, key, err)


# One ?key=value filter as a where node, or 0 with an error added.
orm_where* orm_filter_param_where(orm_filter_set* fs, orm_params* params, char* key, char* value, json_value* errors, int* many):
	orm_filter_rule* rule = orm_filter_rule_for(fs, key)
	char* lookup = c"exact"
	if (rule == 0):
		int at = rindex_of(key, c"__")
		if (at > 0):
			char* tail = key + at + 2
			if (orm_is_lookup(tail)):
				char* path = substring(key, 0, at)
				rule = orm_filter_rule_for(fs, path)
				free(path)
				if (rule != 0): lookup = tail
	if (rule == 0):
		orm_rest_error_add(errors, key, c"Unknown filter parameter.")
		return 0
	if (orm_filter_rule_allows(rule, lookup) == 0):
		char* msg = orm_rest_concat3(c"Lookup \"", lookup, c"\" is not allowed for this field.")
		orm_rest_error_add(errors, key, msg)
		free(msg)
		return 0
	if (rule.many): many[0] = 1
	char* err = 0
	if (strcmp(lookup, c"in") == 0 || strcmp(lookup, c"range") == 0):
		list[char*] parts = split(value, ',')
		list[char*] vals = new list[char*]
		for char* part in parts:
			orm_params_own(params, part)
			if (err == 0):
				char* checked = orm_filter_value(params, rule.field, c"exact", part, &err)
				if (checked != 0): vals.push(checked)
				else: orm_filter_value_error(errors, key, err, part)
		parts.free()
		orm_where* w = 0
		if (err == 0):
			if (strcmp(lookup, c"in") == 0): w = q_in(rule.path, vals)
			else if (vals.length == 2): w = q_range(rule.path, vals[0], vals[1])
			else: orm_rest_error_add(errors, key, c"Enter two values separated by a comma.")
		vals.free()
		return w
	char* checked = orm_filter_value(params, rule.field, lookup, value, &err)
	if (checked == 0):
		orm_filter_value_error(errors, key, err, value)
		return 0
	return q_lookup(rule.path, lookup, checked)


# ?search=: every whitespace/comma separated term must match one of the
# search fields (icontains).
orm_where* orm_filter_search_where(orm_filter_set* fs, orm_params* params, char* value):
	orm_where* all = 0
	list[char*] terms = split(value, 0)
	for char* t0 in terms:
		list[char*] sub = split(t0, ',')
		for char* t in sub:
			if (t[0] == 0):
				free(t)
				continue
			orm_params_own(params, t)
			orm_where* any = 0
			for char* path in fs.search_fields: any = q_or(any, q_icontains(path, t))
			all = q_and(all, any)
		sub.free()
		free(t0)
	terms.free()
	return all


int orm_filter_ordering_allowed(orm_filter_set* fs, char* name):
	for char* o in fs.ordering_fields:
		if (strcmp(o, name) == 0): return 1
	return 0


# The queryset filtered/ordered by params, or 0 with *errors_out set to
# an owned error object ({"param": ["message"]}, or {"detail": ...} for a
# misconfigured filter set). Empty values are ignored, as django-filter
# does. params must outlive every evaluation of the returned queryset
# (bound values point into it).
orm_queryset* orm_filter_apply(orm_filter_set* fs, orm_queryset* qs, orm_params* params, json_value** errors_out):
	errors_out[0] = 0
	if (fs.error != 0):
		errors_out[0] = orm_rest_detail(fs.error)
		return 0
	json_value* errors = json_object()
	orm_where* where = 0
	int many = 0
	list[char*] ordering = 0
	if (params != 0):
		for orm_param* it in params.items:
			char* key = it.key
			char* value = it.value
			if (orm_filter_is_reserved(fs, key)): continue
			if (strcmp(key, fs.ordering_param) == 0 && fs.ordering_fields.length > 0):
				if (value[0] == 0): continue
				list[char*] terms = split(value, ',')
				ordering = new list[char*]
				for char* term in terms:
					orm_params_own(params, term)
					char* name = term
					if (name[0] == '-'): name = name + 1
					if (orm_filter_ordering_allowed(fs, name)): ordering.push(term)
					else:
						char* msg = orm_rest_concat3(c"Invalid ordering field \"", name, c"\".")
						orm_rest_error_add(errors, key, msg)
						free(msg)
				terms.free()
				continue
			if (strcmp(key, fs.search_param) == 0 && fs.search_fields.length > 0):
				if (value[0] == 0): continue
				orm_where* sw = orm_filter_search_where(fs, params, value)
				if (sw != 0):
					where = q_and(where, sw)
					if (fs.search_many): many = 1
				continue
			if (value[0] == 0):
				if (orm_filter_rule_for(fs, key) != 0): continue
			orm_where* w = orm_filter_param_where(fs, params, key, value, errors, &many)
			if (w != 0): where = q_and(where, w)
	if (orm_rest_errors_empty(errors) == 0):
		if (ordering != 0): ordering.free()
		errors_out[0] = errors
		return 0
	json_free(errors)
	orm_queryset* out = qs
	if (where != 0): out = out.filter(where)
	else: out = orm_queryset_clone(out)
	if (many): out = out.distinct()
	if (ordering != 0):
		out = out.order_clear()
		for char* spec in ordering: out = out.order_by(spec)
		ordering.free()
	return out


# Same, from a raw query string; the parsed params are returned in
# *params_out (free them after the queryset is no longer used).
orm_queryset* orm_filter_apply_query(orm_filter_set* fs, orm_queryset* qs, char* query, orm_params** params_out, json_value** errors_out):
	orm_params* p = orm_params_parse(query)
	params_out[0] = p
	return orm_filter_apply(fs, qs, p, errors_out)
