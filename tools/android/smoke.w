# wbuild: binary=android_smoke tag=tests
# Explicit-device Android smoke qualification; no implicit device selection.
import tools.host_tools
import lib.str
import libs.standard.cli.argparse

char* as_serial

process_result* as_run(list[char*] args, int check = 1):
	list[char*] command = ht_argv(c"adb", c"-s", as_serial)
	for char* arg in args: command.push(arg)
	process_result* result = ht_run(command, 0, 0, 60000)
	if (check): ht_success(result)
	return result

int main(int argc, int argv):
	arg_parser* parser = argparse_new(c"android_smoke")
	argparse_arg_required(argparse_add_option(parser, c"--serial", c"SERIAL", c"adb device serial"))
	argparse_arg_default(argparse_add_option(parser, c"--apk", c"FILE", c"APK"), c"bin/android/app/WApp.apk")
	argparse_arg_default(argparse_add_option(parser, c"--screenshot", c"FILE", c"PNG output"), c"bin/android/app/preview.png")
	argparse_add_flag(parser, c"--probes", c"run packaged compiler/ABI probes")
	arg_namespace* args = argparse_parse_or_exit(parser, argc, argv)
	as_serial = argparse_get(args, c"serial")
	char[16] random
	ht_require(random_bytes(&random[0], 16), c"cannot create smoke token")
	char* token = hex_encode(&random[0], 16)
	as_run(ht_argv(c"install", c"--no-incremental", c"-r", argparse_get(args, c"apk")))
	as_run(ht_command(c"shell am force-stop org.wlang.androiddemo"))
	list[char*] start = ht_command(c"shell am start -W -n org.wlang.androiddemo/.WActivity --ez w_smoke true --es w_smoke_token")
	start.push(token)
	start.push(c"--ez")
	start.push(c"w_probes")
	char* probes = c"false"
	if (argparse_get_bool(args, c"probes")): probes = c"true"
	start.push(probes)
	as_run(start)
	char* logs = c""
	# Each poll is bounded, and the loop has a monotonic overall deadline.
	int deadline = process_monotonic_ms() + 45000
	while (process_monotonic_ms() < deadline):
		logs = as_run(ht_command(c"logcat -d -s WAndroid:I AndroidRuntime:E *:S")).stdout_text
		if (contains(logs, strjoin(c"android demo native: ok ", token)) && (!argparse_get_bool(args, c"probes") || contains(logs, strjoin(c"android compiler and ABI: ok ", token)))):
			char* screenshot = argparse_get(args, c"screenshot")
			ht_mkdir(path_dirname(screenshot))
			process_result* result = as_run(ht_command(c"exec-out screencap -p"))
			ht_write(screenshot, result.stdout_text, result.stdout_length)
			println(strjoin(strjoin(c"Android native callbacks, state, Unicode, lifecycle: OK (", as_serial), c")"))
			if (argparse_get_bool(args, c"probes")): println(c"Android embedded compiler, generated code, ARM64 ABI: OK")
			println(screenshot)
			return 0
		process_sleep_ms(1000)
	char* crashes = as_run(ht_command(c"logcat -d -b crash")).stdout_text
	as_run(ht_command(c"shell am force-stop org.wlang.androiddemo"))
	process_result* diagnostic = as_run(ht_command(c"shell run-as org.wlang.androiddemo cat files/w-src/compiler.log"), 0)
	println2(c"Android native smoke failed or timed out:")
	print2(logs)
	print2(crashes)
	print2(diagnostic.stdout_text)
	print2(diagnostic.stderr_text)
	return 1
