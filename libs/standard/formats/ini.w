# INI configuration files: a subset of Python's configparser
# (ConfigParser with its defaults: strict=True, empty_lines_in_values=True,
# allow_no_value=False, comment_prefixes ('#', ';'), no inline comments,
# delimiters ('=', ':'), default_section "DEFAULT").
#
# Reading (ini_parse / ini_read_string), Python _read semantics:
#   [section]          header; the name is everything between the first
#                      '[' and the last ']' of the stripped line, case
#                      sensitive. "[DEFAULT]" holds fallbacks for every
#                      section and is not listed by ini_sections.
#   key = value        or "key: value"; the key ends at the first '=' or
#   key: value         ':'. Keys are lowercased (optionxform); values
#                      are stripped.
#   # comment          '#' or ';' as the first non-blank character; only
#   ; comment          whole-line comments (a '#' inside a value is kept).
#   indented lines     a line indented deeper than its key line continues
#                      the value, joined with '\n'. Blank lines inside a
#                      value are kept; trailing ones are dropped.
#   errors             a key line before any header, a line that is
#                      neither header nor key, an empty key, a section
#                      repeated within one read, a key repeated within
#                      one section of one read. Parsing stops at the
#                      first error; ini_error / ini_error_line /
#                      ini_error_message describe it.
# A second ini_read_string into the same config merges like Python's
# read_string: sections reopen and keys are overwritten without error.
#
# Values are raw (interpolation is off, like RawConfigParser);
# ini_get_interpolated applies BasicInterpolation's "%(name)s" and "%%"
# on request. ini_write emits Python's ConfigParser.write layout
# ("key = value", continuation lines indented with a tab, a blank line
# after each section, DEFAULT first) and parses back to the same config,
# as long as no line of a value has surrounding whitespace or starts
# with a comment prefix (the same limits as Python's writer).
#
# Ownership: the config owns every name and value. ini_get returns a
# borrowed pointer valid until the option is set or removed or the
# config freed; ini_sections / ini_options return a new list (free it
# with .free()) of borrowed names; ini_write and ini_get_interpolated
# return malloc'd strings the caller frees.
import lib.lib
import lib.format


const int INI_OK = 0
const int INI_NO_SECTION = 1            # NoSectionError
const int INI_NO_OPTION = 2             # NoOptionError
const int INI_BAD_VALUE = 3             # ValueError from a typed getter
const int INI_DUPLICATE_SECTION = 4     # DuplicateSectionError
const int INI_DUPLICATE_OPTION = 5      # DuplicateOptionError
const int INI_MISSING_SECTION_HEADER = 6  # MissingSectionHeaderError
const int INI_PARSE_ERROR = 7           # ParsingError
const int INI_INTERPOLATION_MISSING = 8   # InterpolationMissingOptionError
const int INI_INTERPOLATION_DEPTH = 9   # InterpolationDepthError
const int INI_INTERPOLATION_SYNTAX = 10   # InterpolationSyntaxError
const int INI_INVALID_NAME = 11         # a section or key ini_write could not round-trip

const int INI_MAX_INTERPOLATION_DEPTH = 10


struct ini_option:
	char* name
	char* value


struct ini_section:
	char* name
	list[ini_option*] options


struct ini_config:
	ini_section* defaults
	list[ini_section*] sections
	int error
	int error_line
	char* error_message


char* ini_status_name(int status):
	switch status:
		case INI_OK: return c"ok"
		case INI_NO_SECTION: return c"no such section"
		case INI_NO_OPTION: return c"no such option"
		case INI_BAD_VALUE: return c"bad value"
		case INI_DUPLICATE_SECTION: return c"duplicate section"
		case INI_DUPLICATE_OPTION: return c"duplicate option"
		case INI_MISSING_SECTION_HEADER: return c"missing section header"
		case INI_PARSE_ERROR: return c"parse error"
		case INI_INTERPOLATION_MISSING: return c"interpolation: missing option"
		case INI_INTERPOLATION_DEPTH: return c"interpolation: too deep"
		case INI_INTERPOLATION_SYNTAX: return c"interpolation: bad syntax"
		case INI_INVALID_NAME: return c"invalid name"
	return c"unknown"


