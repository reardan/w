/*
Small INI/configparser subset.

Supported syntax:
- section headers: [section]
- default section: [DEFAULT]
- key/value pairs separated by '=' or ':'
- blank lines and full-line '#' or ';' comments
- duplicate keys use the last value

Interpolation, multiline values, inline comments, and duplicate-section policy
are deferred.
*/
import lib.lib


struct config:
	map[char*, map[char*, char*]] sections
	map[char*, char*] defaults


int config_is_space(int c):
	return (c == ' ') | (c == '\t')


int config_is_digit(int c):
	return (c >= '0') & (c <= '9')


char* config_copy_range(char* text, int start, int end):
	int length = end - start
	char* out = malloc(length + 1)
	int i = 0
	while (i < length):
		out[i] = text[start + i]
		i = i + 1
	out[length] = 0
	return out


char* config_copy_trim(char* text, int start, int end):
	while ((start < end) & (config_is_space(text[start]))):
		start = start + 1
	while ((end > start) & (config_is_space(text[end - 1]))):
		end = end - 1
	return config_copy_range(text, start, end)


int config_trim_start(char* text, int start, int end):
	while ((start < end) & (config_is_space(text[start]))):
		start = start + 1
	return start


int config_trim_end(char* text, int start, int end):
	while ((end > start) & (config_is_space(text[end - 1]))):
		end = end - 1
	return end


config* config_new():
	config* cfg = new config()
	cfg.sections = new map[char*, map[char*, char*]]
	cfg.defaults = new map[char*, char*]
	return cfg


config* config_parse(char* text):
	config* cfg = config_new()
	map[char*, char*] current = cfg.defaults
	int have_section = 0
	int i = 0
	while (text[i] != 0):
		int line_start = i
		while ((text[i] != 0) & (text[i] != '\n') & (text[i] != '\r')):
			i = i + 1
		int line_end = i
		if (text[i] == '\r'):
			i = i + 1
			if (text[i] == '\n'):
				i = i + 1
		else if (text[i] == '\n'):
			i = i + 1

		int start = config_trim_start(text, line_start, line_end)
		int end = config_trim_end(text, start, line_end)
		if (start == end):
			continue
		if ((text[start] == '#') | (text[start] == ';')):
			continue
		if (text[start] == '['):
			if ((end - start < 3) | (text[end - 1] != ']')):
				return 0
			char* name = config_copy_trim(text, start + 1, end - 1)
			if (name[0] == 0):
				return 0
			if (strcmp(name, c"DEFAULT") == 0):
				current = cfg.defaults
				have_section = 1
			else:
				if (name in cfg.sections):
					current = cfg.sections[name]
				else:
					current = new map[char*, char*]
					cfg.sections[name] = current
				have_section = 1
			continue

		if (have_section == 0):
			return 0
		int sep = -1
		int j = start
		while (j < end):
			if ((text[j] == '=') | (text[j] == ':')):
				sep = j
				j = end
			else:
				j = j + 1
		if (sep < 0):
			return 0
		char* key = config_copy_trim(text, start, sep)
		if (key[0] == 0):
			return 0
		char* value = config_copy_trim(text, sep + 1, end)
		current[key] = value
	return cfg


char* config_get(config* cfg, char* section, char* key):
	if (strcmp(section, c"DEFAULT") == 0):
		if (key in cfg.defaults):
			return cfg.defaults[key]
		return 0
	if (section in cfg.sections):
		map[char*, char*] values = cfg.sections[section]
		if (key in values):
			return values[key]
	if (key in cfg.defaults):
		return cfg.defaults[key]
	return 0


int config_get_int(config* cfg, char* section, char* key, int* out):
	char* value = config_get(cfg, section, key)
	if (value == 0):
		return 0
	int i = 0
	int negative = 0
	if (value[0] == '-'):
		negative = 1
		i = 1
	if (value[i] == 0):
		return 0
	int result = 0
	while (value[i] != 0):
		if (config_is_digit(value[i]) == 0):
			return 0
		result = result * 10 + value[i] - '0'
		i = i + 1
	if (negative):
		result = 0 - result
	out[0] = result
	return 1


list[char*] config_sections(config* cfg):
	list[char*] sections = new list[char*]
	for char* section in cfg.sections:
		sections.push(section)
	return sections
