# wbuild: binary=javascript_conformance_cli out=bin/javascript_conformance
import tools.javascript_conformance_lib
import libs.standard.cli.argparse

int main(int argc, int argv):
	arg_parser* parser = argparse_new(c"javascript_conformance")
	argparse_arg_default(argparse_add_option(parser, c"--manifest", c"FILE", c"pinned native ECMAScript manifest"), c"tests/javascript/conformance/manifest.json")
	argparse_arg_default(argparse_add_option(parser, c"--runner", c"FILE", c"native execution runner"), c"bin/javascript_runtime_runner")
	argparse_arg_default(argparse_add_float(parser, c"--timeout", c"SECONDS", c"per-case timeout"), c"10")
	argparse_add_option(parser, c"--json", c"FILE", c"write complete results")
	arg_namespace* args = argparse_parse_or_exit(parser, argc, argv)
	int status = 0
	json_value* report = jc_run(tempfile_abspath(argparse_get(args, c"manifest")), tempfile_abspath(argparse_get(args, c"runner")), cast(int, argparse_get_float(args, c"timeout") * 1000.0), &status)
	char* encoded = strjoin(json_stringify(report), c"\n")
	char* output = argparse_get(args, c"json")
	if (output != 0): ht_write(output, encoded, strlen(encoded))
	print(encoded)
	return status