# ---- small string helpers (ASCII; the config owns what they return) ----

int ini_is_space(int c):
	return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == 11 || c == 12


int ini_lower(int c):
	if c >= 'A' && c <= 'Z': return c + 32
	return c


char* ini_substr(char* s, int start, int end):
	int n = end - start
	char* out = cast(char*, malloc(n + 1))
	for int i in range(n):
		out[i] = s[start + i]
	out[n] = 0
	return out


# s[start:end] with surrounding whitespace removed, as a new string.
char* ini_strip_range(char* s, int start, int end):
	while start < end && ini_is_space(s[start]): start++
	while end > start && ini_is_space(s[end - 1]): end--
	return ini_substr(s, start, end)


char* ini_lower_copy(char* s):
	int n = strlen(s)
	char* out = cast(char*, malloc(n + 1))
	for int i in range(n):
		out[i] = ini_lower(s[i])
	out[n] = 0
	return out


int ini_streq(char* a, char* b):
	return strcmp(a, b) == 0


# a + sep + b (sep may be 0); frees a.
char* ini_concat(char* a, int sep, char* b, int b_len):
	int an = strlen(a)
	int extra = 0
	if sep: extra = 1
	char* out = cast(char*, malloc(an + extra + b_len + 1))
	for int i in range(an):
		out[i] = a[i]
	if sep: out[an] = sep
	for int j in range(b_len):
		out[an + extra + j] = b[j]
	out[an + extra + b_len] = 0
	free(a)
	return out


# Drop trailing whitespace in place.
void ini_rstrip_in_place(char* s):
	int n = strlen(s)
	while n > 0 && ini_is_space(s[n - 1]): n--
	s[n] = 0


# A growable output buffer for ini_write / interpolation.
struct ini_buf:
	char* data
	int length
	int capacity


void ini_buf_init(ini_buf* b):
	b.capacity = 64
	b.length = 0
	b.data = cast(char*, malloc(b.capacity))
	b.data[0] = 0


void ini_buf_add(ini_buf* b, char* s, int n):
	if b.length + n + 1 > b.capacity:
		int cap = b.capacity * 2
		while cap < b.length + n + 1: cap = cap * 2
		b.data = realloc(b.data, b.capacity, cap)
		b.capacity = cap
	for int i in range(n):
		b.data[b.length + i] = s[i]
	b.length = b.length + n
	b.data[b.length] = 0


void ini_buf_str(ini_buf* b, char* s):
	ini_buf_add(b, s, strlen(s))


# ---- construction and teardown ----

ini_section* ini_section_new(char* name):
	ini_section* sec = new ini_section
	sec.name = strclone(name)
	sec.options = new list[ini_option*]
	return sec


void ini_option_free(ini_option* opt):
	free(opt.name)
	free(opt.value)
	free(opt)


void ini_section_free(ini_section* sec):
	for ini_option* opt in sec.options:
		ini_option_free(opt)
	sec.options.free()
	free(sec.name)
	free(sec)


ini_config* ini_new():
	ini_config* cfg = new ini_config
	cfg.defaults = ini_section_new(c"DEFAULT")
	cfg.sections = new list[ini_section*]
	cfg.error = INI_OK
	cfg.error_line = 0
	cfg.error_message = 0
	return cfg


void ini_free(ini_config* cfg):
	if cfg == 0: return
	ini_section_free(cfg.defaults)
	for ini_section* sec in cfg.sections:
		ini_section_free(sec)
	cfg.sections.free()
	if cfg.error_message: free(cfg.error_message)
	free(cfg)


# The status of the last read (INI_OK when it succeeded).
int ini_error(ini_config* cfg):
	return cfg.error


