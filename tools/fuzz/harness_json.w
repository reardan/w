# wbuild: target=wfuzz_json_smoke tag=tests dep=wfuzz data=tools/fuzz/seeds/json/ data=tools/fuzz/dicts/json.dict data=tests/wexec/
# wbuild: step="bin/wv2 --coverage tools/fuzz/harness_json.w -o bin/wfuzz_json_harness"
# wbuild: step="rm -rf bin/wfuzz_json_smoke"
# wbuild: step="bin/wfuzz --binary bin/wfuzz_json_harness --ext .json --dict tools/fuzz/dicts/json.dict --corpus tools/fuzz/seeds/json --corpus tests/wexec --out bin/wfuzz_json_smoke --cases 0 --fail-on-findings" expect_stdout="crashes: 0" timeout=300000
# wbuild: target=wfuzz_json tag=fuzz_campaign dep=wfuzz
# wbuild: step="bin/wv2 --coverage tools/fuzz/harness_json.w -o bin/wfuzz_json_harness"
# wbuild: step="bin/wfuzz --binary bin/wfuzz_json_harness --ext .json --dict tools/fuzz/dicts/json.dict --corpus tools/fuzz/seeds/json --corpus tests/wexec --out bin/wfuzz_json" timeout=3600000
# Fuzz harness for structures/json.w (issue #842): parses the input and,
# when it is valid JSON, checks that stringify is a fixpoint of parse
# (stringify(parse(stringify(v))) == stringify(v)) and that a clone
# stringifies the same.
import tools.fuzz.harness
import structures.json


int main(int argc, int argv):
	int length = 0
	char* text = fh_input(argc, argv, &length)
	json_value* value = json_parse(text)
	if (value == 0): return 1
	char* once = json_stringify(value)
	json_value* again = json_parse(once)
	fh_check(again != 0, c"stringified JSON does not parse")
	char* twice = json_stringify(again)
	fh_check(strcmp(once, twice) == 0, c"stringify(parse(stringify(v))) differs from stringify(v)")
	json_value* copy = json_clone(value)
	char* cloned = json_stringify(copy)
	fh_check(strcmp(once, cloned) == 0, c"a clone stringifies differently")
	json_free(value)
	json_free(again)
	json_free(copy)
	free(once)
	free(twice)
	free(cloned)
	return 0
