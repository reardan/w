import lib.testing
import libs.standard.formats.configparser


void assert_config_parse_fails(char* text):
	config* cfg = config_parse(text)
	assert_equal(0, cast(int, cfg))


void test_config_defaults_sections_and_ints():
	config* cfg = config_parse(c"[DEFAULT]\nroot = /tmp\nanswer = 42\n[server]\nhost = localhost\nport: 8080\n[empty]\n")
	assert1(cfg != 0)
	assert_strings_equal(c"localhost", config_get(cfg, c"server", c"host"))
	assert_strings_equal(c"/tmp", config_get(cfg, c"server", c"root"))
	int value = 0
	assert_equal(1, config_get_int(cfg, c"server", c"port", &value))
	assert_equal(8080, value)
	assert_equal(1, config_get_int(cfg, c"server", c"answer", &value))
	assert_equal(42, value)
	list[char*] sections = config_sections(cfg)
	assert_equal(1, c"server" in sections)
	assert_equal(1, c"empty" in sections)
	assert_equal(0, c"DEFAULT" in sections)


void test_config_comments_whitespace_and_duplicate_keys():
	config* cfg = config_parse(c"; comment\n# another comment\n[main]\n key = one \nkey=two\nspaced : value with spaces\n")
	assert1(cfg != 0)
	assert_strings_equal(c"two", config_get(cfg, c"main", c"key"))
	assert_strings_equal(c"value with spaces", config_get(cfg, c"main", c"spaced"))


void test_config_missing_values():
	config* cfg = config_parse(c"[main]\nname = w\n")
	assert1(cfg != 0)
	assert_equal(0, cast(int, config_get(cfg, c"main", c"missing")))
	assert_equal(0, cast(int, config_get(cfg, c"missing", c"name")))
	int value = 0
	assert_equal(0, config_get_int(cfg, c"main", c"name", &value))


void test_config_negative_integer():
	config* cfg = config_parse(c"[main]\nvalue = -17\n")
	assert1(cfg != 0)
	int value = 0
	assert_equal(1, config_get_int(cfg, c"main", c"value", &value))
	assert_equal(-17, value)


void test_config_rejects_malformed_input():
	assert_config_parse_fails(c"key=value\n")
	assert_config_parse_fails(c"[broken\nkey=value\n")
	assert_config_parse_fails(c"[]\n")
	assert_config_parse_fails(c"[main]\n=value\n")
	assert_config_parse_fails(c"[main]\nmissing delimiter\n")