# 1-based line of the last read's error, 0 when there was none.
int ini_error_line(ini_config* cfg):
	return cfg.error_line


# "line N: ..." for the last read's error, "" when there was none.
char* ini_error_message(ini_config* cfg):
	if cfg.error_message == 0: return c""
	return cfg.error_message


# ---- lookup ----

ini_section* ini_find_section(ini_config* cfg, char* name):
	for ini_section* sec in cfg.sections:
		if ini_streq(sec.name, name): return sec
	return 0


int ini_find_section_index(ini_config* cfg, char* name):
	for int i in range(cfg.sections.length):
		if ini_streq(cfg.sections[i].name, name): return i
	return -1


# key must already be lowercased.
int ini_find_option_index(ini_section* sec, char* key):
	for int i in range(sec.options.length):
		if ini_streq(sec.options[i].name, key): return i
	return -1


ini_option* ini_find_option(ini_section* sec, char* key):
	int i = ini_find_option_index(sec, key)
	if i < 0: return 0
	return sec.options[i]


int ini_is_default_name(char* name):
	return name == 0 || name[0] == 0 || ini_streq(name, c"DEFAULT")


# The option for (section, key) with DEFAULT fallback; *status gets
# INI_OK, INI_NO_SECTION or INI_NO_OPTION. key is lowercased here.
ini_option* ini_lookup(ini_config* cfg, char* section, char* key, int* status):
	char* lk = ini_lower_copy(key)
	ini_option* found = 0
	int st = INI_OK
	if ini_is_default_name(section):
		found = ini_find_option(cfg.defaults, lk)
	else:
		ini_section* sec = ini_find_section(cfg, section)
		if sec == 0:
			st = INI_NO_SECTION
		else:
			found = ini_find_option(sec, lk)
			if found == 0: found = ini_find_option(cfg.defaults, lk)
	free(lk)
	if st == INI_OK && found == 0: st = INI_NO_OPTION
	if status: *status = st
	return found


# Section names in file order, DEFAULT excluded (Python sections()).
list[char*] ini_sections(ini_config* cfg):
	list[char*] out = new list[char*]
	for ini_section* sec in cfg.sections:
		out.push(sec.name)
	return out


# The section's keys followed by DEFAULT keys it does not override
# (Python options()); 0 when the section does not exist (DEFAULT
# included, as in Python).
list[char*] ini_options(ini_config* cfg, char* section):
	ini_section* sec = ini_find_section(cfg, section)
	if sec == 0: return 0
	list[char*] out = new list[char*]
	for ini_option* opt in sec.options:
		out.push(opt.name)
	for ini_option* d in cfg.defaults.options:
		if ini_find_option_index(sec, d.name) < 0: out.push(d.name)
	return out


# Python has_section: DEFAULT is never reported.
int ini_has_section(ini_config* cfg, char* section):
	if section == 0: return 0
	return ini_find_section(cfg, section) != 0


# Python has_option: an empty/0 or "DEFAULT" section asks DEFAULT alone;
# otherwise the section's keys or DEFAULT's, false for a missing section.
int ini_has_option(ini_config* cfg, char* section, char* key):
	int st = INI_OK
	ini_option* opt = ini_lookup(cfg, section, key, &st)
	return opt != 0


# The raw value, or 0 when the section or key is missing.
char* ini_get(ini_config* cfg, char* section, char* key):
	ini_option* opt = ini_lookup(cfg, section, key, 0)
	if opt == 0: return 0
	return opt.value


# The raw value, or fallback when the section or key is missing.
char* ini_get_or(ini_config* cfg, char* section, char* key, char* fallback):
	char* v = ini_get(cfg, section, key)
	if v == 0: return fallback
	return v


