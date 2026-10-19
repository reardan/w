# wbuild: binary=test262_conformance
import tools.test262_conformance_lib
import libs.standard.cli.argparse

int main(int argc, int argv):
	arg_parser* parser = argparse_new(c"test262_conformance")
	argparse_arg_default(argparse_add_option(parser, c"--manifest", c"FILE", c"pinned Test262 profile"), c"tests/javascript/test262/manifest.json")
	argparse_arg_default(argparse_add_option(parser, c"--runner", c"FILE", c"native execution runner"), c"bin/test262_runtime_runner")
	argparse_add_option(parser, c"--json", c"FILE", c"write complete results")
	argparse_arg_default(argparse_add_float(parser, c"--timeout", c"SECONDS", c"per-case timeout"), c"10")
	argparse_arg_default(argparse_add_int(parser, c"--budget", c"STEPS", c"execution step budget"), c"100000")
	argparse_add_flag(parser, c"--require-all", c"fail if any case is unsupported")
	arg_namespace* args = argparse_parse_or_exit(parser, argc, argv)
	int status = 0
	json_value* report = t262_run(tempfile_abspath(argparse_get(args, c"manifest")), tempfile_abspath(argparse_get(args, c"runner")), cast(int, argparse_get_float(args, c"timeout") * 1000.0), argparse_get_int(args, c"budget"), &status, t262_execute)
	if (status != 2 && argparse_get_bool(args, c"require_all") && ht_number(jc_get(report, c"counts"), c"UNSUPPORTED")): status = 1
	char* encoded = strjoin(json_stringify(report), c"\n")
	char* output = argparse_get(args, c"json")
	if (output != 0): ht_write(output, encoded, strlen(encoded))
	print(encoded)
	ht_cleanup()
	return status