# Python int() on the value: optional sign, decimal digits, single
# underscores between digits. INI_BAD_VALUE on anything else or when the
# number does not fit in an int (the word size).
int ini_parse_int(char* s, int* out):
	int i = 0
	int neg = 0
	if s[i] == '+' || s[i] == '-':
		if s[i] == '-': neg = 1
		i++
	if s[i] < '0' || s[i] > '9': return INI_BAD_VALUE
	int limit = ~(1 << (__word_size__ * 8 - 1))   # INT_MAX
	int v = 0                                      # accumulated as -|n|
	while s[i] != 0:
		int c = s[i]
		if c == '_':
			if s[i + 1] < '0' || s[i + 1] > '9': return INI_BAD_VALUE
			i++
			continue
		if c < '0' || c > '9': return INI_BAD_VALUE
		int d = c - '0'
		# v * 10 - d must stay >= -INT_MAX - 1
		if v < (-limit - 1 + d) / 10: return INI_BAD_VALUE
		if v * 10 < -limit - 1 + d: return INI_BAD_VALUE
		v = v * 10 - d
		i++
	if neg == 0:
		if v < -limit: return INI_BAD_VALUE
		v = -v
	*out = v
	return INI_OK


int ini_get_int(ini_config* cfg, char* section, char* key, int* out):
	int st = INI_OK
	ini_option* opt = ini_lookup(cfg, section, key, &st)
	if opt == 0: return st
	return ini_parse_int(opt.value, out)


# Python's BOOLEAN_STATES, case-insensitive: 1 yes true on -> 1,
# 0 no false off -> 0; INI_BAD_VALUE otherwise.
int ini_parse_bool(char* s, int* out):
	char* l = ini_lower_copy(s)
	int st = INI_OK
	if ini_streq(l, c"1") || ini_streq(l, c"yes") || ini_streq(l, c"true") || ini_streq(l, c"on"):
		*out = 1
	elif ini_streq(l, c"0") || ini_streq(l, c"no") || ini_streq(l, c"false") || ini_streq(l, c"off"):
		*out = 0
	else:
		st = INI_BAD_VALUE
	free(l)
	return st


int ini_get_bool(ini_config* cfg, char* section, char* key, int* out):
	int st = INI_OK
	ini_option* opt = ini_lookup(cfg, section, key, &st)
	if opt == 0: return st
	return ini_parse_bool(opt.value, out)


int ini_is_digit(int c):
	return c >= '0' && c <= '9'


# Python float() on the value (as a float32, the float every target
# has): decimal or exponent form, "5." and ".5", inf/infinity/nan in any
# case, single underscores between digits.
int ini_parse_float(char* s, float* out):
	int n = strlen(s)
	if n == 0: return INI_BAD_VALUE
	char* t = cast(char*, malloc(n + 2))
	int k = 0
	int st = INI_OK
	for int i in range(n):
		if s[i] == '_':
			if i == 0 || !ini_is_digit(s[i - 1]) || !ini_is_digit(s[i + 1]): st = INI_BAD_VALUE
		else:
			t[k] = s[i]
			k++
	t[k] = 0
	# "5." / "5.e3": the parser wants a digit after the point.
	if st == INI_OK:
		int consumed = 0
		float f = parse_float(t, &consumed)
		if consumed > 0 && t[consumed] == '.' && consumed > 0 && ini_is_digit(t[consumed - 1]):
			# drop the bare point and retry ("5." == "5", "5.e3" == "5e3")
			int j = consumed
			while t[j] != 0:
				t[j] = t[j + 1]
				j++
			f = parse_float(t, &consumed)
		if consumed == 0 || t[consumed] != 0: st = INI_BAD_VALUE
		else: *out = f
	free(t)
	return st


int ini_get_float(ini_config* cfg, char* section, char* key, float* out):
	int st = INI_OK
	ini_option* opt = ini_lookup(cfg, section, key, &st)
	if opt == 0: return st
	return ini_parse_float(opt.value, out)


# ---- BasicInterpolation ----

int ini_has_percent(char* s):
	int i = 0
	while s[i] != 0:
		if s[i] == '%': return 1
		i++
	return 0


# Python BasicInterpolation._interpolate_some: appends rest to b,
# expanding "%%" and "%(name)s" from section + DEFAULT.
int ini_interpolate_some(ini_config* cfg, char* section, ini_buf* b, char* rest, int depth):
	if depth > INI_MAX_INTERPOLATION_DEPTH: return INI_INTERPOLATION_DEPTH
	int i = 0
	while rest[i] != 0:
		if rest[i] != '%':
			ini_buf_add(b, &rest[i], 1)
			i++
			continue
		int c = rest[i + 1]
		if c == '%':
			ini_buf_add(b, c"%", 1)
			i = i + 2
		elif c == '(':
			int j = i + 2
			while rest[j] != 0 && rest[j] != ')': j++
			if j == i + 2 || rest[j] != ')' || rest[j + 1] != 's': return INI_INTERPOLATION_SYNTAX
			char* name = ini_substr(rest, i + 2, j)
			int st = INI_OK
			ini_option* opt = ini_lookup(cfg, section, name, &st)
			free(name)
			if opt == 0: return INI_INTERPOLATION_MISSING
			if ini_has_percent(opt.value):
				int sub = ini_interpolate_some(cfg, section, b, opt.value, depth + 1)
				if sub != INI_OK: return sub
			else:
				ini_buf_str(b, opt.value)
			i = j + 2
		else:
			return INI_INTERPOLATION_SYNTAX
	return INI_OK


# The value with BasicInterpolation applied (malloc'd; free it), or 0
# with *status set: INI_NO_SECTION / INI_NO_OPTION, or one of the
# INI_INTERPOLATION_* errors. References resolve in the same section,
# then DEFAULT, case-insensitively; nesting deeper than 10 fails.
char* ini_get_interpolated(ini_config* cfg, char* section, char* key, int* status):
	int st = INI_OK
	ini_option* opt = ini_lookup(cfg, section, key, &st)
	if opt == 0:
		if status: *status = st
		return 0
	ini_buf b
	ini_buf_init(&b)
	st = ini_interpolate_some(cfg, section, &b, opt.value, 1)
	if status: *status = st
	if st != INI_OK:
		free(b.data)
		return 0
	return b.data


# ---- mutation ----

int ini_valid_section_name(char* name):
	if name == 0 || name[0] == 0: return 0
	int n = strlen(name)
	for int k in range(n):
		if name[k] == '\n' || name[k] == '\r': return 0
	return 1


# Python add_section: INI_DUPLICATE_SECTION when it exists,
# INI_BAD_VALUE for "DEFAULT", INI_INVALID_NAME for an empty name or one
# with a line break.
int ini_add_section(ini_config* cfg, char* name):
	if name != 0 && ini_streq(name, c"DEFAULT"): return INI_BAD_VALUE
	if !ini_valid_section_name(name): return INI_INVALID_NAME
	if ini_find_section(cfg, name) != 0: return INI_DUPLICATE_SECTION
	cfg.sections.push(ini_section_new(name))
	return INI_OK


# A key that reads back as itself: non-empty, no surrounding whitespace,
# no '=' ':' or line break, not starting with '[' '#' ';'.
int ini_valid_key(char* key):
	if key == 0 || key[0] == 0: return 0
	int n = strlen(key)
	if ini_is_space(key[0]) || ini_is_space(key[n - 1]): return 0
	if key[0] == '[' || key[0] == '#' || key[0] == ';': return 0
	for int i in range(n):
		int c = key[i]
		if c == '=' || c == ':' || c == '\n' || c == '\r': return 0
	return 1


ini_section* ini_target_section(ini_config* cfg, char* section):
	if ini_is_default_name(section): return cfg.defaults
	return ini_find_section(cfg, section)


# Python set: the section (or DEFAULT for 0/""/"DEFAULT") must exist;
# the key is lowercased. The value is copied.
int ini_set(ini_config* cfg, char* section, char* key, char* value):
	ini_section* sec = ini_target_section(cfg, section)
	if sec == 0: return INI_NO_SECTION
	if !ini_valid_key(key): return INI_INVALID_NAME
	char* lk = ini_lower_copy(key)
	ini_option* opt = ini_find_option(sec, lk)
	if opt != 0:
		free(lk)
		free(opt.value)
		opt.value = strclone(value)
		return INI_OK
	opt = new ini_option
	opt.name = lk
	opt.value = strclone(value)
	sec.options.push(opt)
	return INI_OK


# 1 when the section existed and was removed (never DEFAULT).
int ini_remove_section(ini_config* cfg, char* section):
	if section == 0: return 0
	int i = ini_find_section_index(cfg, section)
	if i < 0: return 0
	ini_section* sec = cfg.sections[i]
	cfg.sections.remove(i)
	ini_section_free(sec)
	return 1


# 1 when the key existed in that section (or DEFAULT) and was removed;
# 0 when it or the section is missing.
int ini_remove_option(ini_config* cfg, char* section, char* key):
	ini_section* sec = ini_target_section(cfg, section)
	if sec == 0: return 0
	char* lk = ini_lower_copy(key)
	int i = ini_find_option_index(sec, lk)
	free(lk)
	if i < 0: return 0
	ini_option* opt = sec.options[i]
	sec.options.remove(i)
	ini_option_free(opt)
	return 1


# ---- reading ----

int ini_read_fail(ini_config* cfg, int status, int line, char* what):
	cfg.error = status
	cfg.error_line = line
	char* num = itoa(line)
	char* msg = strjoin(c"line ", num)
	msg = ini_concat(msg, ':', c" ", 1)
	msg = ini_concat(msg, 0, what, strlen(what))
	free(num)
	if cfg.error_message: free(cfg.error_message)
	cfg.error_message = msg
	return status


# "'name'" helpers for messages.
char* ini_quoted(char* prefix, char* name, char* suffix):
	char* m = strclone(prefix)
	m = ini_concat(m, '\'', name, strlen(name))
	m = ini_concat(m, '\'', suffix, strlen(suffix))
	return m


int ini_read_fail_owned(ini_config* cfg, int status, int line, char* what):
	ini_read_fail(cfg, status, line, what)
	free(what)
	return status


# Parse text into cfg (Python read_string). Returns INI_OK or the error
# status, also kept in ini_error / ini_error_line / ini_error_message.
int ini_read_string(ini_config* cfg, char* text):
	cfg.error = INI_OK
	cfg.error_line = 0
	if cfg.error_message:
		free(cfg.error_message)
		cfg.error_message = 0
	# names seen in this read (strict duplicate checks)
	list[char*] seen_sections = new list[char*]
	list[ini_option*] touched = new list[ini_option*]
	ini_section* cursect = 0
	ini_option* cur = 0          # option the next continuation extends
	int indent_level = 0
	int status = INI_OK
	int lineno = 0
	int pos = 0
	int len = strlen(text)
	while pos < len && status == INI_OK:
		int start = pos
		while pos < len && text[pos] != '\n': pos++
		int end = pos
		if pos < len: pos++
		lineno++
		# stripped bounds
		int a = start
		int z = end
		while a < z && ini_is_space(text[a]): a++
		while z > a && ini_is_space(text[z - 1]): z--
		if a == z:
			# blank line: part of the current value (dropped if trailing)
			if cursect != 0 && cur != 0: cur.value = ini_concat(cur.value, '\n', c"", 0)
			continue
		if text[a] == '#' || text[a] == ';':
			continue
		int cur_indent = a - start
		if cursect != 0 && cur != 0 && cur_indent > indent_level:
			cur.value = ini_concat(cur.value, '\n', &text[a], z - a)
			continue
		indent_level = cur_indent
		if text[a] == '[':
			int close = z - 1
			while close > a && text[close] != ']': close--
			if close > a + 1:
				char* sname = ini_substr(text, a + 1, close)
				int dup = 0
				for char* s in seen_sections:
					if ini_streq(s, sname): dup = 1
				if dup:
					status = ini_read_fail_owned(cfg, INI_DUPLICATE_SECTION, lineno, ini_quoted(c"section ", sname, c" already exists"))
					free(sname)
					break
				if ini_streq(sname, c"DEFAULT"):
					cursect = cfg.defaults
					free(sname)
				else:
					cursect = ini_find_section(cfg, sname)
					if cursect == 0:
						cursect = ini_section_new(sname)
						cfg.sections.push(cursect)
					seen_sections.push(sname)
				cur = 0
				continue
		if cursect == 0:
			status = ini_read_fail(cfg, INI_MISSING_SECTION_HEADER, lineno, c"file contains no section headers")
			break
		int d = a
		while d < z && text[d] != '=' && text[d] != ':': d++
		if d == z:
			char* bad = ini_substr(text, a, z)
			status = ini_read_fail_owned(cfg, INI_PARSE_ERROR, lineno, ini_quoted(c"parsing error: ", bad, c""))
			free(bad)
			break
		char* raw = ini_strip_range(text, a, d)
		if raw[0] == 0:
			free(raw)
			char* bad2 = ini_substr(text, a, z)
			status = ini_read_fail_owned(cfg, INI_PARSE_ERROR, lineno, ini_quoted(c"parsing error: ", bad2, c""))
			free(bad2)
			break
		char* key = ini_lower_copy(raw)
		free(raw)
		ini_option* opt = ini_find_option(cursect, key)
		int again = 0
		for ini_option* t in touched:
			if t == opt: again = 1
		if again:
			char* m = ini_quoted(c"option ", key, c" in section ")
			m = ini_concat(m, '\'', cursect.name, strlen(cursect.name))
			m = ini_concat(m, '\'', c" already exists", 15)
			status = ini_read_fail_owned(cfg, INI_DUPLICATE_OPTION, lineno, m)
			free(key)
			break
		char* value = ini_strip_range(text, d + 1, z)
		if opt != 0:
			free(key)
			free(opt.value)
			opt.value = value
		else:
			opt = new ini_option
			opt.name = key
			opt.value = value
			cursect.options.push(opt)
		touched.push(opt)
		cur = opt
	# Python _join_multiline_values: drop trailing blank lines
	for ini_option* t2 in touched:
		ini_rstrip_in_place(t2.value)
	for char* s2 in seen_sections:
		free(s2)
	seen_sections.free()
	touched.free()
	return status


# A new config holding text; check ini_error(cfg) (always returns a
# config, to be freed with ini_free, even when parsing failed).
ini_config* ini_parse(char* text):
	ini_config* cfg = ini_new()
	ini_read_string(cfg, text)
	return cfg


# ---- writing ----

void ini_write_section(ini_buf* b, ini_section* sec):
	ini_buf_str(b, c"[")
	ini_buf_str(b, sec.name)
	ini_buf_str(b, c"]\n")
	for ini_option* opt in sec.options:
		ini_buf_str(b, opt.name)
		ini_buf_str(b, c" = ")
		char* v = opt.value
		int i = 0
		while v[i] != 0:
			if v[i] == '\n': ini_buf_add(b, c"\n\t", 2)
			else: ini_buf_add(b, &v[i], 1)
			i++
		ini_buf_str(b, c"\n")
	ini_buf_str(b, c"\n")


# Python ConfigParser.write layout (malloc'd): DEFAULT first when it has
# keys, then every section in order, each followed by a blank line.
char* ini_write(ini_config* cfg):
	ini_buf b
	ini_buf_init(&b)
	if cfg.defaults.options.length > 0: ini_write_section(&b, cfg.defaults)
	for ini_section* sec in cfg.sections:
		ini_write_section(&b, sec)
	return b.data
